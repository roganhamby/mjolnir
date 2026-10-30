import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'models/server_config.dart';
import 'models/task_item.dart';
import 'models/stored_string_item.dart';
import 'services/sftp_sync_service.dart';
import 'services/sync_storage_provider.dart';
import 'services/vault_manager.dart';
import 'services/ssh_service.dart';
import 'ui/terminal_tab_widget.dart';
import 'ui/sftp_tab_widget.dart';
import 'ui/task_manager_tab_widget.dart';
import 'ui/stored_strings_tab_widget.dart';
import 'ui/server_edit_dialog.dart';
import 'ui/app_notification.dart';
import 'theme/ansi_themes.dart';
import 'theme/app_color_schemes.dart';
import 'package:xterm/xterm.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  AppColorScheme _colorScheme = AppColorSchemes.mjolnirAmber;

  @override
  void initState() {
    super.initState();
    AppColorSchemes.loadSavedSchemeName().then((savedName) {
      if (mounted) {
        setState(() {
          _colorScheme = AppColorSchemes.byName(savedName);
        });
      }
    });
  }

  void _handleSchemeChanged(String schemeName) {
    final next = AppColorSchemes.byName(schemeName);
    setState(() {
      _colorScheme = next;
    });
    AppColorSchemes.saveSchemeName(next.name);
  }

  @override
  Widget build(BuildContext context) {
    final themeData = _colorScheme.toThemeData();
    return MaterialApp(
      navigatorKey: AppNotification.navigatorKey,
      title: 'Mjölnir',
      debugShowCheckedModeBanner: false,
      themeMode: _colorScheme.isDark ? ThemeMode.dark : ThemeMode.light,
      theme: themeData,
      darkTheme: themeData,
      home: MainScreen(
        currentColorScheme: _colorScheme,
        onColorSchemeChanged: _handleSchemeChanged,
      ),
    );
  }
}

class TabItem {
  final String id;
  String title;
  Color? color;
  final IconData icon;
  final String type; // 'ssh', 'sftp', or 'tasks'
  final ServerConfig? server;
  String themeName;
  double fontSize;
  int timerSeconds;
  bool isTimerRunning;
  Timer? _activeTimer;

  TabItem({
    required this.id,
    required this.title,
    this.color,
    required this.icon,
    required this.type,
    this.server,
    this.themeName = 'Default Dark',
    this.fontSize = 13.0,
    this.timerSeconds = 0,
    this.isTimerRunning = false,
  });

  void startTimer(VoidCallback onTick) {
    if (isTimerRunning) return;
    isTimerRunning = true;
    _activeTimer?.cancel();
    _activeTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      timerSeconds++;
      onTick();
    });
    onTick();
  }

  void stopTimer([VoidCallback? onStopped]) {
    if (!isTimerRunning && _activeTimer == null) return;
    isTimerRunning = false;
    _activeTimer?.cancel();
    _activeTimer = null;
    onStopped?.call();
  }

  void resetTimer([VoidCallback? onReset]) {
    stopTimer();
    timerSeconds = 0;
    onReset?.call();
  }

  String get formattedTimer {
    final hours = timerSeconds ~/ 3600;
    final minutes = (timerSeconds % 3600) ~/ 60;
    final seconds = timerSeconds % 60;
    final mStr = minutes.toString().padLeft(2, '0');
    final sStr = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$mStr:$sStr';
    }
    return '$mStr:$sStr';
  }
}

class MainScreen extends StatefulWidget {
  final AppColorScheme currentColorScheme;
  final ValueChanged<String>? onColorSchemeChanged;
  final VaultManager? vaultManager;

  const MainScreen({
    super.key,
    this.currentColorScheme = AppColorSchemes.mjolnirAmber,
    this.onColorSchemeChanged,
    this.vaultManager,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  late final VaultManager _vaultManager;
  final SshService _sshService = SshService();
  final GlobalKey _pasteboardButtonKey = GlobalKey();

  final List<TabItem> _openTabs = [];
  int _activeTabIndex = -1;
  bool _isSidebarCollapsed = false;
  Timer? _dueDateTimer;

  final TextEditingController _masterPasswordController = TextEditingController();
  bool _isDerivingKey = false;
  String? _unlockError;

  final List<Color> _availableColors = [
    Colors.blueAccent,
    Colors.tealAccent,
    Colors.greenAccent,
    Colors.amberAccent,
    Colors.orangeAccent,
    Colors.pinkAccent,
    Colors.purpleAccent,
    Colors.redAccent,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.vaultManager != null) {
      _vaultManager = widget.vaultManager!;
    } else {
      _vaultManager = VaultManager(storageProvider: LocalFileSyncProvider());
      _vaultManager.init().then((_) {
        if (mounted) setState(() {});
      });
    }
    _dueDateTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && _vaultManager.isUnlocked && _vaultManager.tasks.isNotEmpty) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAllTabTimers();
    _dueDateTimer?.cancel();
    _masterPasswordController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) {
      // Auto-stop timers when the window loses focus, is minimized, or goes to background
      _stopAllTabTimers();
    }
  }

  void _stopActiveTabTimer() {
    if (_activeTabIndex >= 0 && _activeTabIndex < _openTabs.length) {
      _openTabs[_activeTabIndex].stopTimer();
    }
  }

  void _stopAllTabTimers() {
    bool changed = false;
    for (final tab in _openTabs) {
      if (tab.isTimerRunning) {
        tab.stopTimer();
        changed = true;
      }
    }
    if (changed && mounted) {
      setState(() {});
    }
  }

  void _setActiveTabIndex(int newIndex) {
    if (_activeTabIndex == newIndex) return;
    _stopActiveTabTimer();
    setState(() {
      _activeTabIndex = newIndex;
    });
  }

  Future<void> _handleUnlock() async {
    final pass = _masterPasswordController.text;
    if (pass.isEmpty) return;

    setState(() {
      _isDerivingKey = true;
      _unlockError = null;
    });

    final success = await _vaultManager.unlock(pass);
    if (mounted) {
      setState(() {
        _isDerivingKey = false;
        if (!success) {
          _unlockError = _vaultManager.errorMessage ?? 'Incorrect master password.';
        } else {
          _masterPasswordController.clear();
        }
      });
    }
  }

  void _collapseSidebarIfNarrowScreen() {
    if (!mounted) return;
    if (MediaQuery.sizeOf(context).width < 650) {
      _isSidebarCollapsed = true;
    }
  }

  void _openTerminalTab(ServerConfig server) {
    _stopActiveTabTimer();
    final tabId = 'term-${server.id}-${DateTime.now().millisecondsSinceEpoch}';
    final themeToUse = server.terminalTheme.isNotEmpty
        ? server.terminalTheme
        : 'Default Dark';
    setState(() {
      _openTabs.add(
        TabItem(
          id: tabId,
          title: '${server.name} (SSH)',
          icon: Icons.terminal,
          color: null,
          type: 'ssh',
          server: server,
          themeName: themeToUse,
          fontSize: server.terminalFontSize,
        ),
      );
      _activeTabIndex = _openTabs.length - 1;
      _collapseSidebarIfNarrowScreen();
    });
  }

  void _openSftpTab(ServerConfig server) {
    _stopActiveTabTimer();
    final tabId = 'sftp-${server.id}-${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _openTabs.add(
        TabItem(
          id: tabId,
          title: '${server.name} (SFTP)',
          icon: Icons.folder_shared,
          color: null,
          type: 'sftp',
          server: server,
        ),
      );
      _activeTabIndex = _openTabs.length - 1;
      _collapseSidebarIfNarrowScreen();
    });
  }

  void _openTaskManagerTab() {
    final existingIndex = _openTabs.indexWhere((t) => t.type == 'tasks');
    if (existingIndex >= 0) {
      _setActiveTabIndex(existingIndex);
      _collapseSidebarIfNarrowScreen();
      return;
    }

    _stopActiveTabTimer();
    setState(() {
      _openTabs.add(
        TabItem(
          id: 'tasks-${DateTime.now().millisecondsSinceEpoch}',
          title: 'Task Manager',
          icon: Icons.task_alt,
          color: Colors.amberAccent,
          type: 'tasks',
        ),
      );
      _activeTabIndex = _openTabs.length - 1;
      _collapseSidebarIfNarrowScreen();
    });
  }

  void _openStoredStringsTab() {
    final existingIndex = _openTabs.indexWhere((t) => t.type == 'strings');
    if (existingIndex >= 0) {
      _setActiveTabIndex(existingIndex);
      _collapseSidebarIfNarrowScreen();
      return;
    }

    _stopActiveTabTimer();
    setState(() {
      _openTabs.add(
        TabItem(
          id: 'strings-${DateTime.now().millisecondsSinceEpoch}',
          title: 'Pasteboard',
          icon: Icons.content_paste,
          color: Colors.tealAccent,
          type: 'strings',
        ),
      );
      _activeTabIndex = _openTabs.length - 1;
      _collapseSidebarIfNarrowScreen();
    });
  }

  TaskItem? _getAssignedTaskForTab(String tabId) {
    for (final task in _vaultManager.tasks) {
      if (task.assignedTabId == tabId) {
        return task;
      }
    }
    return null;
  }

  void _assignTaskToTab(TaskItem task, String? tabId) {
    setState(() {
      if (tabId != null) {
        // Each tab can only have one task assigned at a time
        for (final other in _vaultManager.tasks) {
          if (other.assignedTabId == tabId && other.id != task.id) {
            other.assignedTabId = null;
          }
        }
      }
      task.assignedTabId = tabId;
    });
  }

  Future<void> _completeTask(String taskId) async {
    await _vaultManager.deleteTask(taskId);
    if (mounted) {
      setState(() {});
    }
  }

  void _showServerContextMenu(BuildContext context, Offset globalPos, ServerConfig server) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPos & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'ssh',
          child: Row(
            children: [
              Icon(Icons.terminal, size: 16),
              SizedBox(width: 8),
              Text('Open SSH Terminal'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'sftp',
          child: Row(
            children: [
              Icon(Icons.folder_shared, size: 16),
              SizedBox(width: 8),
              Text('Open SFTP Browser'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'edit',
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 16),
              SizedBox(width: 8),
              Text('Edit'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('Delete', style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    ).then((val) {
      if (val == 'ssh') _openTerminalTab(server);
      if (val == 'sftp') _openSftpTab(server);
      if (val == 'edit') _showAddOrEditServerDialog(server);
      if (val == 'delete') _confirmDeleteServer(server);
    });
  }

  void _showPasteboardContextMenu([Offset? globalPos]) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final scheme = AppColorScheme.of(context);
    final items = _vaultManager.storedStrings;

    Offset pos;
    if (globalPos != null) {
      pos = globalPos;
    } else {
      final btnBox = _pasteboardButtonKey.currentContext?.findRenderObject() as RenderBox?;
      if (btnBox != null && btnBox.hasSize) {
        pos = btnBox.localToGlobal(Offset(0, btnBox.size.height));
      } else {
        pos = Offset(overlay.size.width - 250, 50);
      }
    }

    final menuItems = <PopupMenuEntry<String>>[];

    if (items.isEmpty) {
      menuItems.add(
        const PopupMenuItem<String>(
          enabled: false,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.info_outline, size: 16),
              SizedBox(width: 8),
              Text('Pasteboard is empty'),
            ],
          ),
        ),
      );
    } else {
      for (final item in items) {
        final hasLabel = item.label.trim().isNotEmpty;
        final cleanValue = item.value
            .replaceAll('\r\n', ' ')
            .replaceAll('\n', ' ')
            .replaceAll('\t', ' ')
            .trim();
        final displayValue = cleanValue.length > 40
            ? '${cleanValue.substring(0, 40)}...'
            : cleanValue;

        menuItems.add(
          PopupMenuItem<String>(
            value: item.id,
            child: Row(
              children: [
                Icon(Icons.content_paste, size: 16, color: scheme.accentColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasLabel)
                        Text(
                          item.label.trim(),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: scheme.primaryText,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      Text(
                        displayValue.isEmpty ? '(empty)' : displayValue,
                        style: TextStyle(
                          fontSize: hasLabel ? 11 : 12,
                          fontFamily: 'monospace',
                          color: hasLabel ? scheme.mutedText : scheme.primaryText,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }

    menuItems.add(const PopupMenuDivider());
    menuItems.add(
      PopupMenuItem<String>(
        value: '__open_pasteboard_tab__',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tab, size: 16, color: scheme.accentColor),
            const SizedBox(width: 10),
            Text(
              'Open Pasteboard Tab',
              style: TextStyle(
                fontSize: 12,
                color: scheme.primaryText,
              ),
            ),
          ],
        ),
      ),
    );

    final selectedId = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        pos & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: menuItems,
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 360, maxHeight: 420),
    );

    if (selectedId == null || !mounted) return;

    if (selectedId == '__open_pasteboard_tab__') {
      _openStoredStringsTab();
      return;
    }

    StoredStringItem? selectedItem;
    for (final s in items) {
      if (s.id == selectedId) {
        selectedItem = s;
        break;
      }
    }

    if (selectedItem != null) {
      await Clipboard.setData(ClipboardData(text: selectedItem.value));
      if (!mounted) return;
      AppNotification.show(
        context,
        message: selectedItem.label.trim().isNotEmpty
            ? 'Copied "${selectedItem.label.trim()}" to clipboard.'
            : 'Copied string to clipboard.',
        duration: const Duration(seconds: 2),
      );
    }
  }

  Future<void> _closeTab(String tabId) async {
    final index = _openTabs.indexWhere((t) => t.id == tabId);
    if (index < 0) return;

    final assignedTask = _getAssignedTaskForTab(tabId);
    if (assignedTask != null && mounted) {
      final shouldCloseTask = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Active Task Assigned'),
          content: Text(
            'This tab has the task "${assignedTask.title}" assigned to it.\n\nWould you like to close (complete) the task too?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Keep Task Open'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Close Task Too'),
            ),
          ],
        ),
      );

      if (shouldCloseTask == true) {
        await _vaultManager.deleteTask(assignedTask.id);
      } else {
        assignedTask.assignedTabId = null;
      }
    }

    if (!mounted) return;
    final removeIndex = _openTabs.indexWhere((t) => t.id == tabId);
    if (removeIndex >= 0) {
      final tabToRemove = _openTabs[removeIndex];
      tabToRemove.stopTimer();
      _stopActiveTabTimer();
      setState(() {
        _openTabs.removeAt(removeIndex);
        if (_openTabs.isEmpty) {
          _activeTabIndex = -1;
        } else if (_activeTabIndex >= _openTabs.length) {
          _activeTabIndex = _openTabs.length - 1;
        }
      });
    }
  }

  void _renameAndRecolorTab(TabItem tab) {
    final titleController = TextEditingController(text: tab.title);
    final remotePathController = TextEditingController(
      text: (tab.server != null && tab.server!.defaultRemotePath.trim().isNotEmpty)
          ? tab.server!.defaultRemotePath.trim()
          : '~/',
    );
    Color? selectedColor = tab.color;
    String selectedTheme = tab.themeName;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Customize Tab'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: 'Tab Name',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (tab.type == 'ssh') ...[
                  const SizedBox(height: 16),
                  const Text('ANSI Terminal Theme:', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: selectedTheme,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    items: AnsiThemes.all.keys.map((themeName) {
                      return DropdownMenuItem(
                        value: themeName,
                        child: Text(themeName),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() => selectedTheme = val);
                      }
                    },
                  ),
                ],
                if (tab.type == 'sftp' && tab.server != null) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: remotePathController,
                    decoration: InputDecoration(
                      labelText: 'Default SFTP Directory',
                      hintText: '~/',
                      helperText: 'Defaults to ~/ (home). Specify an alternate default path to override.',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.home_outlined, size: 18),
                        tooltip: 'Reset to ~/',
                        onPressed: () => setDialogState(() => remotePathController.text = '~/'),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                const Text('Tab Color Tag:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('None'),
                      selected: selectedColor == null,
                      onSelected: (selected) {
                        setDialogState(() => selectedColor = null);
                      },
                    ),
                    ..._availableColors.map((color) {
                      return GestureDetector(
                        onTap: () {
                          setDialogState(() => selectedColor = color);
                        },
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: selectedColor == color
                                ? Border.all(color: Colors.white, width: 2.5)
                                : null,
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                setState(() {
                  tab.title = titleController.text.trim().isEmpty ? tab.title : titleController.text.trim();
                  tab.color = selectedColor;
                  tab.themeName = selectedTheme;
                });
                // Persist theme or default remote path to server config
                if (tab.type == 'ssh' && tab.server != null) {
                  tab.server!.terminalTheme = selectedTheme;
                  await _vaultManager.saveServer(tab.server!);
                } else if (tab.type == 'sftp' && tab.server != null) {
                  final entered = remotePathController.text.trim();
                  final effectivePath = entered.isEmpty ? '~/' : entered;
                  tab.server!.defaultRemotePath = effectivePath;
                  tab.server!.customRemotePathSet =
                      effectivePath != '~/' && effectivePath != '~';
                  await _vaultManager.saveServer(tab.server!);
                }
                if (context.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportVault() async {
    try {
      final jsonString = await _vaultManager.prepareAndExportVaultJson();
      final bytes = Uint8List.fromList(utf8.encode(jsonString));
      final dateStr = DateTime.now().toIso8601String().split('T').first;

      final savedUri = await FilePicker.saveFile(
        dialogTitle: 'Export Encrypted JSON Vault',
        fileName: 'mjolnir-servers-$dateStr.json',
        bytes: bytes,
      );

      if (savedUri != null && mounted) {
        AppNotification.success(
          context,
          'Vault exported successfully.',
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.error(
          context,
          'Export failed: $e',
        );
      }
    }
  }

  Future<void> _exportToSftp() async {
    final sftp = _vaultManager.sftpSyncService;
    if (!sftp.config.isConfigured) {
      _showSftpSyncDialog();
      return;
    }

    try {
      final dateStr = DateTime.now().toIso8601String().split('T').first;
      final path = await _vaultManager.exportVaultToSftp(fileName: 'servers.json');
      await _vaultManager.exportVaultToSftp(fileName: 'mjolnir-servers-$dateStr.json');
      if (mounted) {
        AppNotification.show(
          context,
          message: 'Exported JSON vault to SFTP server ($path on ${sftp.config.host}).',
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.error(
          context,
          'SFTP export failed: $e',
        );
      }
    }
  }

  Future<void> _importFromSftp() async {
    final sftp = _vaultManager.sftpSyncService;
    if (!sftp.config.isConfigured) {
      _showSftpSyncDialog();
      return;
    }

    final importPassController = TextEditingController();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Newest JSON from SFTP'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Fetches the newest JSON file from "${sftp.displayRemotePath}" on ${sftp.config.host} and merges connections & tasks.',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            const Text('Enter the Master Password used to encrypt the SFTP vault:'),
            const SizedBox(height: 12),
            TextField(
              controller: importPassController,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Vault Master Password',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.cloud_download_outlined, size: 16),
            onPressed: () => Navigator.of(ctx).pop(true),
            label: const Text('Import Newest & Merge'),
          ),
        ],
      ),
    );

    if (confirm == true && importPassController.text.isNotEmpty && mounted) {
      try {
        final result = await _vaultManager.importNewestFromSftp(
          importPassController.text,
        );
        if (mounted) {
          setState(() {});
          AppNotification.show(
            context,
            message:
                'Imported newest vault from SFTP (${result.filePath}): ${result.serverCount} server(s) merged.',
          );
        }
      } catch (e) {
        if (mounted) {
          AppNotification.error(
            context,
            'SFTP import failed: $e',
          );
        }
      }
    }
  }

  void _showSftpSyncDialog() {
    final sftp = _vaultManager.sftpSyncService;
    final hostController = TextEditingController(text: sftp.config.host);
    final portController = TextEditingController(text: sftp.config.port.toString());
    final usernameController = TextEditingController(text: sftp.config.username);
    final passwordController = TextEditingController(text: sftp.config.password ?? '');
    final privateKeyController = TextEditingController(text: sftp.config.privateKey ?? '');
    final passphraseController = TextEditingController(text: sftp.config.passphrase ?? '');
    final remotePathController = TextEditingController(text: sftp.config.remotePath);
    AuthType authType = sftp.config.authType;
    bool autoSync = sftp.config.autoSyncOnLoadAndSave;
    bool hidePassword = true;
    bool hidePassphrase = true;
    bool isWorking = false;
    String? statusMsg;
    bool isError = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          SftpSyncConfig buildConfigFromInputs() {
            final parsedPort = int.tryParse(portController.text.trim()) ?? 22;
            return SftpSyncConfig(
              host: hostController.text.trim(),
              port: parsedPort > 0 ? parsedPort : 22,
              username: usernameController.text.trim(),
              authType: authType,
              password: passwordController.text.isNotEmpty ? passwordController.text : null,
              privateKey: privateKeyController.text.trim().isNotEmpty ? privateKeyController.text.trim() : null,
              passphrase: passphraseController.text.isNotEmpty ? passphraseController.text : null,
              remotePath: remotePathController.text.trim().isNotEmpty ? remotePathController.text.trim() : '~/.mjolnir/servers.json',
              autoSyncOnLoadAndSave: autoSync,
            );
          }

          Future<void> saveSettings() async {
            final newConfig = buildConfigFromInputs();
            await _vaultManager.saveSftpSyncConfig(newConfig);
          }

          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.dns_outlined, color: Colors.cyanAccent),
                SizedBox(width: 10),
                Text('SFTP Server Sync (Dogfooding)'),
              ],
            ),
            content: SizedBox(
              width: 540,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Dogfooding: Sync your encrypted vaults directly to your own SSH/SFTP server across macOS, Windows, iOS, and Android without any third-party clouds or OAuth.\n'
                      'Your credentials remain AES-256-GCM encrypted and can only be decrypted with your Master Password.',
                      style: TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                    const SizedBox(height: 14),
                    if (_vaultManager.servers.isNotEmpty) ...[
                      DropdownButtonFormField<ServerConfig>(
                        decoration: const InputDecoration(
                          labelText: 'Quick Fill from Saved Server',
                          border: OutlineInputBorder(),
                          isDense: true,
                          prefixIcon: Icon(Icons.copy, size: 18),
                        ),
                        hint: const Text('Select a server to copy settings...'),
                        items: _vaultManager.servers.map((s) {
                          return DropdownMenuItem<ServerConfig>(
                            value: s,
                            child: Text(
                              '${s.name} (${s.username}@${s.host}:${s.port})',
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }).toList(),
                        onChanged: (selected) {
                          if (selected != null) {
                            setDialogState(() {
                              hostController.text = selected.host;
                              portController.text = selected.port.toString();
                              usernameController.text = selected.username;
                              authType = selected.authType;
                              passwordController.text = selected.decryptedCredentials?.password ?? '';
                              privateKeyController.text = selected.decryptedCredentials?.privateKey ?? '';
                              passphraseController.text = selected.decryptedCredentials?.passphrase ?? '';
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 14),
                    ],
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextField(
                            controller: hostController,
                            decoration: const InputDecoration(
                              labelText: 'SFTP Host / IP',
                              hintText: 'e.g. sftp.example.com or 192.168.1.50',
                              border: OutlineInputBorder(),
                              isDense: true,
                              prefixIcon: Icon(Icons.computer, size: 18),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 1,
                          child: TextField(
                            controller: portController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Port',
                              hintText: '22',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: usernameController,
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        hintText: 'e.g. root or admin',
                        border: OutlineInputBorder(),
                        isDense: true,
                        prefixIcon: Icon(Icons.person_outline, size: 18),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Authentication:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 12),
                        ChoiceChip(
                          label: const Text('Password', style: TextStyle(fontSize: 12)),
                          selected: authType == AuthType.password,
                          onSelected: (val) {
                            if (val) setDialogState(() => authType = AuthType.password);
                          },
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('Private Key', style: TextStyle(fontSize: 12)),
                          selected: authType == AuthType.privateKey,
                          onSelected: (val) {
                            if (val) setDialogState(() => authType = AuthType.privateKey);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (authType == AuthType.password)
                      TextField(
                        controller: passwordController,
                        obscureText: hidePassword,
                        decoration: InputDecoration(
                          labelText: 'SFTP Password',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          prefixIcon: const Icon(Icons.lock_outline, size: 18),
                          suffixIcon: IconButton(
                            icon: Icon(hidePassword ? Icons.visibility_off : Icons.visibility, size: 18),
                            onPressed: () => setDialogState(() => hidePassword = !hidePassword),
                          ),
                        ),
                      )
                    else ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Private Key (OpenSSH / PEM format):', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          TextButton.icon(
                            icon: const Icon(Icons.file_open, size: 16),
                            label: const Text('Pick Key File', style: TextStyle(fontSize: 12)),
                            onPressed: () async {
                              try {
                                final res = await FilePicker.pickFiles(
                                  dialogTitle: 'Select Private Key File',
                                  type: FileType.any,
                                );
                                if (res.isNotEmpty && res.first.path != null) {
                                  final file = File(res.first.path!);
                                  final text = await file.readAsString();
                                  setDialogState(() {
                                    privateKeyController.text = text;
                                  });
                                }
                              } catch (e) {
                                setDialogState(() {
                                  statusMsg = 'Failed to read key file: $e';
                                  isError = true;
                                });
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: privateKeyController,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: passphraseController,
                        obscureText: hidePassphrase,
                        decoration: InputDecoration(
                          labelText: 'Key Passphrase (Optional)',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          prefixIcon: const Icon(Icons.vpn_key_outlined, size: 18),
                          suffixIcon: IconButton(
                            icon: Icon(hidePassphrase ? Icons.visibility_off : Icons.visibility, size: 18),
                            onPressed: () => setDialogState(() => hidePassphrase = !hidePassphrase),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    TextField(
                      controller: remotePathController,
                      decoration: const InputDecoration(
                        labelText: 'Remote File Path',
                        hintText: '~/.mjolnir/servers.json',
                        helperText: 'Target file on remote server (e.g. ~/.mjolnir/servers.json). Parent folder is created automatically.',
                        helperMaxLines: 2,
                        border: OutlineInputBorder(),
                        isDense: true,
                        prefixIcon: Icon(Icons.folder_outlined, size: 18),
                      ),
                    ),
                    const SizedBox(height: 14),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Auto-sync vault on launch & save', style: TextStyle(fontSize: 13)),
                      subtitle: const Text(
                        'Compares timestamps on startup and loads the newest JSON from SFTP, and uploads when changes are saved locally.',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      value: autoSync,
                      onChanged: (val) {
                        setDialogState(() {
                          autoSync = val;
                        });
                      },
                    ),
                    const Divider(height: 24),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.cable, size: 16),
                          label: const Text('Test Connection', style: TextStyle(fontSize: 12)),
                          onPressed: isWorking
                              ? null
                              : () async {
                                  setDialogState(() {
                                    isWorking = true;
                                    statusMsg = 'Testing connection to ${hostController.text.trim()}...';
                                    isError = false;
                                  });
                                  try {
                                    final tempConfig = buildConfigFromInputs();
                                    final res = await sftp.testConnection(tempConfig);
                                    setDialogState(() {
                                      isWorking = false;
                                      statusMsg = res.message;
                                      isError = !res.success;
                                    });
                                  } catch (e) {
                                    setDialogState(() {
                                      isWorking = false;
                                      statusMsg = 'Connection error: $e';
                                      isError = true;
                                    });
                                  }
                                },
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                          label: const Text('Export Now', style: TextStyle(fontSize: 12)),
                          onPressed: isWorking || !_vaultManager.isUnlocked
                              ? null
                              : () async {
                                  setDialogState(() {
                                    isWorking = true;
                                    statusMsg = 'Exporting vault to SFTP...';
                                    isError = false;
                                  });
                                  try {
                                    await saveSettings();
                                    final path = await _vaultManager.exportVaultToSftp(fileName: 'servers.json');
                                    final dateStr = DateTime.now().toIso8601String().split('T').first;
                                    await _vaultManager.exportVaultToSftp(fileName: 'mjolnir-servers-$dateStr.json');
                                    setDialogState(() {
                                      isWorking = false;
                                      statusMsg = 'Successfully exported vault to $path on ${hostController.text.trim()}!';
                                      isError = false;
                                    });
                                  } catch (e) {
                                    setDialogState(() {
                                      isWorking = false;
                                      statusMsg = 'Export failed: $e';
                                      isError = true;
                                    });
                                  }
                                },
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.cloud_download_outlined, size: 16),
                          label: const Text('Import Now', style: TextStyle(fontSize: 12)),
                          onPressed: isWorking
                              ? null
                              : () async {
                                  if (!_vaultManager.isUnlocked) {
                                    setDialogState(() {
                                      statusMsg = 'Vault is locked. Unlock first or use Lock Screen setup.';
                                      isError = true;
                                    });
                                    return;
                                  }
                                  final masterPassCtrl = TextEditingController();
                                  final confirm = await showDialog<bool>(
                                    context: ctx,
                                    builder: (innerCtx) => AlertDialog(
                                      title: const Text('Confirm Import from SFTP'),
                                      content: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Text(
                                            'This will download the newest JSON file from the SFTP server and merge it into your active vault.',
                                          ),
                                          const SizedBox(height: 12),
                                          TextField(
                                            controller: masterPassCtrl,
                                            obscureText: true,
                                            decoration: const InputDecoration(
                                              labelText: 'Master Password for SFTP Vault',
                                              border: OutlineInputBorder(),
                                            ),
                                          ),
                                        ],
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.of(innerCtx).pop(false),
                                          child: const Text('Cancel'),
                                        ),
                                        ElevatedButton(
                                          onPressed: () => Navigator.of(innerCtx).pop(true),
                                          child: const Text('Import'),
                                        ),
                                      ],
                                    ),
                                  );

                                  if (confirm != true || masterPassCtrl.text.isEmpty) return;

                                  setDialogState(() {
                                    isWorking = true;
                                    statusMsg = 'Importing newest vault from SFTP...';
                                    isError = false;
                                  });
                                  try {
                                    await saveSettings();
                                    final res = await _vaultManager.importNewestFromSftp(masterPassCtrl.text);
                                    setDialogState(() {
                                      isWorking = false;
                                      statusMsg = 'Imported ${res.serverCount} server(s) from ${res.filePath}!';
                                      isError = false;
                                    });
                                    if (mounted) setState(() {});
                                  } catch (e) {
                                    setDialogState(() {
                                      isWorking = false;
                                      statusMsg = 'Import failed: $e';
                                      isError = true;
                                    });
                                  }
                                },
                        ),
                      ],
                    ),
                    if (statusMsg != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isError
                              ? Colors.redAccent.withOpacity(0.15)
                              : Colors.greenAccent.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: isError ? Colors.redAccent : Colors.greenAccent,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isError ? Icons.error_outline : Icons.check_circle_outline,
                              color: isError ? Colors.redAccent : Colors.greenAccent,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                statusMsg!,
                                style: TextStyle(
                                  color: isError ? Colors.redAccent : Colors.greenAccent,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: isWorking
                    ? null
                    : () async {
                        await saveSettings();
                        if (autoSync && sftp.config.isConfigured) {
                          try {
                            if (_vaultManager.isUnlocked) {
                              await _vaultManager.exportVaultToSftp(fileName: 'servers.json');
                            }
                          } catch (_) {}
                        }
                        if (mounted) setState(() {});
                        if (ctx.mounted) Navigator.of(ctx).pop();
                      },
                child: const Text('Save Settings'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _importVault() async {
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: 'Select Mjölnir JSON Vault to Import',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result.isEmpty || result.first.path == null) return;

      final file = File(result.first.path!);
      final content = await file.readAsString();

      if (!mounted) return;

      final isCurrentlyUnlocked = _vaultManager.isUnlocked;
      // Ask for the Master Password used when exporting the file (prefill if typed on lock screen)
      final importPassController = TextEditingController(
        text: isCurrentlyUnlocked ? '' : _masterPasswordController.text,
      );
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            isCurrentlyUnlocked
                ? 'Import Connections JSON'
                : 'Quick Station Setup from JSON',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isCurrentlyUnlocked
                    ? 'Enter the Master Password used to encrypt this JSON file (merges servers, tasks, strings, and encrypted SFTP sync credentials):'
                    : 'Enter the Master Password used to encrypt this JSON file to unlock and configure this station:',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: importPassController,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Vault Master Password',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => Navigator.of(ctx).pop(true),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(isCurrentlyUnlocked ? 'Import & Merge' : 'Import & Unlock'),
            ),
          ],
        ),
      );

      if (confirm == true && importPassController.text.isNotEmpty && mounted) {
        if (!isCurrentlyUnlocked) {
          final res = await _vaultManager.importAndUnlockVaultJson(
            content,
            importPassController.text,
          );
          _masterPasswordController.clear();
          if (mounted) {
            setState(() {});
            AppNotification.show(
              context,
              message: res.sftpConfigured
                  ? 'Station ready: imported ${res.serverCount} server(s) and restored SFTP Sync credentials.'
                  : 'Station ready: imported ${res.serverCount} server(s).',
            );
          }
        } else {
          final hadSftpBefore = _vaultManager.sftpSyncService.config.isConfigured;
          final count = await _vaultManager.importVaultJson(content, importPassController.text);
          final hasSftpNow = _vaultManager.sftpSyncService.config.isConfigured;
          if (mounted) {
            setState(() {});
            AppNotification.show(
              context,
              message: (!hadSftpBefore && hasSftpNow)
                  ? 'Imported and merged $count server(s) and restored SFTP Sync credentials.'
                  : 'Imported and merged $count server(s).',
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        AppNotification.error(
          context,
          'Import failed: $e',
        );
      }
    }
  }

  void _showAddOrEditServerDialog([ServerConfig? server]) {
    showDialog(
      context: context,
      builder: (ctx) => ServerEditDialog(
        initialServer: server,
        onSave: (updated) async {
          await _vaultManager.saveServer(updated);
          if (mounted) setState(() {});
        },
      ),
    );
  }

  void _confirmDeleteServer(ServerConfig server) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Server'),
        content: Text('Are you sure you want to remove "${server.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              final nav = Navigator.of(ctx);
              await _vaultManager.deleteServer(server.id);
              if (mounted) {
                nav.pop();
                setState(() {});
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Widget _buildColorSchemeMenuButton(AppColorScheme activeScheme) {
    return PopupMenuButton<String>(
      tooltip: 'App Color Scheme: ${activeScheme.name}',
      icon: Icon(
        Icons.palette_outlined,
        size: 20,
        color: activeScheme.accentColor,
      ),
      onSelected: (schemeName) {
        widget.onColorSchemeChanged?.call(schemeName);
      },
      itemBuilder: (ctx) {
        return AppColorSchemes.all.entries.map((entry) {
          final scheme = entry.value;
          final isSelected = scheme.name == activeScheme.name;
          return PopupMenuItem<String>(
            value: scheme.name,
            height: 36,
            child: Row(
              children: [
                if (isSelected)
                  Icon(Icons.check, size: 15, color: activeScheme.accentColor)
                else
                  const SizedBox(width: 15),
                const SizedBox(width: 8),
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: scheme.panelBackground,
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.accentColor, width: 2),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: scheme.accentColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  scheme.name,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          );
        }).toList();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = AppColorScheme.of(context);

    if (!_vaultManager.isUnlocked) {
      return _buildUnlockScreen(scheme);
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): () {
          setState(() => _isSidebarCollapsed = !_isSidebarCollapsed);
        },
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () {
          setState(() => _isSidebarCollapsed = !_isSidebarCollapsed);
        },
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: Icon(
              _isSidebarCollapsed ? Icons.view_sidebar_outlined : Icons.view_sidebar,
              size: 20,
            ),
            tooltip: _isSidebarCollapsed
                ? 'Expand Sidebar (${Platform.isMacOS ? "⌘B" : "Ctrl+B"})'
                : 'Collapse Sidebar (${Platform.isMacOS ? "⌘B" : "Ctrl+B"})',
            onPressed: () => setState(() => _isSidebarCollapsed = !_isSidebarCollapsed),
          ),
          title: Row(
            children: [
              Image.asset(
                'assets/app_icon.png',
                width: 24,
                height: 24,
                errorBuilder: (context, error, stackTrace) => Icon(Icons.bolt, color: scheme.accentColor, size: 22),
              ),
              const SizedBox(width: 8),
              Text('Mjölnir', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: scheme.primaryText)),
              const SizedBox(width: 8),
              Text('• SSH & SFTP', style: TextStyle(fontSize: 12, color: scheme.mutedText)),
            ],
          ),
          actions: [
            TextButton.icon(
              icon: Icon(
                Icons.task_alt,
                size: 18,
                color: _vaultManager.tasks.any((t) => t.isOverdue)
                    ? Colors.redAccent
                    : scheme.accentColor,
              ),
              label: Text(
                _vaultManager.tasks.isEmpty
                    ? 'Tasks'
                    : 'Tasks (${_vaultManager.tasks.length})',
                style: TextStyle(
                  fontSize: 12,
                  color: _vaultManager.tasks.any((t) => t.isOverdue)
                      ? Colors.redAccent
                      : scheme.primaryText,
                  fontWeight: _vaultManager.tasks.any((t) => t.isOverdue)
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
              onPressed: _openTaskManagerTab,
            ),
            GestureDetector(
              key: _pasteboardButtonKey,
              behavior: HitTestBehavior.opaque,
              onSecondaryTapUp: (details) =>
                  _showPasteboardContextMenu(details.globalPosition),
              onLongPressStart: (details) =>
                  _showPasteboardContextMenu(details.globalPosition),
              child: TextButton.icon(
                icon: Icon(
                  Icons.content_paste,
                  size: 18,
                  color: scheme.accentColor,
                ),
                label: Text(
                  _vaultManager.storedStrings.isEmpty
                      ? 'Pasteboard'
                      : 'Pasteboard (${_vaultManager.storedStrings.length})',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.primaryText,
                  ),
                ),
                onPressed: _openStoredStringsTab,
              ),
            ),
            _buildColorSchemeMenuButton(scheme),
            PopupMenuButton<String>(
              icon: const Icon(Icons.file_upload_outlined, size: 20),
              tooltip: 'Import JSON Connections',
              onSelected: (val) {
                if (val == 'local') _importVault();
                if (val == 'sftp') _importFromSftp();
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'local',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.folder_open, size: 18),
                    title: Text('Import from Local JSON File'),
                  ),
                ),
                PopupMenuItem(
                  value: 'sftp',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.dns_outlined, size: 18, color: scheme.accentColor),
                    title: Text(
                      _vaultManager.sftpSyncService.config.isConfigured
                          ? 'Import Newest from SFTP (${_vaultManager.sftpSyncService.config.host})'
                          : 'Import from SFTP Server...',
                    ),
                  ),
                ),
              ],
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.file_download_outlined, size: 20),
              tooltip: 'Export JSON Connections',
              onSelected: (val) {
                if (val == 'local') _exportVault();
                if (val == 'sftp') _exportToSftp();
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'local',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.save_alt, size: 18),
                    title: Text('Export to Local JSON File'),
                  ),
                ),
                PopupMenuItem(
                  value: 'sftp',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.cloud_upload_outlined, size: 18, color: scheme.accentColor),
                    title: Text(
                      _vaultManager.sftpSyncService.config.isConfigured
                          ? 'Export to SFTP (${_vaultManager.sftpSyncService.config.host})'
                          : 'Export to SFTP Server...',
                    ),
                  ),
                ),
              ],
            ),
            IconButton(
              icon: Icon(
                Icons.cloud_sync_outlined,
                size: 20,
                color: _vaultManager.sftpSyncService.config.isConfigured
                    ? Colors.greenAccent
                    : null,
              ),
              tooltip: _vaultManager.sftpSyncService.config.isConfigured
                  ? 'SFTP Sync Settings (${_vaultManager.sftpSyncService.config.host})'
                  : 'Configure SFTP Sync (Dogfooding)',
              onPressed: _showSftpSyncDialog,
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 20),
              tooltip: 'Add Server',
              onPressed: () => _showAddOrEditServerDialog(),
            ),
            IconButton(
              icon: const Icon(Icons.lock_outline, size: 20),
              tooltip: 'Lock Vault',
              onPressed: () {
                _stopAllTabTimers();
                setState(() {
                  _openTabs.clear();
                  _activeTabIndex = -1;
                  _vaultManager.lock();
                });
              },
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Row(
          children: [
            // Collapsible Sidebar: Server List
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              width: _isSidebarCollapsed ? 0 : 280,
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                color: scheme.panelBackground,
              ),
              child: OverflowBox(
                minWidth: 280,
                maxWidth: 280,
                alignment: Alignment.topLeft,
                child: _buildSidebar(scheme),
              ),
            ),
            if (!_isSidebarCollapsed)
              VerticalDivider(width: 1, thickness: 1, color: scheme.borderColor),
            // Workspace: Tabs and Session View
            Expanded(
              child: _buildWorkspace(scheme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUnlockScreen(AppColorScheme scheme) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          _buildColorSchemeMenuButton(scheme),
          const SizedBox(width: 12),
        ],
      ),
      body: Center(
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: scheme.panelBackground,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.borderColor),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/app_icon.png',
                width: 64,
                height: 64,
                errorBuilder: (context, error, stackTrace) => Icon(Icons.bolt, size: 56, color: scheme.accentColor),
              ),
              const SizedBox(height: 12),
              Text(
                'Mjölnir',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: scheme.primaryText),
              ),
              const SizedBox(height: 4),
              Text(
                'Secure SSH & SFTP Sync Client',
                style: TextStyle(fontSize: 13, color: scheme.mutedText),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _masterPasswordController,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Master Password',
                  border: const OutlineInputBorder(),
                  errorText: _unlockError,
                ),
                onSubmitted: (_) => _handleUnlock(),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton(
                  onPressed: _isDerivingKey ? null : _handleUnlock,
                  child: _isDerivingKey
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Unlock'),
                ),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                icon: Icon(
                  Icons.file_upload_outlined,
                  size: 16,
                  color: scheme.accentColor,
                ),
                label: const Text(
                  'Import JSON Vault (Quick Station Setup)',
                  style: TextStyle(fontSize: 12),
                ),
                onPressed: _importVault,
              ),
              TextButton.icon(
                icon: Icon(
                  Icons.cloud_sync_outlined,
                  size: 16,
                  color: _vaultManager.sftpSyncService.config.isConfigured
                      ? Colors.greenAccent
                      : scheme.accentColor,
                ),
                label: Text(
                  _vaultManager.sftpSyncService.config.isConfigured
                      ? 'SFTP Sync Connected (${_vaultManager.sftpSyncService.config.host})'
                      : 'Configure SFTP Sync (Dogfooding)',
                  style: const TextStyle(fontSize: 12),
                ),
                onPressed: _showSftpSyncDialog,
              ),
              if (_vaultManager.loadedSource.startsWith('SFTP'))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Loaded newest vault from ${_vaultManager.loadedSource}',
                    style: const TextStyle(fontSize: 11, color: Colors.greenAccent),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSidebar(AppColorScheme scheme) {
    final servers = _vaultManager.servers;

    return Column(
      children: [
        // Sidebar Header
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: scheme.scaffoldBackground,
            border: Border(bottom: BorderSide(color: scheme.borderColor)),
          ),
          child: Row(
            children: [
              Icon(Icons.dns, size: 14, color: scheme.accentColor),
              const SizedBox(width: 8),
              Text(
                'SERVERS (${servers.length})',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                  color: scheme.mutedText,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.add, size: 16, color: scheme.mutedText),
                tooltip: 'Add Server',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                onPressed: () => _showAddOrEditServerDialog(),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(Icons.chevron_left, size: 18, color: scheme.mutedText),
                tooltip: 'Collapse Sidebar (${Platform.isMacOS ? "⌘B" : "Ctrl+B"})',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                onPressed: () => setState(() => _isSidebarCollapsed = true),
              ),
            ],
          ),
        ),
        // Server List Content
        Expanded(
          child: servers.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.dns_outlined, size: 40, color: scheme.mutedText),
                        const SizedBox(height: 8),
                        Text('No servers yet', style: TextStyle(color: scheme.mutedText)),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add First Server'),
                          onPressed: () => _showAddOrEditServerDialog(),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: servers.length,
                  itemBuilder: (context, index) {
                    final server = servers[index];
                    final isSftp = server.connectionType == ConnectionType.sftp;

                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onSecondaryTapUp: (details) =>
                          _showServerContextMenu(context, details.globalPosition, server),
                      onLongPressStart: (details) =>
                          _showServerContextMenu(context, details.globalPosition, server),
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          isSftp ? Icons.folder_shared : Icons.computer,
                          size: 20,
                          color: scheme.accentColor,
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(server.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isSftp
                                    ? scheme.secondaryAccent.withValues(alpha: 0.22)
                                    : scheme.accentColor.withValues(alpha: 0.22),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                isSftp ? 'SFTP' : 'SSH',
                                style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        subtitle: Text('${server.username}@${server.host}:${server.port}',
                            style: const TextStyle(fontSize: 11)),
                        trailing: PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert, size: 16),
                          onSelected: (val) {
                            if (val == 'ssh') _openTerminalTab(server);
                            if (val == 'sftp') _openSftpTab(server);
                            if (val == 'edit') _showAddOrEditServerDialog(server);
                            if (val == 'delete') _confirmDeleteServer(server);
                          },
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                              value: 'ssh',
                              child: Row(
                                children: [
                                  Icon(Icons.terminal, size: 16),
                                  SizedBox(width: 8),
                                  Text('Open SSH Terminal'),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'sftp',
                              child: Row(
                                children: [
                                  Icon(Icons.folder_shared, size: 16),
                                  SizedBox(width: 8),
                                  Text('Open SFTP Browser'),
                                ],
                              ),
                            ),
                            const PopupMenuDivider(),
                            const PopupMenuItem(
                              value: 'edit',
                              child: Row(
                                children: [
                                  Icon(Icons.edit_outlined, size: 16),
                                  SizedBox(width: 8),
                                  Text('Edit'),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                                  SizedBox(width: 8),
                                  Text('Delete', style: TextStyle(color: Colors.redAccent)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildWorkspace(AppColorScheme scheme) {
    if (_openTabs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal_outlined, size: 56, color: scheme.mutedText),
            const SizedBox(height: 12),
            Text(
              'Right-click a server in the sidebar to open an SSH terminal or SFTP browser.',
              style: TextStyle(color: scheme.mutedText),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                if (_isSidebarCollapsed)
                  ElevatedButton.icon(
                    icon: const Icon(Icons.view_sidebar, size: 16),
                    label: const Text('Show Sidebar'),
                    onPressed: () => setState(() => _isSidebarCollapsed = false),
                  ),
                OutlinedButton.icon(
                  icon: Icon(Icons.task_alt, size: 16, color: scheme.accentColor),
                  label: const Text('Open Task Manager'),
                  onPressed: _openTaskManagerTab,
                ),
                OutlinedButton.icon(
                  icon: Icon(Icons.content_paste, size: 16, color: scheme.accentColor),
                  label: const Text('Open Pasteboard'),
                  onPressed: _openStoredStringsTab,
                ),
              ],
            ),
          ],
        ),
      );
    }

    final assignableTabs = _openTabs
        .where((t) => t.type == 'ssh' || t.type == 'sftp')
        .map((t) => AssignableTabInfo(id: t.id, title: t.title, type: t.type))
        .toList();

    return Column(
      children: [
        // Tab Header Bar
        Container(
          height: 38,
          color: scheme.scaffoldBackground,
          child: Row(
            children: [
              if (_isSidebarCollapsed)
                IconButton(
                  icon: Icon(Icons.chevron_right, size: 18, color: scheme.mutedText),
                  tooltip: 'Expand Sidebar (${Platform.isMacOS ? "⌘B" : "Ctrl+B"})',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 38),
                  onPressed: () => setState(() => _isSidebarCollapsed = false),
                ),
              Expanded(
                child: ReorderableListView.builder(
                  scrollDirection: Axis.horizontal,
                  buildDefaultDragHandles: false,
                  itemCount: _openTabs.length,
                  onReorder: (int oldIndex, int newIndex) {
                    setState(() {
                      if (oldIndex < newIndex) {
                        newIndex -= 1;
                      }
                      final activeTabId = (_activeTabIndex >= 0 && _activeTabIndex < _openTabs.length)
                          ? _openTabs[_activeTabIndex].id
                          : null;
                      final movedTab = _openTabs.removeAt(oldIndex);
                      _openTabs.insert(newIndex, movedTab);
                      if (activeTabId != null) {
                        _activeTabIndex = _openTabs.indexWhere((t) => t.id == activeTabId);
                      }
                    });
                  },
                  proxyDecorator: (Widget child, int index, Animation<double> animation) {
                    return AnimatedBuilder(
                      animation: animation,
                      builder: (BuildContext context, Widget? child) {
                        final double elevation = Tween<double>(begin: 0, end: 6).evaluate(animation);
                        return Material(
                          color: Colors.transparent,
                          shadowColor: Colors.black54,
                          elevation: elevation,
                          child: child,
                        );
                      },
                      child: child,
                    );
                  },
                  itemBuilder: (context, index) {
                    final tab = _openTabs[index];
                    final isActive = index == _activeTabIndex;
                    final tabHighlightColor = tab.color ?? (isActive ? scheme.accentColor : Colors.transparent);
                    final assignedTask = (tab.type == 'ssh' || tab.type == 'sftp')
                        ? _getAssignedTaskForTab(tab.id)
                        : null;
                    final isTaskOverdue = assignedTask?.isOverdue ?? false;

                    return Container(
                      key: ValueKey(tab.id),
                      height: 38,
                      decoration: BoxDecoration(
                        color: isActive ? scheme.panelBackground : scheme.scaffoldBackground,
                        border: Border(
                          top: BorderSide(
                            color: tabHighlightColor,
                            width: tab.color != null ? 3 : 2,
                          ),
                          right: BorderSide(color: scheme.borderColor),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ReorderableDragStartListener(
                            index: index,
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: Listener(
                                onPointerDown: (e) {
                                  if (e.buttons == kPrimaryMouseButton) {
                                    if (_activeTabIndex != index) {
                                      _setActiveTabIndex(index);
                                    }
                                  }
                                },
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    if (_activeTabIndex != index) {
                                      _setActiveTabIndex(index);
                                    }
                                  },
                                  onSecondaryTap: () => _renameAndRecolorTab(tab),
                                  onLongPress: () => _renameAndRecolorTab(tab),
                                  child: Container(
                                    color: Colors.transparent,
                                    padding: const EdgeInsets.only(left: 12, right: 6),
                                    alignment: Alignment.center,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (tab.color != null)
                                          Container(
                                            width: 8,
                                            height: 8,
                                            margin: const EdgeInsets.only(right: 6),
                                            decoration: BoxDecoration(
                                              color: tab.color,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                        Icon(tab.icon, size: 14, color: isActive ? scheme.primaryText : scheme.mutedText),
                                        const SizedBox(width: 8),
                                        Text(
                                          tab.title,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: isActive ? scheme.primaryText : scheme.mutedText,
                                            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                                          ),
                                        ),
                                        if (assignedTask != null) ...[
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: isTaskOverdue
                                                  ? Colors.redAccent.withAlpha(45)
                                                  : assignedTask.importance.color.withAlpha(35),
                                              borderRadius: BorderRadius.circular(4),
                                              border: Border.all(
                                                color: isTaskOverdue
                                                    ? Colors.redAccent
                                                    : assignedTask.importance.color.withAlpha(140),
                                                width: 1,
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  isTaskOverdue ? Icons.warning_amber_rounded : Icons.task_alt,
                                                  size: 11,
                                                  color: isTaskOverdue
                                                      ? Colors.redAccent
                                                      : assignedTask.importance.color,
                                                ),
                                                const SizedBox(width: 4),
                                                ConstrainedBox(
                                                  constraints: const BoxConstraints(maxWidth: 160),
                                                  child: Text(
                                                    assignedTask.title,
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight: FontWeight.w600,
                                                      color: isTaskOverdue ? Colors.redAccent : scheme.primaryText,
                                                    ),
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                if (assignedTask.subtasks.isNotEmpty) ...[
                                                  const SizedBox(width: 5),
                                                  Text(
                                                    '(${assignedTask.completedSubtaskCount}/${assignedTask.subtasks.length})',
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      fontWeight: FontWeight.w600,
                                                      color: assignedTask.completedSubtaskCount ==
                                                              assignedTask.subtasks.length
                                                          ? Colors.greenAccent
                                                          : scheme.mutedText,
                                                    ),
                                                  ),
                                                ],
                                                if (assignedTask.dueDate != null) ...[
                                                  const SizedBox(width: 5),
                                                  Text(
                                                    DateFormat('HH:mm').format(assignedTask.dueDate!.toLocal()),
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      fontWeight: isTaskOverdue ? FontWeight.bold : FontWeight.normal,
                                                      color: isTaskOverdue
                                                          ? Colors.redAccent
                                                          : scheme.mutedText,
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          _buildTabTimerWidget(tab, index, isActive, scheme),
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(3),
                              onTap: () => _renameAndRecolorTab(tab),
                              child: Padding(
                                padding: const EdgeInsets.all(4.0),
                                child: Icon(Icons.edit, size: 12, color: scheme.mutedText),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(3),
                              onTap: () => _closeTab(tab.id),
                              child: Padding(
                                padding: const EdgeInsets.all(4.0),
                                child: Icon(Icons.close, size: 14, color: scheme.mutedText),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        // Active Tab View Content
        Expanded(
          child: IndexedStack(
            index: _activeTabIndex >= 0 ? _activeTabIndex : 0,
            children: _openTabs.asMap().entries.map((entry) {
              final tabIndex = entry.key;
              final t = entry.value;
              final assignedTask = (t.type == 'ssh' || t.type == 'sftp')
                  ? _getAssignedTaskForTab(t.id)
                  : null;

              if (t.type == 'tasks') {
                return TaskManagerTabWidget(
                  key: ValueKey(t.id),
                  tasks: _vaultManager.tasks,
                  availableTabs: assignableTabs,
                  onSaveTask: (task) async {
                    await _vaultManager.saveTask(task);
                    if (mounted) setState(() {});
                  },
                  onCompleteTask: _completeTask,
                  onAssignTaskToTab: _assignTaskToTab,
                );
              } else if (t.type == 'strings') {
                return StoredStringsTabWidget(
                  key: ValueKey(t.id),
                  storedStrings: _vaultManager.storedStrings,
                  onSaveStoredString: (item) async {
                    await _vaultManager.saveStoredString(item);
                    if (mounted) setState(() {});
                  },
                  onDeleteStoredString: (id) async {
                    await _vaultManager.deleteStoredString(id);
                    if (mounted) setState(() {});
                  },
                );
              } else if (t.type == 'ssh') {
                final server = t.server!;
                return TerminalTabWidget(
                  key: ValueKey(t.id),
                  server: server,
                  sshService: _sshService,
                  theme: AnsiThemes.all[server.terminalTheme] ?? AnsiThemes.all[t.themeName] ?? TerminalThemes.defaultTheme,
                  initialThemeName: server.terminalTheme.isNotEmpty ? server.terminalTheme : t.themeName,
                  fontSize: t.fontSize,
                  isActive: tabIndex == _activeTabIndex,
                  assignedTask: assignedTask,
                  onCompleteAssignedTask: assignedTask != null
                      ? () => _completeTask(assignedTask.id)
                      : null,
                  onUnassignTask: assignedTask != null
                      ? () => _assignTaskToTab(assignedTask, null)
                      : null,
                  onAssignedTaskChanged: (updatedTask) async {
                    await _vaultManager.saveTask(updatedTask);
                    if (mounted) setState(() {});
                  },
                  onFontSizeChanged: (newSize) async {
                    t.fontSize = newSize;
                    server.terminalFontSize = newSize;
                    await _vaultManager.saveServer(server);
                  },
                  onThemeChanged: (newThemeName) async {
                    t.themeName = newThemeName;
                    server.terminalTheme = newThemeName;
                    await _vaultManager.saveServer(server);
                  },
                  onClose: () => _closeTab(t.id),
                );
              } else {
                final server = t.server!;
                return SftpTabWidget(
                  key: ValueKey(t.id),
                  server: server,
                  sshService: _sshService,
                  assignedTask: assignedTask,
                  onCompleteAssignedTask: assignedTask != null
                      ? () => _completeTask(assignedTask.id)
                      : null,
                  onUnassignTask: assignedTask != null
                      ? () => _assignTaskToTab(assignedTask, null)
                      : null,
                  onAssignedTaskChanged: (updatedTask) async {
                    await _vaultManager.saveTask(updatedTask);
                    if (mounted) setState(() {});
                  },
                  onDefaultRemotePathChanged: (newDefaultPath) async {
                    server.defaultRemotePath = newDefaultPath;
                    server.customRemotePathSet =
                        newDefaultPath != '~/' && newDefaultPath != '~';
                    await _vaultManager.saveServer(server);
                    if (mounted) setState(() {});
                  },
                );
              }
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildTabTimerWidget(TabItem tab, int index, bool isActive, AppColorScheme scheme) {
    final isRunning = tab.isTimerRunning;
    final hasElapsed = tab.timerSeconds > 0;

    final Color timerColor;
    final Color timerBg;
    final Color timerBorder;

    if (isRunning) {
      timerColor = Colors.greenAccent;
      timerBg = Colors.greenAccent.withAlpha(35);
      timerBorder = Colors.greenAccent.withAlpha(160);
    } else if (hasElapsed) {
      timerColor = isActive ? scheme.accentColor : scheme.primaryText;
      timerBg = scheme.elevatedSurface.withAlpha(120);
      timerBorder = scheme.borderColor;
    } else {
      timerColor = scheme.mutedText.withAlpha(180);
      timerBg = Colors.transparent;
      timerBorder = scheme.borderColor.withAlpha(60);
    }

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: isRunning
                ? 'Stop timer (auto-stops when tab is clicked off or window loses focus)'
                : (hasElapsed
                    ? 'Resume timer (auto-stops when tab is clicked off or window loses focus)'
                    : 'Start timer (auto-stops when tab is clicked off or window loses focus)'),
            waitDuration: const Duration(milliseconds: 500),
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () {
                if (isRunning) {
                  tab.stopTimer(() {
                    if (mounted) setState(() {});
                  });
                } else {
                  if (_activeTabIndex != index) {
                    _setActiveTabIndex(index);
                  }
                  tab.startTimer(() {
                    if (mounted) setState(() {});
                  });
                  if (mounted) setState(() {});
                }
              },
              child: Container(
                height: 22,
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: timerBg,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: timerBorder, width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isRunning ? Icons.pause : Icons.play_arrow,
                      size: 11,
                      color: timerColor,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      tab.formattedTimer,
                      style: TextStyle(
                        fontSize: 11,
                        color: timerColor,
                        fontWeight: isRunning || hasElapsed ? FontWeight.w600 : FontWeight.normal,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (hasElapsed && !isRunning) ...[
            const SizedBox(width: 2),
            Tooltip(
              message: 'Reset timer to 00:00',
              waitDuration: const Duration(milliseconds: 500),
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () {
                  tab.resetTimer(() {
                    if (mounted) setState(() {});
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.all(3.0),
                  child: Icon(Icons.refresh, size: 12, color: scheme.mutedText),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

