import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'models/server_config.dart';
import 'services/sync_storage_provider.dart';
import 'services/vault_manager.dart';
import 'services/ssh_service.dart';
import 'ui/terminal_tab_widget.dart';
import 'ui/sftp_tab_widget.dart';
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
  final String type; // 'ssh' or 'sftp'
  final ServerConfig server;
  String themeName;
  double fontSize;

  TabItem({
    required this.id,
    required this.title,
    this.color,
    required this.icon,
    required this.type,
    required this.server,
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
  }

  @override
  void dispose() {
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

  void _launchServerDefault(ServerConfig server) {
    if (server.connectionType == ConnectionType.sftp) {
      _openSftpTab(server);
    } else {
      _openTerminalTab(server);
    }
  }

  void _closeTab(String tabId) {
    final index = _openTabs.indexWhere((t) => t.id == tabId);
    if (index >= 0) {
      setState(() {
        _openTabs.removeAt(index);
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
                if (tab.type == 'ssh') {
                  tab.server.terminalTheme = selectedTheme;
                  await _vaultManager.saveServer(tab.server);
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
            IconButton(
              icon: const Icon(Icons.file_upload_outlined, size: 20),
              tooltip: 'Import JSON Connections',
              onPressed: _importVault,
            ),
            IconButton(
              icon: const Icon(Icons.file_download_outlined, size: 20),
              tooltip: 'Export JSON Connections',
              onPressed: _exportVault,
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
            if (_isSidebarCollapsed) ...[
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.view_sidebar, size: 16),
                label: const Text('Show Sidebar'),
                onPressed: () => setState(() => _isSidebarCollapsed = false),
              ),
            ],
          ],
        ),
      );
    }

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
              if (t.type == 'ssh') {
                return TerminalTabWidget(
                  key: ValueKey(t.id),
                  server: t.server,
                  sshService: _sshService,
                  theme: AnsiThemes.all[t.server.terminalTheme] ?? AnsiThemes.all[t.themeName] ?? TerminalThemes.defaultTheme,
                  initialThemeName: t.server.terminalTheme.isNotEmpty ? t.server.terminalTheme : t.themeName,
                  fontSize: t.fontSize,
                  isActive: tabIndex == _activeTabIndex,
                  onFontSizeChanged: (newSize) async {
                    t.fontSize = newSize;
                    t.server.terminalFontSize = newSize;
                    await _vaultManager.saveServer(t.server);
                  },
                  onThemeChanged: (newThemeName) async {
                    t.themeName = newThemeName;
                    t.server.terminalTheme = newThemeName;
                    await _vaultManager.saveServer(t.server);
                  },
                  onClose: () => _closeTab(t.id),
                );
              } else {
                return SftpTabWidget(
                  key: ValueKey(t.id),
                  server: t.server,
                  sshService: _sshService,
                );
              }
            }).toList(),
          ),
        ),
      ],
    );
  }
}

