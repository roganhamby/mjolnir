import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_color_schemes.dart';

/// Represents a single notification item in the notification system.
class NotificationItem {
  final String id;
  final String message;
  final IconData? icon;
  final bool isError;
  final bool isSuccess;
  final Color? customColor;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration duration;
  final DateTime createdAt;

  NotificationItem({
    required this.id,
    required this.message,
    this.icon,
    this.isError = false,
    this.isSuccess = false,
    this.customColor,
    this.actionLabel,
    this.onAction,
    this.duration = const Duration(seconds: 3),
  }) : createdAt = DateTime.now();
}

/// Central manager for top-right floating toast notifications in Mjölnir.
class AppNotification {
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  static final _AppNotificationManager _manager = _AppNotificationManager();

  /// Show a notification in the top-right corner of the application window.
  static void show(
    BuildContext? context, {
    required String message,
    IconData? icon,
    bool isError = false,
    bool isSuccess = false,
    Color? backgroundColor,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    final effectiveIsError = isError ||
        backgroundColor == Colors.red ||
        backgroundColor == Colors.redAccent;

    _manager.show(
      context: context,
      message: message,
      icon: icon,
      isError: effectiveIsError,
      isSuccess: isSuccess,
      customColor: backgroundColor,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
  }

  /// Convenience helper to display a success notification.
  static void success(
    BuildContext? context,
    String message, {
    Duration duration = const Duration(seconds: 3),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    show(
      context,
      message: message,
      isSuccess: true,
      duration: duration,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  /// Convenience helper to display an error notification.
  static void error(
    BuildContext? context,
    String message, {
    Duration duration = const Duration(seconds: 4),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    show(
      context,
      message: message,
      isError: true,
      duration: duration,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  /// Dismiss all active notifications immediately.
  static void dismissAll() {
    _manager.dismissAll();
  }
}

class _AppNotificationManager with ChangeNotifier {
  static int _counter = 0;
  final List<NotificationItem> _items = [];
  OverlayEntry? _overlayEntry;

  List<NotificationItem> get items => List.unmodifiable(_items);

  void show({
    BuildContext? context,
    required String message,
    IconData? icon,
    bool isError = false,
    bool isSuccess = false,
    Color? customColor,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    OverlayState? overlay;
    if (context != null && context.mounted) {
      overlay = Overlay.maybeOf(context);
    }
    overlay ??= AppNotification.navigatorKey.currentState?.overlay;

    // Headless / test environment without active overlay
    if (overlay == null) {
      return;
    }

    final id = 'notif_${++_counter}';
    final item = NotificationItem(
      id: id,
      message: message,
      icon: icon,
      isError: isError,
      isSuccess: isSuccess,
      customColor: customColor,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );

    // Limit maximum stacked notifications to 4
    if (_items.length >= 4) {
      _items.removeAt(0);
    }
    _items.add(item);
    notifyListeners();

    if (_overlayEntry == null) {
      _overlayEntry = OverlayEntry(
        builder: (ctx) => _NotificationHost(manager: this),
      );
      overlay.insert(_overlayEntry!);
    } else {
      _overlayEntry!.markNeedsBuild();
    }
  }

  void remove(String id) {
    _items.removeWhere((item) => item.id == id);
    notifyListeners();

    if (_items.isEmpty && _overlayEntry != null) {
      _overlayEntry?.remove();
      _overlayEntry = null;
    } else {
      _overlayEntry?.markNeedsBuild();
    }
  }

  void dismissAll() {
    _items.clear();
    notifyListeners();
    if (_overlayEntry != null) {
      _overlayEntry?.remove();
      _overlayEntry = null;
    }
  }
}

class _NotificationHost extends StatelessWidget {
  final _AppNotificationManager manager;

  const _NotificationHost({required this.manager});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) {
        if (manager.items.isEmpty) {
          return const SizedBox.shrink();
        }

        return Positioned(
          top: 64,
          right: 16,
          child: Material(
            type: MaterialType.transparency,
            child: SafeArea(
              child: FocusScope(
                canRequestFocus: false,
                child: SizedBox(
                  width: 380,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final item in manager.items)
                        _NotificationCard(
                          key: ValueKey(item.id),
                          item: item,
                          onDismiss: () => manager.remove(item.id),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NotificationCard extends StatefulWidget {
  final NotificationItem item;
  final VoidCallback onDismiss;

  const _NotificationCard({
    super.key,
    required this.item,
    required this.onDismiss,
  });

  @override
  State<_NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<_NotificationCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<Offset> _slideAnim;
  late Animation<double> _fadeAnim;
  Timer? _dismissTimer;
  bool _isHovered = false;
  bool _isDismissing = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );

    _slideAnim = Tween<Offset>(
      begin: const Offset(0.2, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
    ));

    _fadeAnim = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    );

    _animController.forward();
    _startTimer(widget.item.duration);
  }

  void _startTimer(Duration duration) {
    _dismissTimer?.cancel();
    _dismissTimer = Timer(duration, () {
      if (mounted && !_isHovered && !_isDismissing) {
        _dismiss();
      }
    });
  }

  void _dismiss() {
    if (_isDismissing) return;
    _isDismissing = true;
    _dismissTimer?.cancel();
    _animController.reverse().then((_) {
      if (mounted) {
        widget.onDismiss();
      }
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = AppColorScheme.of(context);

    // Color coordination based on notification kind
    final Color borderColor;
    final Color iconColor;
    final IconData defaultIcon;

    if (widget.item.isError) {
      borderColor = Colors.redAccent.withValues(alpha: 0.6);
      iconColor = Colors.redAccent;
      defaultIcon = Icons.error_outline;
    } else if (widget.item.isSuccess) {
      borderColor = Colors.greenAccent.withValues(alpha: 0.6);
      iconColor = Colors.greenAccent;
      defaultIcon = Icons.check_circle_outline;
    } else {
      borderColor = scheme.borderColor;
      iconColor = scheme.accentColor;
      defaultIcon = Icons.info_outline;
    }

    final displayIcon = widget.item.icon ?? defaultIcon;

    return SlideTransition(
      position: _slideAnim,
      child: FadeTransition(
        opacity: _fadeAnim,
        child: MouseRegion(
          onEnter: (_) {
            _isHovered = true;
            _dismissTimer?.cancel();
          },
          onExit: (_) {
            _isHovered = false;
            if (!_isDismissing) {
              _startTimer(const Duration(seconds: 2));
            }
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: scheme.elevatedSurface.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor, width: 1.2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Leading status icon container
                Container(
                  width: 28,
                  height: 28,
                  margin: const EdgeInsets.only(right: 10, top: 1),
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(displayIcon, size: 16, color: iconColor),
                ),

                // Main message content and action
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.item.message,
                        style: TextStyle(
                          color: scheme.primaryText,
                          fontSize: 13,
                          height: 1.3,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (widget.item.actionLabel != null && widget.item.onAction != null) ...[
                        const SizedBox(height: 8),
                        OutlinedButton(
                          focusNode: FocusNode(canRequestFocus: false, skipTraversal: true),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            minimumSize: const Size(0, 26),
                            side: BorderSide(color: iconColor.withValues(alpha: 0.5)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          onPressed: () {
                            _dismiss();
                            widget.item.onAction!();
                          },
                          child: Text(
                            widget.item.actionLabel!,
                            style: TextStyle(
                              color: iconColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(width: 8),

                // Close button
                InkResponse(
                  focusNode: FocusNode(canRequestFocus: false, skipTraversal: true),
                  radius: 14,
                  onTap: _dismiss,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      Icons.close,
                      size: 15,
                      color: scheme.mutedText,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
