import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'models/server_config.dart';
import 'models/task_item.dart';
import 'models/stored_string_item.dart';
import 'services/dropbox_sync_service.dart';
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

  TabItem({
    required this.id,
    required this.title,
    this.color,
    required this.icon,
    required this.type,
    this.server,
    this.themeName = 'Default Dark',
    this.fontSize = 13.0,
  });
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

class _MainScreenState extends State<MainScreen> {
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
    _dueDateTimer?.cancel();
    _masterPasswordController.dispose();
    super.dispose();
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
      setState(() {
        _activeTabIndex = existingIndex;
        _collapseSidebarIfNarrowScreen();
      });
      return;
    }

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
      setState(() {
        _activeTabIndex = existingIndex;
        _collapseSidebarIfNarrowScreen();
      });
      return;
    }

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

  Future<void> _exportToDropbox() async {
    final dropbox = _vaultManager.dropboxService;
    if (!dropbox.config.isConfigured) {
      _showDropboxDialog();
      return;
    }

    try {
      final dateStr = DateTime.now().toIso8601String().split('T').first;
      // Write both canonical servers.json and dated export in /App/Mjolnir
      final path = await _vaultManager.exportVaultToDropbox(fileName: 'servers.json');
      await _vaultManager.exportVaultToDropbox(fileName: 'mjolnir-servers-$dateStr.json');
      if (mounted) {
        AppNotification.show(
          context,
          message: 'Exported JSON vault to Dropbox ($path in ${dropbox.displayFolderPath}).',
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.error(
          context,
          'Dropbox export failed: $e',
        );
      }
    }
  }

  Future<void> _importFromDropbox() async {
    final dropbox = _vaultManager.dropboxService;
    if (!dropbox.config.isConfigured) {
      _showDropboxDialog();
      return;
    }

    final importPassController = TextEditingController();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Newest JSON from Dropbox'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Fetches the newest JSON file from Dropbox directory "${dropbox.displayFolderPath}" and merges connections & tasks.',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            const Text('Enter the Master Password used to encrypt the Dropbox vault:'),
            const SizedBox(height: 12),
            TextField(
              controller: importPassController,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Dropbox Vault Master Password',
                border: OutlineInputBorder(),
              ),
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
        final result = await _vaultManager.importNewestFromDropbox(
          importPassController.text,
        );
        if (mounted) {
          setState(() {});
          AppNotification.show(
            context,
            message:
                'Imported newest vault from Dropbox (${result.filePath}): ${result.serverCount} server(s) merged.',
          );
        }
      } catch (e) {
        if (mounted) {
          AppNotification.error(
            context,
            'Dropbox import failed: $e',
          );
        }
      }
    }
  }

  Future<void> _openExternalUrl(String url) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [url]);
      }
    } catch (_) {}
    await Clipboard.setData(ClipboardData(text: url));
  }

  void _showDropboxDialog() {
    final dropbox = _vaultManager.dropboxService;
    final tokenController = TextEditingController(text: dropbox.config.accessToken);
    final folderController = TextEditingController(
      text: dropbox.config.folderPath,
    );
    final appKeyController = TextEditingController(text: dropbox.config.appKey ?? '');
    final appSecretController = TextEditingController(text: dropbox.config.appSecret ?? '');
    final refreshTokenController = TextEditingController(text: dropbox.config.refreshToken ?? '');
    final authCodeController = TextEditingController();
    bool autoSync = dropbox.config.autoSyncOnLoadAndSave;
    bool showOAuthFields = (dropbox.config.appKey?.isNotEmpty ?? false) ||
        (dropbox.config.refreshToken?.isNotEmpty ?? false);
    bool isWorking = false;
    String? statusMsg;
    bool isError = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> saveSettings() async {
            final newConfig = DropboxConfig(
              accessToken: tokenController.text.trim(),
              appKey: appKeyController.text.trim().isEmpty ? null : appKeyController.text.trim(),
              appSecret: appSecretController.text.trim().isEmpty ? null : appSecretController.text.trim(),
              refreshToken: refreshTokenController.text.trim().isEmpty ? null : refreshTokenController.text.trim(),
              folderPath: folderController.text.trim(),
              autoSyncOnLoadAndSave: autoSync,
            );
            await _vaultManager.saveDropboxConfig(newConfig);
          }

          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.cloud_sync_outlined, color: Colors.amberAccent),
                SizedBox(width: 10),
                Text('Dropbox API Sync (All files / Apps / Mjolnir)'),
              ],
            ),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Sync, import, and export your encrypted JSON vault via Dropbox API. '
                      'Mjölnir syncs directly with your Dropbox app folder: All files / Apps / Mjolnir.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: folderController,
                      decoration: const InputDecoration(
                        labelText: 'Dropbox Subfolder (Optional)',
                        hintText: 'Leave empty for All files / Apps / Mjolnir',
                        helperText: 'Default root is All files / Apps / Mjolnir. Enter a subfolder only if desired.',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: tokenController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Dropbox API Access Token',
                        hintText: 'sl.u... (Generated in Dropbox App Console)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(Icons.open_in_new, size: 13),
                          label: const Text('Open Dropbox App Console to Generate Token', style: TextStyle(fontSize: 11)),
                          onPressed: () => _openExternalUrl('https://www.dropbox.com/developers/apps'),
                        ),
                        const Spacer(),
                        const Text(
                          'Console tokens expire in 4 hrs',
                          style: TextStyle(fontSize: 10, color: Colors.orangeAccent),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Use newest vault on load & auto-sync saves'),
                      subtitle: Text(
                        'Compares timestamps on startup and uses the newest JSON from ${dropbox.displayFolderPath}',
                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      value: autoSync,
                      onChanged: (val) => setDialogState(() => autoSync = val),
                    ),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      initiallyExpanded: showOAuthFields,
                      title: Row(
                        children: [
                          const Text(
                            'Permanent Sync: OAuth2 Offline Refresh Token',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(width: 8),
                          if (refreshTokenController.text.trim().isNotEmpty)
                            const Icon(Icons.check_circle, size: 14, color: Colors.green),
                        ],
                      ),
                      subtitle: const Text(
                        'Prevents 4-hour token expiration with background auto-refresh',
                        style: TextStyle(fontSize: 10, color: Colors.grey),
                      ),
                      children: [
                        if (refreshTokenController.text.trim().isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            margin: const EdgeInsets.only(bottom: 10),
                            decoration: BoxDecoration(
                              color: Colors.green.withAlpha(25),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.green.withAlpha(60)),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.check_circle_outline, color: Colors.green, size: 16),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Permanent auto-refresh active. Mjölnir will refresh expired access tokens automatically.',
                                    style: TextStyle(color: Colors.green, fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const Text(
                          'To enable permanent sync without token expiration:\n'
                          '1. In Dropbox App Console (Settings tab), copy your App Key.\n'
                          '2. In the Permissions tab, verify "files.content.write" and "files.content.read" are enabled.\n'
                          '3. Paste App Key below and click "1. Authorize in Browser" to get an authorization code.\n'
                          '4. Paste the code into Step 2 below and click "Exchange & Save".',
                          style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.3),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: appKeyController,
                          decoration: const InputDecoration(
                            labelText: 'Dropbox App Key',
                            hintText: 'Found in Dropbox App Console -> Settings',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: appSecretController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Dropbox App Secret (Optional)',
                            hintText: 'Leave empty if your app does not require a secret',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.open_in_browser, size: 16),
                            label: const Text('1. Authorize in Browser (Get Code)'),
                            onPressed: () async {
                              final key = appKeyController.text.trim();
                              if (key.isEmpty) {
                                setDialogState(() {
                                  isError = true;
                                  statusMsg = 'Please enter your Dropbox App Key first.';
                                });
                                return;
                              }
                              final authUrl =
                                  'https://www.dropbox.com/oauth2/authorize?client_id=$key&response_type=code&token_access_type=offline';
                              await _openExternalUrl(authUrl);
                              setDialogState(() {
                                isError = false;
                                statusMsg =
                                    'Opening Dropbox authorization in browser (link copied to clipboard). '
                                    'Click "Allow", then copy the code Dropbox provides and paste it into Step 2 below.';
                              });
                            },
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: authCodeController,
                                decoration: const InputDecoration(
                                  labelText: '2. Paste Authorization Code Here',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              onPressed: isWorking
                                  ? null
                                  : () async {
                                      if (appKeyController.text.trim().isEmpty ||
                                          authCodeController.text.trim().isEmpty) {
                                        setDialogState(() {
                                          isError = true;
                                          statusMsg = 'Enter App Key and Authorization Code first.';
                                        });
                                        return;
                                      }
                                      setDialogState(() {
                                        isWorking = true;
                                        statusMsg = 'Exchanging authorization code...';
                                        isError = false;
                                      });
                                      try {
                                        await saveSettings();
                                        await dropbox.exchangeAuthorizationCode(
                                          appKey: appKeyController.text,
                                          appSecret: appSecretController.text,
                                          authCode: authCodeController.text,
                                        );
                                        await _vaultManager.saveDropboxConfig(dropbox.config);
                                        tokenController.text = dropbox.config.accessToken;
                                        refreshTokenController.text = dropbox.config.refreshToken ?? '';
                                        setDialogState(() {
                                          isWorking = false;
                                          isError = false;
                                          statusMsg = 'Success! OAuth refresh token exchanged and saved. Permanent auto-sync is ready.';
                                        });
                                      } catch (e) {
                                        setDialogState(() {
                                          isWorking = false;
                                          isError = true;
                                          statusMsg = '$e';
                                        });
                                      }
                                    },
                              child: const Text('Exchange & Save'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: refreshTokenController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'OAuth2 Refresh Token (if already obtained)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                    const Divider(height: 20),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                          label: const Text('Verify Connection & Folder'),
                          onPressed: isWorking
                              ? null
                              : () async {
                                  setDialogState(() {
                                    isWorking = true;
                                    statusMsg = 'Checking ${dropbox.displayFolderPath} on Dropbox...';
                                    isError = false;
                                  });
                                  try {
                                    await saveSettings();
                                    await dropbox.ensureDirectoryExists();
                                    final files = await dropbox.listJsonFiles();
                                    tokenController.text = dropbox.config.accessToken;
                                    refreshTokenController.text = dropbox.config.refreshToken ?? '';
                                    setDialogState(() {
                                      isWorking = false;
                                      isError = false;
                                      statusMsg =
                                          'Connected! ${dropbox.displayFolderPath} is ready (${files.length} JSON file(s) found).';
                                    });
                                  } catch (e) {
                                    setDialogState(() {
                                      isWorking = false;
                                      isError = true;
                                      statusMsg = '$e';
                                    });
                                  }
                                },
                        ),
                        if (_vaultManager.isUnlocked) ...[
                          ElevatedButton.icon(
                            icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                            label: const Text('Export to Dropbox'),
                            onPressed: isWorking
                                ? null
                                : () async {
                                    setDialogState(() {
                                      isWorking = true;
                                      statusMsg = 'Uploading JSON vault to Dropbox...';
                                      isError = false;
                                    });
                                    try {
                                      await saveSettings();
                                      final dateStr = DateTime.now().toIso8601String().split('T').first;
                                      final path = await _vaultManager.exportVaultToDropbox(
                                        fileName: 'servers.json',
                                      );
                                      await _vaultManager.exportVaultToDropbox(
                                        fileName: 'mjolnir-servers-$dateStr.json',
                                      );
                                      tokenController.text = dropbox.config.accessToken;
                                      refreshTokenController.text = dropbox.config.refreshToken ?? '';
                                      setDialogState(() {
                                        isWorking = false;
                                        isError = false;
                                        statusMsg = 'Exported to $path in ${dropbox.displayFolderPath}!';
                                      });
                                    } catch (e) {
                                      setDialogState(() {
                                        isWorking = false;
                                        isError = true;
                                        statusMsg = '$e';
                                      });
                                    }
                                  },
                          ),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.cloud_download_outlined, size: 16),
                            label: const Text('Import Newest from Dropbox'),
                            onPressed: isWorking
                                ? null
                                : () async {
                                    await saveSettings();
                                    if (ctx.mounted) Navigator.of(ctx).pop();
                                    await _importFromDropbox();
                                  },
                          ),
                        ] else ...[
                          ElevatedButton.icon(
                            icon: const Icon(Icons.cloud_download_outlined, size: 16),
                            label: const Text('Load Newest Vault from Dropbox Now'),
                            onPressed: isWorking
                                ? null
                                : () async {
                                    setDialogState(() {
                                      isWorking = true;
                                      statusMsg = 'Checking Dropbox for newest vault...';
                                      isError = false;
                                    });
                                    try {
                                      await saveSettings();
                                      final loadedPath =
                                          await _vaultManager.checkAndLoadNewestFromDropbox();
                                      tokenController.text = dropbox.config.accessToken;
                                      refreshTokenController.text = dropbox.config.refreshToken ?? '';
                                      if (mounted) setState(() {});
                                      setDialogState(() {
                                        isWorking = false;
                                        isError = false;
                                        statusMsg = loadedPath != null
                                            ? 'Loaded newest vault from $loadedPath! Enter Master Password to unlock.'
                                            : 'Local vault is already up-to-date (or no newer file in Dropbox).';
                                      });
                                    } catch (e) {
                                      setDialogState(() {
                                        isWorking = false;
                                        isError = true;
                                        statusMsg = '$e';
                                      });
                                    }
                                  },
                          ),
                        ],
                      ],
                    ),
                    if (statusMsg != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isError
                              ? Colors.redAccent.withAlpha(30)
                              : Colors.greenAccent.withAlpha(25),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: isError ? Colors.redAccent : Colors.greenAccent.withAlpha(120),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              statusMsg!,
                              style: TextStyle(
                                fontSize: 12,
                                color: isError ? Colors.redAccent : Colors.greenAccent,
                              ),
                            ),
                            if (isError &&
                                (statusMsg!.contains('401') ||
                                    statusMsg!.contains('expired') ||
                                    statusMsg!.contains('unauthorized'))) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  TextButton.icon(
                                    style: TextButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      foregroundColor: Colors.amberAccent,
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                    ),
                                    icon: const Icon(Icons.open_in_new, size: 14),
                                    label: const Text(
                                      'Open Dropbox App Console to Generate New Token',
                                      style: TextStyle(fontSize: 11),
                                    ),
                                    onPressed: () => _openExternalUrl('https://www.dropbox.com/developers/apps'),
                                  ),
                                ],
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
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
              ElevatedButton(
                onPressed: isWorking
                    ? null
                    : () async {
                        await saveSettings();
                        if (_vaultManager.isUnlocked) {
                          if (autoSync && dropbox.config.isConfigured) {
                            try {
                              await _vaultManager.exportVaultToDropbox(fileName: 'servers.json');
                            } catch (e) {
                              debugPrint('Initial sync on save settings: $e');
                            }
                          }
                        } else if (autoSync && dropbox.config.isConfigured) {
                          try {
                            await _vaultManager.checkAndLoadNewestFromDropbox();
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
                    ? 'Enter the Master Password used to encrypt this JSON file (merges servers, tasks, strings, and encrypted Dropbox API credentials):'
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
              message: res.dropboxConfigured
                  ? 'Station ready: imported ${res.serverCount} server(s) and restored Dropbox API credentials.'
                  : 'Station ready: imported ${res.serverCount} server(s).',
            );
          }
        } else {
          final hadDropboxBefore = _vaultManager.dropboxService.config.isConfigured;
          final count = await _vaultManager.importVaultJson(content, importPassController.text);
          final hasDropboxNow = _vaultManager.dropboxService.config.isConfigured;
          if (mounted) {
            setState(() {});
            AppNotification.show(
              context,
              message: (!hadDropboxBefore && hasDropboxNow)
                  ? 'Imported and merged $count server(s) and restored Dropbox API credentials.'
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
                if (val == 'dropbox') _importFromDropbox();
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
                  value: 'dropbox',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.cloud_download_outlined, size: 18, color: scheme.accentColor),
                    title: const Text('Import Newest from Dropbox (All files / Apps / Mjolnir)'),
                  ),
                ),
              ],
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.file_download_outlined, size: 20),
              tooltip: 'Export JSON Connections',
              onSelected: (val) {
                if (val == 'local') _exportVault();
                if (val == 'dropbox') _exportToDropbox();
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
                  value: 'dropbox',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.cloud_upload_outlined, size: 18, color: scheme.accentColor),
                    title: const Text('Export to Dropbox (All files / Apps / Mjolnir)'),
                  ),
                ),
              ],
            ),
            IconButton(
              icon: Icon(
                Icons.cloud_sync_outlined,
                size: 20,
                color: _vaultManager.dropboxService.config.isConfigured
                    ? Colors.greenAccent
                    : null,
              ),
              tooltip: 'Dropbox API Settings & Sync (All files / Apps / Mjolnir)',
              onPressed: _showDropboxDialog,
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
                  color: _vaultManager.dropboxService.config.isConfigured
                      ? Colors.greenAccent
                      : scheme.accentColor,
                ),
                label: Text(
                  _vaultManager.dropboxService.config.isConfigured
                      ? 'Dropbox API Connected (${_vaultManager.dropboxService.displayFolderPath})'
                      : 'Configure Dropbox API (All files / Apps / Mjolnir)',
                  style: const TextStyle(fontSize: 12),
                ),
                onPressed: _showDropboxDialog,
              ),
              if (_vaultManager.loadedSource.startsWith('Dropbox'))
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
                                      setState(() {
                                        _activeTabIndex = index;
                                      });
                                    }
                                  }
                                },
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    if (_activeTabIndex != index) {
                                      setState(() {
                                        _activeTabIndex = index;
                                      });
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
}

