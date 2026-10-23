import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'models/server_config.dart';
import 'models/task_item.dart';
import 'services/dropbox_sync_service.dart';
import 'services/sync_storage_provider.dart';
import 'services/vault_manager.dart';
import 'services/ssh_service.dart';
import 'ui/terminal_tab_widget.dart';
import 'ui/sftp_tab_widget.dart';
import 'ui/task_manager_tab_widget.dart';
import 'ui/server_edit_dialog.dart';
import 'theme/ansi_themes.dart';
import 'package:xterm/xterm.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mjölnir',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.amber,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF252526),
          elevation: 0,
        ),
      ),
      home: const MainScreen(),
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
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late final VaultManager _vaultManager;
  final SshService _sshService = SshService();

  final List<TabItem> _openTabs = [];
  int _activeTabIndex = -1;
  bool _isSidebarCollapsed = false;
  Timer? _dueDateTimer;

  final TextEditingController _masterPasswordController = TextEditingController();
  bool _isDerivingKey = false;
  String? _unlockError;

  String _currentThemeName = 'Default Dark';

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
    _vaultManager = VaultManager(storageProvider: LocalFileSyncProvider());
    _vaultManager.init().then((_) {
      if (mounted) setState(() {});
    });
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
      _currentThemeName = themeToUse;
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
    });
  }

  void _openTaskManagerTab() {
    final existingIndex = _openTabs.indexWhere((t) => t.type == 'tasks');
    if (existingIndex >= 0) {
      setState(() {
        _activeTabIndex = existingIndex;
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

  void _launchServerDefault(ServerConfig server) {
    if (server.connectionType == ConnectionType.sftp) {
      _openSftpTab(server);
    } else {
      _openTerminalTab(server);
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
        if (_activeTabIndex >= 0 && _openTabs[_activeTabIndex].type == 'ssh') {
          _currentThemeName = _openTabs[_activeTabIndex].themeName;
        }
      });
    }
  }

  void _renameAndRecolorTab(TabItem tab) {
    final titleController = TextEditingController(text: tab.title);
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
                  if (_activeTabIndex >= 0 && _openTabs[_activeTabIndex] == tab) {
                    _currentThemeName = selectedTheme;
                  }
                });
                // Persist theme to server config
                if (tab.type == 'ssh' && tab.server != null) {
                  tab.server!.terminalTheme = selectedTheme;
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
      final jsonString = _vaultManager.exportVaultJson();
      final bytes = Uint8List.fromList(utf8.encode(jsonString));
      final dateStr = DateTime.now().toIso8601String().split('T').first;

      final savedUri = await FilePicker.saveFile(
        dialogTitle: 'Export Encrypted JSON Vault',
        fileName: 'mjolnir-servers-$dateStr.json',
        bytes: bytes,
      );

      if (savedUri != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Vault exported successfully.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported JSON vault to Dropbox ($path).')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Dropbox export failed: $e'),
            backgroundColor: Colors.red,
          ),
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
              'Fetches the newest JSON file from Dropbox directory "${dropbox.normalizedFolderPath}" and merges connections & tasks.',
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Imported newest vault from Dropbox (${result.filePath}): ${result.serverCount} server(s) merged.',
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Dropbox import failed: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  void _showDropboxDialog() {
    final dropbox = _vaultManager.dropboxService;
    final tokenController = TextEditingController(text: dropbox.config.accessToken);
    final folderController = TextEditingController(
      text: dropbox.config.folderPath.isEmpty ? '/App/Mjolnir' : dropbox.config.folderPath,
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
              folderPath: folderController.text.trim().isEmpty ? '/App/Mjolnir' : folderController.text.trim(),
              autoSyncOnLoadAndSave: autoSync,
            );
            await dropbox.saveConfig(newConfig);
          }

          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.cloud_sync_outlined, color: Colors.amberAccent),
                SizedBox(width: 10),
                Text('Dropbox API Sync (/App/Mjolnir)'),
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
                      'When loading, Mjölnir checks your Dropbox directory (default /App/Mjolnir) and automatically uses the newest vault.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: folderController,
                      decoration: const InputDecoration(
                        labelText: 'Dropbox Directory Path',
                        hintText: '/App/Mjolnir',
                        helperText: 'Mjölnir creates /App/Mjolnir automatically if it does not exist.',
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
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Use newest vault on load & auto-sync saves'),
                      subtitle: const Text(
                        'Compares timestamps on startup and uses the newest JSON from /App/Mjolnir',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      value: autoSync,
                      onChanged: (val) => setDialogState(() => autoSync = val),
                    ),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      initiallyExpanded: showOAuthFields,
                      title: const Text(
                        'Optional: OAuth2 Refresh Token / App Key',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      children: [
                        const SizedBox(height: 6),
                        TextField(
                          controller: appKeyController,
                          decoration: const InputDecoration(
                            labelText: 'Dropbox App Key',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: appSecretController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Dropbox App Secret',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
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
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: authCodeController,
                                decoration: const InputDecoration(
                                  labelText: 'Or Exchange Authorization Code',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
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
                                        tokenController.text = dropbox.config.accessToken;
                                        refreshTokenController.text = dropbox.config.refreshToken ?? '';
                                        setDialogState(() {
                                          isWorking = false;
                                          isError = false;
                                          statusMsg = 'OAuth token exchanged and saved!';
                                        });
                                      } catch (e) {
                                        setDialogState(() {
                                          isWorking = false;
                                          isError = true;
                                          statusMsg = '$e';
                                        });
                                      }
                                    },
                              child: const Text('Exchange'),
                            ),
                          ],
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
                          label: const Text('Verify / Create /App/Mjolnir'),
                          onPressed: isWorking
                              ? null
                              : () async {
                                  setDialogState(() {
                                    isWorking = true;
                                    statusMsg = 'Checking ${folderController.text.trim()} on Dropbox...';
                                    isError = false;
                                  });
                                  try {
                                    await saveSettings();
                                    await dropbox.ensureDirectoryExists();
                                    final files = await dropbox.listJsonFiles();
                                    setDialogState(() {
                                      isWorking = false;
                                      isError = false;
                                      statusMsg =
                                          'Connected! ${dropbox.normalizedFolderPath} is ready (${files.length} JSON file(s) found).';
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
                                      setDialogState(() {
                                        isWorking = false;
                                        isError = false;
                                        statusMsg = 'Exported to $path on Dropbox!';
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
                        child: Text(
                          statusMsg!,
                          style: TextStyle(
                            fontSize: 12,
                            color: isError ? Colors.redAccent : Colors.greenAccent,
                          ),
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
                        if (!_vaultManager.isUnlocked && autoSync && dropbox.config.isConfigured) {
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

      // Ask for the Master Password used when exporting the file
      final importPassController = TextEditingController();
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import Connections JSON'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Enter the Master Password used to encrypt this JSON file:'),
              const SizedBox(height: 12),
              TextField(
                controller: importPassController,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Import Master Password',
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
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Import & Merge'),
            ),
          ],
        ),
      );

      if (confirm == true && importPassController.text.isNotEmpty && mounted) {
        final count = await _vaultManager.importVaultJson(content, importPassController.text);
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Imported and merged $count server(s).')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e'), backgroundColor: Colors.red),
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

  @override
  Widget build(BuildContext context) {
    if (!_vaultManager.isUnlocked) {
      return _buildUnlockScreen();
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
                errorBuilder: (_, __, ___) => const Icon(Icons.bolt, color: Colors.amberAccent, size: 22),
              ),
              const SizedBox(width: 8),
              const Text('Mjölnir', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              const Text('• SSH & SFTP', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
          actions: [
            TextButton.icon(
              icon: Icon(
                Icons.task_alt,
                size: 18,
                color: _vaultManager.tasks.any((t) => t.isOverdue)
                    ? Colors.redAccent
                    : Colors.amberAccent,
              ),
              label: Text(
                _vaultManager.tasks.isEmpty
                    ? 'Tasks'
                    : 'Tasks (${_vaultManager.tasks.length})',
                style: TextStyle(
                  fontSize: 12,
                  color: _vaultManager.tasks.any((t) => t.isOverdue)
                      ? Colors.redAccent
                      : Colors.white,
                  fontWeight: _vaultManager.tasks.any((t) => t.isOverdue)
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
              onPressed: _openTaskManagerTab,
            ),
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
                const PopupMenuItem(
                  value: 'dropbox',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.cloud_download_outlined, size: 18, color: Colors.amberAccent),
                    title: Text('Import Newest from Dropbox (/App/Mjolnir)'),
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
                const PopupMenuItem(
                  value: 'dropbox',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.cloud_upload_outlined, size: 18, color: Colors.amberAccent),
                    title: Text('Export to Dropbox (/App/Mjolnir)'),
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
              tooltip: 'Dropbox API Settings & Sync (/App/Mjolnir)',
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
              decoration: const BoxDecoration(
                color: Color(0xFF252526),
              ),
              child: OverflowBox(
                minWidth: 280,
                maxWidth: 280,
                alignment: Alignment.topLeft,
                child: _buildSidebar(),
              ),
            ),
            if (!_isSidebarCollapsed)
              const VerticalDivider(width: 1, thickness: 1, color: Color(0xFF333333)),
            // Workspace: Tabs and Session View
            Expanded(
              child: _buildWorkspace(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUnlockScreen() {
    return Scaffold(
      body: Center(
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: const Color(0xFF252526),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF3C3C3C)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/app_icon.png',
                width: 64,
                height: 64,
                errorBuilder: (_, __, ___) => const Icon(Icons.bolt, size: 56, color: Colors.amberAccent),
              ),
              const SizedBox(height: 12),
              const Text(
                'Mjölnir',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              const Text(
                'Secure SSH & SFTP Sync Client',
                style: TextStyle(fontSize: 13, color: Colors.grey),
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
                  Icons.cloud_sync_outlined,
                  size: 16,
                  color: _vaultManager.dropboxService.config.isConfigured
                      ? Colors.greenAccent
                      : Colors.amberAccent,
                ),
                label: Text(
                  _vaultManager.dropboxService.config.isConfigured
                      ? 'Dropbox API Connected (${_vaultManager.dropboxService.normalizedFolderPath})'
                      : 'Configure Dropbox API (/App/Mjolnir)',
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

  Widget _buildSidebar() {
    final servers = _vaultManager.servers;

    return Column(
      children: [
        // Sidebar Header
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(
            color: Color(0xFF1E1E1E),
            border: Border(bottom: BorderSide(color: Color(0xFF333333))),
          ),
          child: Row(
            children: [
              const Icon(Icons.dns, size: 14, color: Colors.amberAccent),
              const SizedBox(width: 8),
              Text(
                'SERVERS (${servers.length})',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                  color: Colors.grey,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add, size: 16, color: Colors.grey),
                tooltip: 'Add Server',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                onPressed: () => _showAddOrEditServerDialog(),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.chevron_left, size: 18, color: Colors.grey),
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
                        const Icon(Icons.dns_outlined, size: 40, color: Colors.grey),
                        const SizedBox(height: 8),
                        const Text('No servers yet', style: TextStyle(color: Colors.grey)),
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

                    return ListTile(
                      dense: true,
                      leading: Icon(
                        isSftp ? Icons.folder_shared : Icons.computer,
                        size: 20,
                        color: Colors.amberAccent,
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(server.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isSftp ? Colors.blueGrey.withAlpha(80) : Colors.amber.withAlpha(60),
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
                          if (val == 'launch') _launchServerDefault(server);
                          if (val == 'ssh') _openTerminalTab(server);
                          if (val == 'sftp') _openSftpTab(server);
                          if (val == 'edit') _showAddOrEditServerDialog(server);
                          if (val == 'delete') _confirmDeleteServer(server);
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'launch',
                            child: Text('Connect (${isSftp ? 'SFTP' : 'SSH'})'),
                          ),
                          const PopupMenuItem(value: 'ssh', child: Text('Open SSH Terminal')),
                          const PopupMenuItem(value: 'sftp', child: Text('Open SFTP Browser')),
                          const PopupMenuDivider(),
                          const PopupMenuItem(value: 'edit', child: Text('Edit')),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete', style: TextStyle(color: Colors.redAccent)),
                          ),
                        ],
                      ),
                      onTap: () => _launchServerDefault(server),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildWorkspace() {
    if (_openTabs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.terminal_outlined, size: 56, color: Colors.grey),
            const SizedBox(height: 12),
            const Text(
              'Select a server from the sidebar to launch an SSH terminal or SFTP browser.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              children: [
                if (_isSidebarCollapsed)
                  ElevatedButton.icon(
                    icon: const Icon(Icons.view_sidebar, size: 16),
                    label: const Text('Show Sidebar'),
                    onPressed: () => setState(() => _isSidebarCollapsed = false),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.task_alt, size: 16, color: Colors.amberAccent),
                  label: const Text('Open Task Manager'),
                  onPressed: _openTaskManagerTab,
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
          color: const Color(0xFF1E1E1E),
          child: Row(
            children: [
              if (_isSidebarCollapsed)
                IconButton(
                  icon: const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
                  tooltip: 'Expand Sidebar (${Platform.isMacOS ? "⌘B" : "Ctrl+B"})',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 38),
                  onPressed: () => setState(() => _isSidebarCollapsed = false),
                ),
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _openTabs.length,
                  itemBuilder: (context, index) {
                    final tab = _openTabs[index];
                    final isActive = index == _activeTabIndex;
                    final tabHighlightColor = tab.color ?? (isActive ? Colors.amberAccent : Colors.transparent);
                    final assignedTask = (tab.type == 'ssh' || tab.type == 'sftp')
                        ? _getAssignedTaskForTab(tab.id)
                        : null;
                    final isTaskOverdue = assignedTask?.isOverdue ?? false;

                    return GestureDetector(
                      onTap: () => setState(() {
                        _activeTabIndex = index;
                        if (tab.type == 'ssh') {
                          _currentThemeName = tab.themeName;
                        }
                      }),
                      onSecondaryTap: () => _renameAndRecolorTab(tab),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: isActive ? const Color(0xFF252526) : const Color(0xFF1E1E1E),
                          border: Border(
                            top: BorderSide(
                              color: tabHighlightColor,
                              width: tab.color != null ? 3 : 2,
                            ),
                            right: const BorderSide(color: Color(0xFF333333)),
                          ),
                        ),
                        child: Row(
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
                            Icon(tab.icon, size: 14, color: isActive ? Colors.white : Colors.grey),
                            const SizedBox(width: 8),
                            Text(
                              tab.title,
                              style: TextStyle(
                                fontSize: 12,
                                color: isActive ? Colors.white : Colors.grey,
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
                                          color: isTaskOverdue ? Colors.redAccent : Colors.white,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (assignedTask.dueDate != null) ...[
                                      const SizedBox(width: 5),
                                      Text(
                                        DateFormat('HH:mm').format(assignedTask.dueDate!.toLocal()),
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: isTaskOverdue ? FontWeight.bold : FontWeight.normal,
                                          color: isTaskOverdue
                                              ? Colors.redAccent
                                              : Colors.grey.shade300,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(width: 6),
                            InkWell(
                              onTap: () => _renameAndRecolorTab(tab),
                              child: const Icon(Icons.edit, size: 12, color: Colors.grey),
                            ),
                            const SizedBox(width: 6),
                            InkWell(
                              onTap: () => _closeTab(tab.id),
                              child: const Icon(Icons.close, size: 14, color: Colors.grey),
                            ),
                          ],
                        ),
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
                );
              }
            }).toList(),
          ),
        ),
      ],
    );
  }
}

