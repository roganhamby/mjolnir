import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xterm/xterm.dart';
import '../models/server_config.dart';
import '../models/task_item.dart';
import '../services/local_shell_service.dart';
import '../services/ssh_service.dart';
import '../services/known_hosts_service.dart';
import '../theme/ansi_themes.dart';
import '../theme/app_color_schemes.dart';
import 'task_manager_tab_widget.dart';
import 'app_notification.dart';

class TerminalTabWidget extends StatefulWidget {
  final ServerConfig server;
  final SshService sshService;
  final bool isLocalShell;
  final LocalShellService localShellService;
  final TerminalTheme theme;
  final String? initialThemeName;
  final double fontSize;
  final bool isActive;
  final TaskItem? assignedTask;
  final VoidCallback? onCompleteAssignedTask;
  final VoidCallback? onUnassignTask;
  final ValueChanged<TaskItem>? onAssignedTaskChanged;
  final VoidCallback? onClose;
  final Function(double newFontSize)? onFontSizeChanged;
  final Function(String newThemeName)? onThemeChanged;
  final Widget? timerWidget;

  const TerminalTabWidget({
    super.key,
    required this.server,
    required this.sshService,
    this.isLocalShell = false,
    this.localShellService = const LocalShellService(),
    this.theme = TerminalThemes.defaultTheme,
    this.initialThemeName,
    this.fontSize = 13.0,
    this.isActive = true,
    this.assignedTask,
    this.onCompleteAssignedTask,
    this.onUnassignTask,
    this.onAssignedTaskChanged,
    this.onClose,
    this.onFontSizeChanged,
    this.onThemeChanged,
    this.timerWidget,
  });

  @override
  State<TerminalTabWidget> createState() => _TerminalTabWidgetState();
}

class _TerminalSelectionController extends TerminalController {
  _TerminalSelectionController({
    required this.isDesktop,
    this.onSelectionUpdated,
  }) : super(pointerInputs: const PointerInputs.none());

  final bool isDesktop;
  final VoidCallback? onSelectionUpdated;
  bool _allowInternalUpdate = false;
  BufferRange? _fallbackSelection;

  @override
  BufferRange? get selection => super.selection ?? _fallbackSelection;

  void setCustomSelection(
    CellAnchor base,
    CellAnchor extent, {
    CellOffset? baseOffset,
    CellOffset? extentOffset,
    SelectionMode? mode,
  }) {
    if (baseOffset != null && extentOffset != null) {
      final effectiveMode = mode ?? selectionMode;
      _fallbackSelection = effectiveMode == SelectionMode.block
          ? BufferRangeBlock(baseOffset, extentOffset)
          : BufferRangeLine(baseOffset, extentOffset);
    }
    _allowInternalUpdate = true;
    try {
      super.setSelection(base, extent, mode: mode);
    } finally {
      _allowInternalUpdate = false;
    }
    onSelectionUpdated?.call();
  }

  void forceClearSelection() {
    _fallbackSelection = null;
    _allowInternalUpdate = true;
    try {
      super.clearSelection();
    } finally {
      _allowInternalUpdate = false;
    }
    onSelectionUpdated?.call();
  }

  @override
  void setSelection(CellAnchor base, CellAnchor extent, {SelectionMode? mode}) {
    if (isDesktop && !_allowInternalUpdate) {
      base.dispose();
      extent.dispose();
      return;
    }
    super.setSelection(base, extent, mode: mode);
    onSelectionUpdated?.call();
  }

  @override
  void clearSelection() {
    if (isDesktop && !_allowInternalUpdate) {
      return;
    }
    _fallbackSelection = null;
    super.clearSelection();
    onSelectionUpdated?.call();
  }
}

class _TerminalTabWidgetState extends State<TerminalTabWidget>
    with WidgetsBindingObserver {
  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  late final Terminal terminal;
  late final _TerminalSelectionController _terminalController;
  late final ScrollController _scrollController;
  late final FocusNode _terminalFocusNode;
  SshSession? _sshSession;
  LocalShellSession? _localSession;
  bool _isLoading = true;
  String? _errorMessage;
  bool _isExited = false;
  bool _isDisconnected = false;
  String? _disconnectReason;
  Timer? _reconnectTimer;
  int _reconnectCountdown = 0;
  int _reconnectAttempt = 0;
  bool _autoReconnectCancelled = false;
  static const int maxReconnectAttempts = 5;
  late double _fontSize;
  late String _currentThemeName;
  late TerminalTheme _currentTheme;
  int _lastCellWidth = 0;
  int _lastCellHeight = 0;
  bool _consumedCopyOnCtrlCDown = false;
  bool _isPrimaryPointerDown = false;
  Offset? _selectionDragOriginGlobal;
  DateTime? _lastPointerDownTime;
  Offset? _lastPointerDownPosition;
  int _pointerClickCount = 0;

  // Screen logging state
  bool _isScreenLogging = false;
  String? _screenLogPath;
  IOSink? _screenLogSink;
  int _screenLogBytesWritten = 0;
  bool _ctrlModifierActive = false;
  final RegExp _ansiRegex = RegExp(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])');

  static TerminalTargetPlatform _getTerminalPlatform() {
    if (Platform.isWindows) return TerminalTargetPlatform.windows;
    if (Platform.isMacOS) return TerminalTargetPlatform.macos;
    if (Platform.isLinux) return TerminalTargetPlatform.linux;
    if (Platform.isAndroid) return TerminalTargetPlatform.android;
    if (Platform.isIOS) return TerminalTargetPlatform.ios;
    return TerminalTargetPlatform.unknown;
  }

  void _requestTerminalFocus() {
    if (!mounted || !widget.isActive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isActive && !_terminalFocusNode.hasFocus) {
        _terminalFocusNode.requestFocus();
      }
    });
  }

  void _syncRemotePtySize({
    int? width,
    int? height,
    int? cellWidth,
    int? cellHeight,
  }) {
    final w = width ?? terminal.viewWidth;
    final h = height ?? terminal.viewHeight;
    if (w <= 0 || h <= 0) return;
    final cw = cellWidth ?? _lastCellWidth;
    final ch = cellHeight ?? _lastCellHeight;

    final localSession = _localSession;
    if (localSession != null) {
      try {
        localSession.resizeTerminal(
          w,
          h,
          cw > 0 ? w * cw : 0,
          ch > 0 ? h * ch : 0,
        );
      } catch (_) {}
      return;
    }

    final session = _sshSession?.session;
    if (session == null) return;
    try {
      session.resizeTerminal(
        w,
        h,
        cw > 0 ? w * cw : 0,
        ch > 0 ? h * ch : 0,
      );
    } catch (_) {}
  }

  void _handleTerminalResize(
    int width,
    int height,
    int cellWidth,
    int cellHeight,
  ) {
    _lastCellWidth = cellWidth;
    _lastCellHeight = cellHeight;

    // Track the cursor line across xterm's Buffer.resize + reflow so that
    // unwrapping/wrapping lines when going full screen keeps cursorY aligned
    // with the actual prompt line and resets full-height vertical margins.
    CellAnchor? cursorAnchor;
    if (!terminal.isUsingAltBuffer && terminal.mainBuffer.lines.length > 0) {
      final absY = terminal.mainBuffer.absoluteCursorY.clamp(
        0,
        terminal.mainBuffer.lines.length - 1,
      );
      final curX = terminal.mainBuffer.cursorX.clamp(
        0,
        terminal.viewWidth > 0 ? terminal.viewWidth - 1 : 0,
      );
      cursorAnchor = terminal.mainBuffer.createAnchor(curX, absY);
    }

    _syncRemotePtySize(
      width: width,
      height: height,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
    );

    scheduleMicrotask(() {
      if (cursorAnchor != null) {
        if (cursorAnchor.attached && !terminal.isUsingAltBuffer) {
          final mainBuf = terminal.mainBuffer;
          var changed = false;
          // Trim excess trailing empty lines pushed past viewHeight by reflow
          while (mainBuf.lines.length > terminal.viewHeight &&
              mainBuf.lines.length - 1 > cursorAnchor.y &&
              mainBuf.lines[mainBuf.lines.length - 1].getTrimmedLength() == 0) {
            mainBuf.lines.pop();
            changed = true;
          }
          final targetCursorY = (cursorAnchor.y - mainBuf.scrollBack).clamp(
            0,
            terminal.viewHeight > 0 ? terminal.viewHeight - 1 : 0,
          );
          final targetCursorX = cursorAnchor.x.clamp(
            0,
            terminal.viewWidth > 0 ? terminal.viewWidth - 1 : 0,
          );
          if (mainBuf.cursorX != targetCursorX ||
              mainBuf.cursorY != targetCursorY) {
            mainBuf.setCursor(targetCursorX, targetCursorY);
            changed = true;
          }
          mainBuf.resetVerticalMargins();
          if (changed && mounted) {
            terminal.notifyListeners();
          }
        }
        cursorAnchor.dispose();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fontSize = widget.fontSize;
    terminal = Terminal(
      maxLines: 10000,
      platform: _getTerminalPlatform(),
      onResize: _handleTerminalResize,
      onPrivateOSC: _handlePrivateOSC,
    );
    // Disable sending mouse tap events to the remote application so that
    // mouse drag selection and right-click context menu (Copy / Paste) work
    // reliably even when vim enables mouse mode (set mouse=a).
    _terminalController = _TerminalSelectionController(
      isDesktop: Platform.isMacOS || Platform.isWindows || Platform.isLinux,
      onSelectionUpdated: _markTerminalNeedsPaint,
    );
    _scrollController = ScrollController();
    _terminalFocusNode = FocusNode();
    _currentThemeName = widget.server.terminalTheme.isNotEmpty
        ? widget.server.terminalTheme
        : (widget.initialThemeName ?? 'Default Dark');
    _currentTheme = AnsiThemes.all[_currentThemeName] ?? widget.theme;
    _requestTerminalFocus();
    _connect();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!terminal.isUsingAltBuffer) {
        terminal.mainBuffer.resetVerticalMargins();
      }
      _syncRemotePtySize();
    });
  }

  @override
  void didUpdateWidget(TerminalTabWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) {
      _requestTerminalFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _syncRemotePtySize();
        }
      });
    }
    if (oldWidget.fontSize != widget.fontSize) {
      _fontSize = widget.fontSize;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _syncRemotePtySize();
        }
      });
    }
    if (oldWidget.server.terminalTheme != widget.server.terminalTheme &&
        widget.server.terminalTheme.isNotEmpty) {
      _currentThemeName = widget.server.terminalTheme;
      _currentTheme = AnsiThemes.all[_currentThemeName] ?? TerminalThemes.defaultTheme;
    }
  }

  void _changeTheme(String newThemeName) {
    setState(() {
      _currentThemeName = newThemeName;
      _currentTheme = AnsiThemes.all[newThemeName] ?? TerminalThemes.defaultTheme;
    });
    widget.server.terminalTheme = newThemeName;
    widget.onThemeChanged?.call(newThemeName);
    _requestTerminalFocus();
  }

  void _increaseFontSize() {
    if (_fontSize < 32) {
      setState(() {
        _fontSize += 1.0;
      });
      widget.onFontSizeChanged?.call(_fontSize);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncRemotePtySize();
      });
    }
    _requestTerminalFocus();
  }

  void _decreaseFontSize() {
    if (_fontSize > 8) {
      setState(() {
        _fontSize -= 1.0;
      });
      widget.onFontSizeChanged?.call(_fontSize);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncRemotePtySize();
      });
    }
    _requestTerminalFocus();
  }

  void _resetFontSize() {
    setState(() {
      _fontSize = 13.0;
    });
    widget.onFontSizeChanged?.call(_fontSize);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncRemotePtySize();
    });
    _requestTerminalFocus();
  }

  // --- Copy & Paste Support ---

  void _repairDetachedBufferLines([Buffer? targetBuffer]) {
    final buf = targetBuffer ?? terminal.buffer;
    final len = buf.lines.length;
    for (var i = 0; i < len; i++) {
      final line = buf.lines[i];
      if (!line.attached) {
        buf.lines[i] = line;
      }
    }
  }

  void _writeToTerminal(String rawText) {
    if (rawText.isEmpty) return;
    var processed = rawText;

    // Extract any OSC 52 clipboard sequence wrapped inside a GNU screen / tmux
    // DCS passthrough (\x1bP...\x1b\\) so yanking inside screen/vim copies to
    // the local system clipboard.
    if (processed.contains('\x1bP')) {
      final dcsOsc52 = RegExp(
        r'\x1bP(?:tmux;)?(?:\x1b)+]52;[^;\x07\x1b]*;([A-Za-z0-9+/=\s]+?)(?:\x07|\x1b\\)+',
      );
      for (final match in dcsOsc52.allMatches(processed)) {
        final payload = match.group(1);
        if (payload != null && payload.isNotEmpty && payload != '?') {
          _handlePrivateOSC('52', ['c', payload]);
        }
      }
    }

    // Strip DCS (\x1bP...\x1b\\), APC (\x1b_...\x1b\\), PM (\x1b^...\x1b\\),
    // and GNU screen window-title (\x1bk...\x1b\\) control strings that
    // xterm-4.0.0's EscapeParser does not implement.
    if (processed.contains('\x1b')) {
      processed = processed.replaceAll(
        RegExp(r'\x1b[P_^k][\s\S]*?\x1b\\'),
        '',
      );
    }

    terminal.write(processed);

    // Keep bracketedPasteMode disabled so pasting inside GNU screen (or vim /
    // subshells inside screen where TERM=screen does not expect \x1b[200~)
    // never sends raw \x1b[200~...\x1b[201~ escape sequences.
    if (terminal.bracketedPasteMode) {
      terminal.setBracketedPasteMode(false);
    }

    // xterm-4.0.0's Buffer.scrollUp, Buffer.scrollDown, and Buffer.deleteLines
    // detach moved BufferLine instances (setting line.attached = false), which
    // happens constantly in GNU screen and causes CellAnchor.attached to be
    // false and TerminalController.selection to return null. Re-attach any
    // detached lines immediately.
    _repairDetachedBufferLines(terminal.mainBuffer);
    if (terminal.isUsingAltBuffer) {
      _repairDetachedBufferLines(terminal.altBuffer);
    }
  }

  void _markTerminalNeedsPaint() {
    if (!mounted) return;
    final viewState = _terminalViewKey.currentState;
    if (viewState == null) return;
    try {
      viewState.renderTerminal.markNeedsPaint();
    } catch (_) {}
  }

  void _selectWordAtGlobal(Offset globalPos) {
    final viewState = _terminalViewKey.currentState;
    if (viewState == null || terminal.buffer.lines.length == 0) return;
    try {
      _repairDetachedBufferLines();
      final render = viewState.renderTerminal;
      final localPos = render.globalToLocal(globalPos);
      final cell = render.getCellOffset(localPos);
      final boundary = terminal.buffer.getWordBoundary(cell);
      if (boundary != null) {
        _terminalController.setCustomSelection(
          terminal.buffer.createAnchorFromOffset(boundary.begin),
          terminal.buffer.createAnchorFromOffset(boundary.end),
          baseOffset: boundary.begin,
          extentOffset: boundary.end,
          mode: SelectionMode.line,
        );
      }
    } catch (_) {}
  }

  void _selectLineAtGlobal(Offset globalFrom, [Offset? globalTo]) {
    final viewState = _terminalViewKey.currentState;
    if (viewState == null || terminal.buffer.lines.length == 0) return;
    try {
      _repairDetachedBufferLines();
      final render = viewState.renderTerminal;
      final fromCell = render.getCellOffset(render.globalToLocal(globalFrom));
      final toCell = globalTo != null
          ? render.getCellOffset(render.globalToLocal(globalTo))
          : fromCell;
      final startY = (fromCell.y <= toCell.y ? fromCell.y : toCell.y)
          .clamp(0, terminal.buffer.lines.length - 1);
      final endY = (fromCell.y <= toCell.y ? toCell.y : fromCell.y)
          .clamp(0, terminal.buffer.lines.length - 1);
      final baseOffset = CellOffset(0, startY);
      final extentOffset = CellOffset(terminal.viewWidth, endY);
      _terminalController.setCustomSelection(
        terminal.buffer.createAnchorFromOffset(baseOffset),
        terminal.buffer.createAnchorFromOffset(extentOffset),
        baseOffset: baseOffset,
        extentOffset: extentOffset,
        mode: SelectionMode.line,
      );
    } catch (_) {}
  }

  void _selectRangeGlobal(
    Offset globalFrom,
    Offset globalTo, {
    required int clickCount,
  }) {
    final viewState = _terminalViewKey.currentState;
    if (viewState == null || terminal.buffer.lines.length == 0) return;
    try {
      _repairDetachedBufferLines();
      final render = viewState.renderTerminal;
      final localFrom = render.globalToLocal(globalFrom);
      final localTo = render.globalToLocal(globalTo);

      if (clickCount >= 3) {
        _selectLineAtGlobal(globalFrom, globalTo);
        return;
      }

      if (clickCount == 2) {
        final fromCell = render.getCellOffset(localFrom);
        final toCell = render.getCellOffset(localTo);
        final fromBoundary = terminal.buffer.getWordBoundary(fromCell);
        final toBoundary = terminal.buffer.getWordBoundary(toCell);
        if (fromBoundary != null && toBoundary != null) {
          final merged = fromBoundary.merge(toBoundary);
          _terminalController.setCustomSelection(
            terminal.buffer.createAnchorFromOffset(merged.begin),
            terminal.buffer.createAnchorFromOffset(merged.end),
            baseOffset: merged.begin,
            extentOffset: merged.end,
            mode: SelectionMode.line,
          );
          return;
        }
      }

      var fromCell = render.getCellOffset(localFrom);
      var toCell = render.getCellOffset(localTo);
      final isForward = toCell.y > fromCell.y ||
          (toCell.y == fromCell.y && toCell.x >= fromCell.x);

      if (isForward) {
        toCell = CellOffset(
          (toCell.x + 1).clamp(0, terminal.viewWidth),
          toCell.y,
        );
      } else {
        fromCell = CellOffset(
          (fromCell.x + 1).clamp(0, terminal.viewWidth),
          fromCell.y,
        );
      }

      _terminalController.setCustomSelection(
        terminal.buffer.createAnchorFromOffset(fromCell),
        terminal.buffer.createAnchorFromOffset(toCell),
        baseOffset: fromCell,
        extentOffset: toCell,
        mode: SelectionMode.line,
      );
    } catch (_) {}
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!_terminalFocusNode.hasFocus) {
      _terminalFocusNode.requestFocus();
    }

    if (event.kind == PointerDeviceKind.touch) {
      return;
    }

    final isSecondary = (event.buttons & kSecondaryMouseButton) != 0 ||
        (Platform.isMacOS &&
            (event.buttons & kPrimaryMouseButton) != 0 &&
            HardwareKeyboard.instance.isControlPressed);

    if (isSecondary) {
      _isPrimaryPointerDown = false;
      if (Platform.isMacOS &&
          (event.buttons & kPrimaryMouseButton) != 0 &&
          HardwareKeyboard.instance.isControlPressed) {
        _showContextMenu(event.position);
      }
      return;
    }

    if ((event.buttons & kPrimaryMouseButton) != 0) {
      _isPrimaryPointerDown = true;
      final now = DateTime.now();
      if (_lastPointerDownTime != null &&
          _lastPointerDownPosition != null &&
          now.difference(_lastPointerDownTime!) <= kDoubleTapTimeout &&
          (event.position - _lastPointerDownPosition!).distance <= kDoubleTapSlop) {
        _pointerClickCount = (_pointerClickCount % 3) + 1;
      } else {
        _pointerClickCount = 1;
      }
      _lastPointerDownTime = now;
      _lastPointerDownPosition = event.position;

      if (_pointerClickCount == 1) {
        if (HardwareKeyboard.instance.isShiftPressed &&
            _selectionDragOriginGlobal != null) {
          _selectRangeGlobal(
            _selectionDragOriginGlobal!,
            event.position,
            clickCount: 1,
          );
          return;
        }
        _selectionDragOriginGlobal = event.position;
        if (_terminalController.selection != null) {
          _terminalController.forceClearSelection();
        }
      } else if (_pointerClickCount == 2) {
        _selectionDragOriginGlobal = event.position;
        _selectWordAtGlobal(event.position);
      } else if (_pointerClickCount >= 3) {
        _selectionDragOriginGlobal = event.position;
        _selectLineAtGlobal(event.position);
      }
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      return;
    }
    if (!_isPrimaryPointerDown || (event.buttons & kPrimaryMouseButton) == 0) {
      return;
    }
    final origin = _selectionDragOriginGlobal;
    if (origin == null) return;

    if (_pointerClickCount == 1 && (event.position - origin).distance < 2.0) {
      return;
    }

    _selectRangeGlobal(
      origin,
      event.position,
      clickCount: _pointerClickCount,
    );
  }

  void _handlePointerUp(PointerUpEvent event) {
    _isPrimaryPointerDown = false;
    _markTerminalNeedsPaint();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _isPrimaryPointerDown = false;
  }

  void _handlePrivateOSC(String code, List<String> args) {
    // Support OSC 52 clipboard integration (\x1b]52;c;<base64>\x07) used by
    // vim / neovim / tmux to copy yanked text to the local system clipboard.
    if (code == '52' && args.length >= 2) {
      final payload = args[1];
      if (payload.isNotEmpty && payload != '?') {
        try {
          final cleaned = payload.replaceAll(RegExp(r'\s+'), '');
          final decoded = utf8.decode(base64.decode(cleaned), allowMalformed: true);
          if (decoded.isNotEmpty) {
            Clipboard.setData(ClipboardData(text: decoded));
          }
        } catch (_) {}
      }
    }
  }

  String _extractSelectedText(BufferRange selection) {
    final range = selection.normalized;
    final builder = StringBuffer();
    final buffer = terminal.buffer;
    final segments = range.toSegments().toList();

    for (var sIdx = 0; sIdx < segments.length; sIdx++) {
      final segment = segments[sIdx];
      if (segment.line < 0 || segment.line >= buffer.height) {
        continue;
      }
      final line = buffer.lines[segment.line];
      if (!(segment.line == range.begin.y ||
          segment.line == 0 ||
          line.isWrapped)) {
        builder.write('\n');
      }

      final from = (segment.start ?? 0).clamp(0, line.length);
      final trimmedEnd = line.getTrimmedLength(line.length);
      var nonSpaceEnd = trimmedEnd;
      if (!line.isWrapped) {
        while (nonSpaceEnd > 0) {
          final cp = line.getCodePoint(nonSpaceEnd - 1);
          if (cp != 0 && cp != 0x20) {
            final w = line.getWidth(nonSpaceEnd - 1);
            if (w > 1) {
              nonSpaceEnd = (nonSpaceEnd - 1 + w).clamp(0, line.length);
            }
            break;
          }
          nonSpaceEnd--;
        }
      }

      final maxEnd = segment.end != null
          ? segment.end!.clamp(0, line.length)
          : line.length;
      final effectiveEnd = maxEnd < nonSpaceEnd ? maxEnd : nonSpaceEnd;

      for (var i = from; i < effectiveEnd; i++) {
        final codePoint = line.getCodePoint(i);
        final width = line.getWidth(i);
        if (codePoint == 0) {
          if (i > 0 && line.getWidth(i - 1) == 2) {
            continue;
          }
          builder.write(' ');
        } else if (i + width <= maxEnd) {
          builder.writeCharCode(codePoint);
        }
      }
    }

    return builder.toString();
  }

  Future<void> _copySelection({bool showNotification = true}) async {
    final selection = _terminalController.selection;
    if (selection == null) {
      if (showNotification && mounted) {
        AppNotification.show(
          context,
          message: 'No text selected in terminal',
          duration: const Duration(seconds: 1),
        );
      }
      _requestTerminalFocus();
      return;
    }

    final text = _extractSelectedText(selection);
    if (text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      if (showNotification && mounted) {
        AppNotification.show(
          context,
          message: 'Copied ${text.length} characters to clipboard',
          duration: const Duration(seconds: 1),
        );
      }
    }
    _requestTerminalFocus();
  }

  Future<void> _pasteToTerminal() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      // Normalize Windows CRLF (\r\n) and LF (\n) to CR (\r) so GNU screen,
      // vim, and remote PTYs do not insert double newlines or literal ^M.
      final normalized = text.replaceAll('\r\n', '\r').replaceAll('\n', '\r');
      // Send via textInput rather than bracketed paste (\x1b[200~...\x1b[201~)
      // so pasting works reliably inside GNU screen sessions as well as shells
      // and editors.
      terminal.textInput(normalized);
      _terminalController.forceClearSelection();
    }
    _requestTerminalFocus();
  }

  void _selectAll() {
    if (terminal.buffer.height <= 0) return;
    _repairDetachedBufferLines();
    final baseOffset = const CellOffset(0, 0);
    final extentOffset = CellOffset(terminal.viewWidth, terminal.buffer.height - 1);
    _terminalController.setCustomSelection(
      terminal.buffer.createAnchorFromOffset(baseOffset),
      terminal.buffer.createAnchorFromOffset(extentOffset),
      baseOffset: baseOffset,
      extentOffset: extentOffset,
      mode: SelectionMode.line,
    );
    _requestTerminalFocus();
  }

  void _clearScreen() {
    terminal.eraseDisplay();
    _terminalController.forceClearSelection();
    _requestTerminalFocus();
  }

  Future<void> _showContextMenu(Offset position) async {
    final hasSelection = _terminalController.selection != null;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      color: const Color(0xFF2D2D2D),
      items: [
        PopupMenuItem<String>(
          value: 'copy',
          enabled: hasSelection,
          height: 36,
          child: Row(
            children: [
              Icon(Icons.copy, size: 16, color: hasSelection ? Colors.white : Colors.grey),
              const SizedBox(width: 8),
              Text(
                'Copy',
                style: TextStyle(
                  fontSize: 13,
                  color: hasSelection ? Colors.white : Colors.grey,
                ),
              ),
              const Spacer(),
              Text(
                Platform.isMacOS ? '⌘C' : 'Ctrl+Shift+C',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'paste',
          height: 36,
          child: Row(
            children: [
              const Icon(Icons.paste, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              const Text('Paste', style: TextStyle(fontSize: 13, color: Colors.white)),
              const Spacer(),
              Text(
                Platform.isMacOS ? '⌘V' : 'Ctrl+V',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(height: 8),
        PopupMenuItem<String>(
          value: 'selectAll',
          height: 36,
          child: Row(
            children: [
              const Icon(Icons.select_all, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              const Text('Select All', style: TextStyle(fontSize: 13, color: Colors.white)),
              const Spacer(),
              Text(
                Platform.isMacOS ? '⌘A' : 'Ctrl+Shift+A',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'clear',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.clear_all, size: 16, color: Colors.white),
              SizedBox(width: 8),
              Text('Clear Screen', style: TextStyle(fontSize: 13, color: Colors.white)),
            ],
          ),
        ),
      ],
    );

    if (selected == 'copy') {
      _copySelection();
    } else if (selected == 'paste') {
      _pasteToTerminal();
    } else if (selected == 'selectAll') {
      _selectAll();
    } else if (selected == 'clear') {
      _clearScreen();
    } else {
      _requestTerminalFocus();
    }
  }

  KeyEventResult _handleTerminalKeyEvent(FocusNode focusNode, KeyEvent event) {
    if (event is KeyUpEvent) {
      if (event.logicalKey == LogicalKeyboardKey.keyC) {
        _consumedCopyOnCtrlCDown = false;
      }
      return KeyEventResult.ignored;
    }

    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final isMeta = HardwareKeyboard.instance.isMetaPressed;
      final isCtrl = HardwareKeyboard.instance.isControlPressed;
      final isShift = HardwareKeyboard.instance.isShiftPressed;

      // Copy: Cmd+C (macOS) or Ctrl+Shift+C or (Ctrl+C if text is selected)
      if ((isMeta && event.logicalKey == LogicalKeyboardKey.keyC) ||
          (isCtrl && isShift && event.logicalKey == LogicalKeyboardKey.keyC)) {
        if (event is KeyDownEvent) {
          _copySelection();
          _terminalController.forceClearSelection();
        }
        return KeyEventResult.handled;
      }

      if (isCtrl && !isShift && event.logicalKey == LogicalKeyboardKey.keyC) {
        if (event is KeyDownEvent && _terminalController.selection != null) {
          _consumedCopyOnCtrlCDown = true;
          _copySelection();
          _terminalController.forceClearSelection();
          return KeyEventResult.handled;
        }
        if (event is KeyRepeatEvent && _consumedCopyOnCtrlCDown) {
          return KeyEventResult.handled;
        }
      }

      // Paste: Cmd+V (macOS) or Ctrl+Shift+V or Ctrl+V
      if ((isMeta && event.logicalKey == LogicalKeyboardKey.keyV) ||
          (isCtrl && isShift && event.logicalKey == LogicalKeyboardKey.keyV) ||
          (isCtrl && event.logicalKey == LogicalKeyboardKey.keyV)) {
        if (event is KeyDownEvent) {
          _pasteToTerminal();
        }
        return KeyEventResult.handled;
      }

      // Select All: Cmd+A (macOS) or Ctrl+Shift+A (Windows/Linux)
      if ((isMeta && event.logicalKey == LogicalKeyboardKey.keyA) ||
          (isCtrl && isShift && event.logicalKey == LogicalKeyboardKey.keyA)) {
        if (event is KeyDownEvent) {
          _selectAll();
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  // --- Screen Logging Support ---

  void _logStreamData(String rawText) {
    if (!_isScreenLogging || _screenLogSink == null) return;
    try {
      final cleanText = rawText.replaceAll(_ansiRegex, '');
      if (cleanText.isNotEmpty) {
        _screenLogSink!.write(cleanText);
        _screenLogBytesWritten += cleanText.length;
      }
    } catch (_) {}
  }

  Future<void> _startScreenLogging() async {
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final safeServerName = widget.server.name.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final fileName = 'mjolnir_${safeServerName}_$timestamp.log';

    final header = '''
================================================================================
Mjölnir SSH Screen Log
Server: ${widget.server.name} (${widget.server.username}@${widget.server.host}:${widget.server.port})
Started: ${DateTime.now().toLocal().toString()}
================================================================================
''';

    String selectedPath;
    final isMobile = Platform.isAndroid || Platform.isIOS;

    if (isMobile) {
      // On Android/iOS, FilePicker.saveFile returns a one-shot SAF content:// URI that cannot
      // be opened with File(...).openWrite(mode: FileMode.append). Stream to app documents first,
      // then offer to export when logging stops.
      final docDir = await getApplicationDocumentsDirectory();
      final logDir = Directory(p.join(docDir.path, 'Mjolnir', 'logs'));
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      selectedPath = p.join(logDir.path, fileName);
      await File(selectedPath).writeAsString(header, flush: true);
    } else {
      final savedUri = await FilePicker.saveFile(
        dialogTitle: 'Save Screen Log As',
        fileName: fileName,
        bytes: Uint8List.fromList(utf8.encode(header)),
      );

      if (savedUri == null || !mounted) return;
      selectedPath = savedUri.toFilePath();
    }

    try {
      final file = File(selectedPath);
      final sink = file.openWrite(mode: FileMode.append);

      // Dump current screen buffer lines if available
      final lineCount = terminal.buffer.lines.length;
      if (lineCount > 0) {
        sink.write('--- Screen Buffer Prior to Logging ---\n');
        for (var i = 0; i < lineCount; i++) {
          final line = terminal.buffer.lines[i];
          final lineStr = line.toString().trimRight();
          if (lineStr.isNotEmpty) {
            sink.write('$lineStr\n');
          }
        }
        sink.write('--- Live Screen Stream Begins ---\n\n');
      }
      await sink.flush();

      setState(() {
        _isScreenLogging = true;
        _screenLogPath = selectedPath;
        _screenLogSink = sink;
        _screenLogBytesWritten = 0;
      });

      if (mounted) {
        AppNotification.show(
          context,
          message: 'Screen logging started: ${p.basename(selectedPath)}',
          duration: const Duration(seconds: 2),
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.error(
          context,
          'Failed to start screen logging: $e',
        );
      }
    }
  }

  Future<void> _stopScreenLogging() async {
    if (!_isScreenLogging) return;
    final path = _screenLogPath;
    try {
      final footer = '''

================================================================================
Screen Logging Ended: ${DateTime.now().toLocal().toString()}
Total Characters Logged: $_screenLogBytesWritten
================================================================================
''';
      _screenLogSink?.write(footer);
      await _screenLogSink?.flush();
      await _screenLogSink?.close();
    } catch (_) {}

    setState(() {
      _isScreenLogging = false;
      _screenLogSink = null;
    });

    if (mounted && path != null) {
      final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
      AppNotification.show(
        context,
        message:
            'Screen log saved (${(_screenLogBytesWritten / 1024).toStringAsFixed(1)} KB): ${p.basename(path)}',
        actionLabel: isDesktop
            ? (Platform.isMacOS ? 'Show in Finder' : 'Open Folder')
            : 'Export Log',
        onAction: () {
          if (Platform.isMacOS) {
            Process.run('open', ['-R', path]);
          } else if (Platform.isWindows) {
            Process.run('explorer.exe', ['/select,$path']);
          } else if (Platform.isLinux) {
            Process.run('xdg-open', [File(path).parent.path]);
          } else {
            try {
              File(path).readAsBytes().then((bytes) {
                FilePicker.saveFile(
                  dialogTitle: 'Save Screen Log As',
                  fileName: p.basename(path),
                  bytes: bytes,
                );
              });
            } catch (_) {}
          }
        },
        duration: const Duration(seconds: 5),
      );
    }
  }

  // --- SSH & Local Shell Connection Handling ---

  Future<void> _connectLocalShell() async {
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      final session = await widget.localShellService.startLocalShellSession(
        terminalWidth: terminal.viewWidth > 0 ? terminal.viewWidth : 80,
        terminalHeight: terminal.viewHeight > 0 ? terminal.viewHeight : 24,
        terminalPixelWidth:
            _lastCellWidth > 0 ? terminal.viewWidth * _lastCellWidth : 0,
        terminalPixelHeight:
            _lastCellHeight > 0 ? terminal.viewHeight * _lastCellHeight : 0,
      );

      if (!mounted) {
        session.close();
        return;
      }

      _localSession = session;
      _isDisconnected = false;
      _disconnectReason = null;
      _reconnectAttempt = 0;
      _autoReconnectCancelled = false;

      if (!terminal.isUsingAltBuffer) {
        terminal.mainBuffer.resetVerticalMargins();
      }
      _syncRemotePtySize();

      session.stdout.listen(
        (data) {
          final text = utf8.decode(data, allowMalformed: true);
          _writeToTerminal(text);
          _logStreamData(text);
        },
        onError: (err) {
          final errStr = '\r\n[Local shell error: $err]\r\n';
          _writeToTerminal(errStr);
          _logStreamData(errStr);
        },
        onDone: () {
          final doneStr = '\r\n[Local shell exited]\r\n';
          _writeToTerminal(doneStr);
          _logStreamData(doneStr);
          _handleSessionDone();
        },
      );

      session.stderr.listen((data) {
        final text = utf8.decode(data, allowMalformed: true);
        _writeToTerminal(text);
        _logStreamData(text);
      });

      terminal.onOutput = (data) {
        if (_isDisconnected && !_isLoading) {
          if (data.contains('\r') || data.contains('\n') || data == ' ') {
            _reconnect();
            return;
          }
        }
        if (data == '\x1b[>0;0;0c') {
          session.write(Uint8List.fromList(utf8.encode('\x1b[>0;279;0c')));
          return;
        }
        if (_ctrlModifierActive && data.isNotEmpty) {
          final code = data.toLowerCase().codeUnitAt(0);
          setState(() => _ctrlModifierActive = false);
          if (code >= 97 && code <= 122) {
            session.write(Uint8List.fromList([code - 96]));
            if (data.length > 1) {
              session.write(
                Uint8List.fromList(utf8.encode(data.substring(1))),
              );
            }
            return;
          }
        }
        session.write(Uint8List.fromList(utf8.encode(data)));
      };

      terminal.onResize = _handleTerminalResize;

      setState(() {
        _isLoading = false;
        _isDisconnected = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          if (!terminal.isUsingAltBuffer) {
            terminal.mainBuffer.resetVerticalMargins();
          }
          _syncRemotePtySize();
        }
      });
      _requestTerminalFocus();
    } catch (e) {
      _autoReconnectCancelled = true;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
        _isDisconnected = true;
        _disconnectReason = e.toString();
      });
      final failMsg = '\r\n[Failed to start local shell: $e]\r\n';
      terminal.write(failMsg);
      _logStreamData(failMsg);
    }
  }

  Future<void> _connect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isExited = false;
      _reconnectCountdown = 0;
    });

    if (widget.isLocalShell) {
      await _connectLocalShell();
      return;
    }

    final connectMsg = 'Connecting to ${widget.server.username}@${widget.server.host}:${widget.server.port}...\r\n';
    terminal.write(connectMsg);
    _logStreamData(connectMsg);

    try {
      // Allow the first layout pass to complete so TerminalView has measured
      // the actual window / full-screen dimensions before requesting the PTY.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      final session = await widget.sshService.startShellSession(
        widget.server,
        terminalWidth: terminal.viewWidth > 0 ? terminal.viewWidth : 80,
        terminalHeight: terminal.viewHeight > 0 ? terminal.viewHeight : 24,
        terminalPixelWidth: _lastCellWidth > 0 ? terminal.viewWidth * _lastCellWidth : 0,
        terminalPixelHeight: _lastCellHeight > 0 ? terminal.viewHeight * _lastCellHeight : 0,
        getTerminalWidth: () => terminal.viewWidth,
        getTerminalHeight: () => terminal.viewHeight,
        getTerminalPixelWidth: () =>
            _lastCellWidth > 0 ? terminal.viewWidth * _lastCellWidth : 0,
        getTerminalPixelHeight: () =>
            _lastCellHeight > 0 ? terminal.viewHeight * _lastCellHeight : 0,
      );

      if (!mounted) {
        session.close();
        return;
      }

      _sshSession = session;
      _isDisconnected = false;
      _disconnectReason = null;
      _reconnectAttempt = 0;
      _autoReconnectCancelled = false;

      // Ensure remote PTY and local scroll margins match the current viewport
      // immediately (in case the window was resized/maximized while connecting).
      if (!terminal.isUsingAltBuffer) {
        terminal.mainBuffer.resetVerticalMargins();
      }
      _syncRemotePtySize();

      bool wasStdoutError = false;
      String? stdoutErrorMsg;

      // Pipe SSH stdout to terminal & screen log
      session.session.stdout.listen(
        (data) {
          final text = utf8.decode(data, allowMalformed: true);
          _writeToTerminal(text);
          _logStreamData(text);
        },
        onError: (err) {
          wasStdoutError = true;
          stdoutErrorMsg = err.toString();
          final errStr = '\r\n[SSH stdout error: $err]\r\n';
          _writeToTerminal(errStr);
          _logStreamData(errStr);
        },
        onDone: () {
          final isCleanExit = session.session.exitCode != null && !wasStdoutError;
          if (isCleanExit) {
            final doneStr = '\r\n[Session closed]\r\n';
            _writeToTerminal(doneStr);
            _logStreamData(doneStr);
            _handleSessionDone();
          } else {
            final reason = stdoutErrorMsg ?? 'Remote host or network connection terminated.';
            final dropMsg = '\r\n[Connection lost: $reason]\r\n';
            _writeToTerminal(dropMsg);
            _logStreamData(dropMsg);
            _handleUnexpectedDisconnect(reason);
          }
        },
      );

      // Pipe SSH stderr to terminal & screen log
      session.session.stderr.listen((data) {
        final text = utf8.decode(data, allowMalformed: true);
        _writeToTerminal(text);
        _logStreamData(text);
      });

      // Terminal user input to SSH stdin
      terminal.onOutput = (data) {
        if (_isDisconnected && !_isLoading) {
          // Pressing Enter or Space on a disconnected terminal attempts reconnect
          if (data.contains('\r') || data.contains('\n') || data == ' ') {
            _reconnect();
            return;
          }
        }
        if (data == '\x1b[>0;0;0c') {
          // Report modern xterm patch level (279) for Secondary Device
          // Attributes (DA2) so vim enables bracketed paste (\x1b[?2004h)
          //instead of treating the terminal as version 0.
          session.session.stdin.add(utf8.encode('\x1b[>0;279;0c'));
          return;
        }
        if (_ctrlModifierActive && data.isNotEmpty) {
          final code = data.toLowerCase().codeUnitAt(0);
          setState(() => _ctrlModifierActive = false);
          if (code >= 97 && code <= 122) {
            // Convert 'a'..'z' to Ctrl+A..Ctrl+Z (1..26)
            session.session.stdin.add(Uint8List.fromList([code - 96]));
            if (data.length > 1) {
              session.session.stdin.add(utf8.encode(data.substring(1)));
            }
            return;
          }
        }
        session.session.stdin.add(utf8.encode(data));
      };

      // Handle terminal resize events
      terminal.onResize = _handleTerminalResize;

      setState(() {
        _isLoading = false;
        _isDisconnected = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          if (!terminal.isUsingAltBuffer) {
            terminal.mainBuffer.resetVerticalMargins();
          }
          _syncRemotePtySize();
        }
      });
      _requestTerminalFocus();
    } catch (e) {
      if (e is HostKeyMismatchException) {
        _autoReconnectCancelled = true;
        _reconnectTimer?.cancel();
        setState(() {
          _isLoading = false;
          _errorMessage = 'HOST KEY VERIFICATION FAILED: REMOTE HOST IDENTIFICATION HAS CHANGED!';
          _isDisconnected = true;
          _disconnectReason = 'Host key mismatch for ${e.host}:${e.port} (Potential MITM Attack)';
        });
        final warning = '\r\n\x1b[1;31m'
            '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\r\n'
            '@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\r\n'
            '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\r\n'
            'IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!\r\n'
            'Someone could be eavesdropping on you right now (man-in-the-middle attack)!\r\n'
            'Host key verification failed for ${e.host}:${e.port} (${e.keyType}).\r\n'
            'Offending key fingerprint: ${e.receivedFingerprint}\r\n'
            'Expected fingerprint:      ${e.expectedFingerprint}\r\n'
            'Connection aborted to protect credentials and data integrity.\x1b[0m\r\n\r\n';
        terminal.write(warning);
        _logStreamData(warning);
        return;
      } else if (e is HostKeyUnknownException) {
        _autoReconnectCancelled = true;
        _reconnectTimer?.cancel();
        setState(() {
          _isLoading = false;
          _errorMessage = 'Host key verification rejected by user.';
          _isDisconnected = true;
          _disconnectReason = 'Host key unverified for ${e.host}:${e.port}';
        });
        final msg = '\r\n\x1b[1;33m[Host key verification declined for ${e.host}:${e.port}]\x1b[0m\r\n'
            'Connection aborted.\r\n\r\n';
        terminal.write(msg);
        _logStreamData(msg);
        return;
      }

      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
        _isDisconnected = true;
        _disconnectReason = e.toString();
      });
      final failMsg = '\r\n[Connection Failed: $e]\r\n';
      terminal.write(failMsg);
      _logStreamData(failMsg);

      if (!_autoReconnectCancelled && _reconnectAttempt < maxReconnectAttempts) {
        _startAutoReconnectCountdown();
      }
    }
  }

  void _handleUnexpectedDisconnect(String reason) {
    if (_isExited) return;
    _sshSession?.close();
    _sshSession = null;
    setState(() {
      _isLoading = false;
      _isDisconnected = true;
      _disconnectReason = reason;
    });

    if (!_autoReconnectCancelled && _reconnectAttempt < maxReconnectAttempts) {
      _startAutoReconnectCountdown();
    }
  }

  void _startAutoReconnectCountdown() {
    _reconnectTimer?.cancel();
    // Exponential backoff: 3s, 5s, 8s, 12s, 15s
    const backoffSeconds = [3, 5, 8, 12, 15];
    final delay = (_reconnectAttempt < backoffSeconds.length)
        ? backoffSeconds[_reconnectAttempt]
        : 15;

    setState(() {
      _reconnectCountdown = delay;
    });

    _reconnectTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_reconnectCountdown <= 1) {
        timer.cancel();
        _reconnectTimer = null;
        setState(() {
          _reconnectCountdown = 0;
          _reconnectAttempt++;
        });
        _reconnect();
      } else {
        setState(() {
          _reconnectCountdown--;
        });
      }
    });
  }

  Future<void> _reconnect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _sshSession?.close();
    _sshSession = null;
    _localSession?.close();
    _localSession = null;
    await _connect();
  }

  void _cancelAutoReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    setState(() {
      _reconnectCountdown = 0;
      _autoReconnectCancelled = true;
    });
  }

  void _handleSessionDone() {
    if (_isExited) return;
    _isExited = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopScreenLogging();
    if (mounted && widget.onClose != null) {
      widget.onClose!();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _sshSession?.close();
    _localSession?.close();
    _stopScreenLogging();
    _terminalController.dispose();
    _scrollController.dispose();
    _terminalFocusNode.dispose();
    super.dispose();
  }

  void _sendRawToShell(List<int> bytes) {
    final localSession = _localSession;
    if (localSession != null) {
      localSession.write(Uint8List.fromList(bytes));
      _requestTerminalFocus();
      return;
    }
    final session = _sshSession?.session;
    if (session != null) {
      session.stdin.add(Uint8List.fromList(bytes));
    }
    _requestTerminalFocus();
  }

  Widget _buildMobileAccessoryBar(AppColorScheme scheme) {
    Widget keyButton(
      String label, {
      required VoidCallback onTap,
      bool highlighted = false,
      IconData? icon,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Material(
          color: highlighted ? scheme.accentColor : scheme.elevatedSurface,
          borderRadius: BorderRadius.circular(5),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(5),
            child: Container(
              constraints: const BoxConstraints(minWidth: 38, minHeight: 32),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              alignment: Alignment.center,
              child: icon != null
                  ? Icon(
                      icon,
                      size: 16,
                      color: highlighted ? Colors.black : scheme.primaryText,
                    )
                  : Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: highlighted ? Colors.black : scheme.primaryText,
                      ),
                    ),
            ),
          ),
        ),
      );
    }

    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.panelBackground,
        border: Border(top: BorderSide(color: scheme.borderColor)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            keyButton(
              'ESC',
              onTap: () => _sendRawToShell([0x1B]),
            ),
            keyButton(
              'TAB',
              onTap: () => _sendRawToShell([0x09]),
            ),
            keyButton(
              'CTRL',
              highlighted: _ctrlModifierActive,
              onTap: () => setState(() => _ctrlModifierActive = !_ctrlModifierActive),
            ),
            keyButton(
              'CTRL+C',
              onTap: () => _sendRawToShell([0x03]),
            ),
            keyButton(
              '↑',
              onTap: () => terminal.keyInput(TerminalKey.arrowUp),
            ),
            keyButton(
              '↓',
              onTap: () => terminal.keyInput(TerminalKey.arrowDown),
            ),
            keyButton(
              '←',
              onTap: () => terminal.keyInput(TerminalKey.arrowLeft),
            ),
            keyButton(
              '→',
              onTap: () => terminal.keyInput(TerminalKey.arrowRight),
            ),
            keyButton(
              '-',
              onTap: () => _sendRawToShell(utf8.encode('-')),
            ),
            keyButton(
              '/',
              onTap: () => _sendRawToShell(utf8.encode('/')),
            ),
            keyButton(
              '|',
              onTap: () => _sendRawToShell(utf8.encode('|')),
            ),
            keyButton(
              'KB',
              icon: Icons.keyboard_alt_outlined,
              onTap: () {
                _terminalFocusNode.requestFocus();
                SystemChannels.textInput.invokeMethod('TextInput.show');
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReconnectBanner(AppColorScheme scheme) {
    final String message;
    if (_isLoading) {
      message = 'Reconnecting to ${widget.server.name}...';
    } else if (_reconnectCountdown > 0) {
      message = 'Connection lost. Auto-reconnecting in ${_reconnectCountdown}s (Attempt $_reconnectAttempt/$maxReconnectAttempts)...';
    } else if (_reconnectAttempt >= maxReconnectAttempts) {
      message = 'Connection lost. Auto-reconnect limit reached.';
    } else if (_autoReconnectCancelled) {
      message = 'Connection lost. Auto-reconnect paused.';
    } else {
      message = 'Connection lost${_errorMessage != null ? ": $_errorMessage" : (_disconnectReason != null ? ": $_disconnectReason" : "")}';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.15),
        border: Border(
          bottom: BorderSide(color: Colors.amberAccent.withValues(alpha: 0.4)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.wifi_off, size: 16, color: Colors.amberAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.amberAccent,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          if (_reconnectCountdown > 0) ...[
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _reconnect,
              child: const Text('Reconnect Now', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 6),
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _cancelAutoReconnect,
              child: const Text('Cancel', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          ] else if (!_isLoading) ...[
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Reconnect', style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _reconnect,
            ),
          ],
          const SizedBox(width: 8),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              _cancelAutoReconnect();
              _handleSessionDone();
            },
            child: const Text('Close Tab', style: TextStyle(fontSize: 12, color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final scheme = AppColorScheme.of(context);

    return Column(
      children: [
        // Connection Info & Control Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: scheme.panelBackground,
          child: Row(
            children: [
              Icon(
                Icons.terminal,
                size: 16,
                color: (_errorMessage != null || _isDisconnected)
                    ? Colors.amberAccent
                    : (_isLoading ? scheme.accentColor : Colors.greenAccent),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.isLocalShell
                      ? '${widget.server.name} (${_localSession?.shellPath ?? LocalShellService.resolveDefaultShell()})'
                      : '${widget.server.name} (${widget.server.username}@${widget.server.host})',
                  style: TextStyle(
                    color: scheme.primaryText,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.assignedTask != null)
                Flexible(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AssignedTabTaskBanner(
                      task: widget.assignedTask!,
                      onCompleteTask: () {
                        widget.onCompleteAssignedTask?.call();
                        _requestTerminalFocus();
                      },
                      onUnassignTask: () {
                        widget.onUnassignTask?.call();
                        _requestTerminalFocus();
                      },
                      onTaskChanged: (updatedTask) {
                        widget.onAssignedTaskChanged?.call(updatedTask);
                        _requestTerminalFocus();
                      },
                    ),
                  ),
                )
              else
                const Spacer(),

              // Scrollable right-hand toolbar controls so narrow screens never overflow
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.timerWidget != null) ...[
                      widget.timerWidget!,
                      Container(
                        height: 14,
                        width: 1,
                        color: scheme.borderColor,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                    ],

                    // Screen Logging Controls
                    if (_isScreenLogging)
                      InkWell(
                        onTap: _stopScreenLogging,
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.fiber_manual_record, size: 10, color: Colors.redAccent),
                              const SizedBox(width: 4),
                              Text(
                                'REC: ${p.basename(_screenLogPath ?? "log")}',
                                style: const TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.close, size: 12, color: Colors.redAccent),
                            ],
                          ),
                        ),
                      )
                    else
                      IconButton(
                        icon: Icon(Icons.fiber_manual_record_outlined, size: 15, color: scheme.mutedText),
                        tooltip: 'Start Screen Log (Save streamed terminal output to file)',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
                        onPressed: _startScreenLogging,
                      ),

                    // Divider
                    Container(
                      height: 14,
                      width: 1,
                      color: scheme.borderColor,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                    ),

                    // Copy & Paste Toolbar Buttons
                    IconButton(
                      icon: Icon(Icons.copy, size: 15, color: scheme.mutedText),
                      tooltip: 'Copy Selection (${Platform.isMacOS ? "⌘C" : "Ctrl+Shift+C"})',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
                      onPressed: _copySelection,
                    ),
                    IconButton(
                      icon: Icon(Icons.paste, size: 15, color: scheme.mutedText),
                      tooltip: 'Paste (${Platform.isMacOS ? "⌘V" : "Ctrl+V"})',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
                      onPressed: _pasteToTerminal,
                    ),

                    // Divider
                    Container(
                      height: 14,
                      width: 1,
                      color: scheme.borderColor,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                    ),

                    // Font size adjustment buttons
                    IconButton(
                      icon: Icon(Icons.remove, size: 14, color: scheme.mutedText),
                      tooltip: 'Decrease Font Size',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                      onPressed: _decreaseFontSize,
                    ),
                    InkWell(
                      onTap: _resetFontSize,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          '${_fontSize.toInt()}pt',
                          style: TextStyle(color: scheme.mutedText, fontSize: 11),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.add, size: 14, color: scheme.mutedText),
                      tooltip: 'Increase Font Size',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                      onPressed: _increaseFontSize,
                    ),

                    // Divider
                    Container(
                      height: 14,
                      width: 1,
                      color: scheme.borderColor,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                    ),

                    // ANSI Color Scheme Selector
                    PopupMenuButton<String>(
                      tooltip: 'ANSI Color Scheme: $_currentThemeName',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                      onSelected: _changeTheme,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: scheme.elevatedSurface,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: scheme.borderColor),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.palette_outlined, size: 12, color: scheme.accentColor),
                            const SizedBox(width: 4),
                            Text(
                              _currentThemeName,
                              style: TextStyle(fontSize: 11, color: scheme.primaryText),
                            ),
                            const SizedBox(width: 2),
                            Icon(Icons.arrow_drop_down, size: 13, color: scheme.mutedText),
                          ],
                        ),
                      ),
                      itemBuilder: (context) {
                        return AnsiThemes.all.keys.map((name) {
                          final isSelected = name == _currentThemeName;
                          final t = AnsiThemes.all[name]!;
                          return PopupMenuItem<String>(
                            value: name,
                            height: 32,
                            child: Row(
                              children: [
                                if (isSelected)
                                  Icon(Icons.check, size: 14, color: scheme.accentColor)
                                else
                                  const SizedBox(width: 14),
                                const SizedBox(width: 6),
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: t.background,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: t.foreground, width: 1.5),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(name, style: const TextStyle(fontSize: 12)),
                              ],
                            ),
                          );
                        }).toList();
                      },
                    ),

                    const SizedBox(width: 6),
                    if (_isLoading)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else if (_errorMessage != null || _isDisconnected)
                      IconButton(
                        icon: Icon(Icons.refresh, size: 16, color: scheme.accentColor),
                        tooltip: 'Reconnect',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                        onPressed: _reconnect,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Reconnect banner when disconnected
        if (_isDisconnected || (_errorMessage != null && !_isLoading))
          _buildReconnectBanner(scheme),

        // Terminal Window
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            removeBottom: true,
            removeLeft: true,
            removeRight: true,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _handlePointerDown,
              onPointerMove: _handlePointerMove,
              onPointerUp: _handlePointerUp,
              onPointerCancel: _handlePointerCancel,
              child: TerminalView(
                terminal,
                key: _terminalViewKey,
                controller: _terminalController,
                scrollController: _scrollController,
                focusNode: _terminalFocusNode,
                padding: EdgeInsets.zero,
                autofocus: true,
                hardwareKeyboardOnly: Platform.isWindows || Platform.isLinux || Platform.isMacOS,
                theme: _currentTheme,
                textStyle: TerminalStyle(
                  fontSize: _fontSize,
                ),
                backgroundOpacity: 1.0,
                shortcuts: const <ShortcutActivator, Intent>{},
                onKeyEvent: _handleTerminalKeyEvent,
                onTapUp: (details, offset) {
                  if (!_terminalFocusNode.hasFocus) {
                    _terminalFocusNode.requestFocus();
                  }
                },
                onSecondaryTapUp: (details, offset) {
                  _showContextMenu(details.globalPosition);
                },
              ),
            ),
          ),
        ),

        // Mobile Accessory Key Bar (ESC, TAB, CTRL, Arrows, Keyboard Toggle)
        if (isMobile) _buildMobileAccessoryBar(scheme),
      ],
    );
  }
}
