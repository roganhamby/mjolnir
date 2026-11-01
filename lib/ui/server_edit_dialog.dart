import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/server_config.dart';
import '../services/known_hosts_service.dart';
import '../theme/ansi_themes.dart';

class ServerEditDialog extends StatefulWidget {
  final ServerConfig? initialServer;
  final Function(ServerConfig server) onSave;

  const ServerEditDialog({
    super.key,
    this.initialServer,
    required this.onSave,
  });

  @override
  State<ServerEditDialog> createState() => _ServerEditDialogState();
}

class _ServerEditDialogState extends State<ServerEditDialog> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _nameController;
  late TextEditingController _hostController;
  late TextEditingController _portController;
  late TextEditingController _usernameController;
  late TextEditingController _groupController;
  late TextEditingController _remotePathController;
  late TextEditingController _passwordController;
  late TextEditingController _privateKeyController;
  late TextEditingController _passphraseController;
  late TextEditingController _expectedHostKeyController;

  List<KnownHostEntry> _knownEntries = [];
  ConnectionType _connectionType = ConnectionType.ssh;
  AuthType _authType = AuthType.password;
  bool _obscurePassword = true;
  late String _terminalTheme;

  @override
  void initState() {
    super.initState();
    final s = widget.initialServer;
    _nameController = TextEditingController(text: s?.name ?? '');
    _hostController = TextEditingController(text: s?.host ?? '');
    _portController = TextEditingController(text: s?.port.toString() ?? '22');
    _usernameController = TextEditingController(text: s?.username ?? 'root');
    _groupController = TextEditingController(text: s?.group ?? 'Default');
    _remotePathController = TextEditingController(
      text: (s != null && s.defaultRemotePath.trim().isNotEmpty)
          ? s.defaultRemotePath
          : '~/',
    );

    _connectionType = s?.connectionType ?? ConnectionType.ssh;
    _authType = s?.authType ?? AuthType.password;
    _terminalTheme = s?.terminalTheme ?? 'Default Dark';
    _passwordController = TextEditingController(text: s?.decryptedCredentials?.password ?? '');
    _privateKeyController = TextEditingController(text: s?.decryptedCredentials?.privateKey ?? '');
    _passphraseController = TextEditingController(text: s?.decryptedCredentials?.passphrase ?? '');
    _expectedHostKeyController = TextEditingController(text: s?.expectedHostKey ?? '');

    _loadKnownEntries();
  }

  Future<void> _loadKnownEntries() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 22;
    if (host.isNotEmpty) {
      final entries = await KnownHostsService.instance.getEntriesForHost(
        host: host,
        port: port,
      );
      if (mounted) {
        setState(() {
          _knownEntries = entries;
        });
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _groupController.dispose();
    _remotePathController.dispose();
    _passwordController.dispose();
    _privateKeyController.dispose();
    _passphraseController.dispose();
    _expectedHostKeyController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    final credentials = ServerCredentials(
      password: _authType == AuthType.password ? _passwordController.text : null,
      privateKey: _authType == AuthType.privateKey ? _privateKeyController.text : null,
      passphrase: _authType == AuthType.privateKey && _passphraseController.text.isNotEmpty
          ? _passphraseController.text
          : null,
    );

    final enteredRemotePath = _remotePathController.text.trim();
    final effectiveRemotePath = enteredRemotePath.isEmpty ? '~/' : enteredRemotePath;
    final isCustomRemotePath = effectiveRemotePath != '~/' && effectiveRemotePath != '~';

    final server = ServerConfig(
      id: widget.initialServer?.id ?? const Uuid().v4(),
      name: _nameController.text.trim(),
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 22,
      username: _usernameController.text.trim(),
      group: _groupController.text.trim().isEmpty ? 'Default' : _groupController.text.trim(),
      defaultRemotePath: effectiveRemotePath,
      customRemotePathSet: isCustomRemotePath,
      connectionType: _connectionType,
      authType: _authType,
      terminalFontSize: widget.initialServer?.terminalFontSize ?? 13.0,
      terminalTheme: _terminalTheme,
      expectedHostKey: _expectedHostKeyController.text.trim().isEmpty
          ? null
          : _expectedHostKeyController.text.trim(),
      decryptedCredentials: credentials,
    );

    widget.onSave(server);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.initialServer == null;

    return AlertDialog(
      title: Text(isNew ? 'Add Server' : 'Edit Server'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Display Name *'),
                  validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                ),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        controller: _hostController,
                        decoration: const InputDecoration(labelText: 'Host / IP *'),
                        validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 1,
                      child: TextFormField(
                        controller: _portController,
                        decoration: const InputDecoration(labelText: 'Port *'),
                        keyboardType: TextInputType.number,
                        validator: (v) => int.tryParse(v ?? '') == null ? 'Invalid' : null,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _usernameController,
                        decoration: const InputDecoration(labelText: 'Username *'),
                        validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _groupController,
                        decoration: const InputDecoration(labelText: 'Group / Tag'),
                      ),
                    ),
                  ],
                ),
                TextFormField(
                  controller: _remotePathController,
                  decoration: InputDecoration(
                    labelText: 'Default SFTP Directory',
                    hintText: '~/',
                    helperText: 'Defaults to ~/ (remote home). Specify an alternate path to override.',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.home_outlined, size: 18),
                      tooltip: 'Reset to ~/ (home directory)',
                      onPressed: () => setState(() => _remotePathController.text = '~/'),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Connection Default Type', style: TextStyle(fontWeight: FontWeight.bold)),
                Row(
                  children: [
                    Radio<ConnectionType>(
                      value: ConnectionType.ssh,
                      groupValue: _connectionType,
                      onChanged: (v) => setState(() => _connectionType = v!),
                    ),
                    const Text('SSH Terminal'),
                    const SizedBox(width: 16),
                    Radio<ConnectionType>(
                      value: ConnectionType.sftp,
                      groupValue: _connectionType,
                      onChanged: (v) => setState(() => _connectionType = v!),
                    ),
                    const Text('SFTP File Browser'),
                  ],
                ),
                if (_connectionType == ConnectionType.ssh) ...[
                  const SizedBox(height: 12),
                  const Text('ANSI Terminal Theme', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: _terminalTheme,
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
                        setState(() => _terminalTheme = val);
                      }
                    },
                  ),
                ],
                const SizedBox(height: 12),
                const Text('Authentication Method', style: TextStyle(fontWeight: FontWeight.bold)),
                Row(
                  children: [
                    Radio<AuthType>(
                      value: AuthType.password,
                      groupValue: _authType,
                      onChanged: (v) => setState(() => _authType = v!),
                    ),
                    const Text('Password'),
                    const SizedBox(width: 16),
                    Radio<AuthType>(
                      value: AuthType.privateKey,
                      groupValue: _authType,
                      onChanged: (v) => setState(() => _authType = v!),
                    ),
                    const Text('SSH Private Key'),
                  ],
                ),
                if (_authType == AuthType.password)
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                  )
                else ...[
                  TextFormField(
                    controller: _privateKeyController,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Private Key (OpenSSH/PEM)',
                      hintText: 'Paste PEM or OpenSSH private key contents here...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _passphraseController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Passphrase (if key is encrypted)',
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.security, size: 18, color: Colors.blueAccent),
                    const SizedBox(width: 8),
                    const Text(
                      'Host Key Verification & Pinning',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _expectedHostKeyController,
                  decoration: const InputDecoration(
                    labelText: 'Pinned Host Key Fingerprint (Optional)',
                    hintText: 'SHA256:...',
                    helperText: 'Enforce strict SHA256 fingerprint matching to prevent MITM attacks.',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
                if (_knownEntries.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.blueGrey.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blueGrey.withOpacity(0.2)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.verified_user, size: 16, color: Colors.green),
                            const SizedBox(width: 6),
                            Text(
                              'Stored Trusted Host Keys (${_knownEntries.length})',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ..._knownEntries.map((e) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${e.keyType}:',
                                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
                                        ),
                                        Text(
                                          e.fingerprint,
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  TextButton.icon(
                                    icon: const Icon(Icons.delete_outline, size: 14, color: Colors.orangeAccent),
                                    label: const Text('Reset', style: TextStyle(fontSize: 11, color: Colors.orangeAccent)),
                                    onPressed: () async {
                                      await KnownHostsService.instance.removeHostKey(
                                        host: e.host,
                                        port: e.port,
                                        keyType: e.keyType,
                                      );
                                      await _loadKnownEntries();
                                    },
                                  ),
                                ],
                              ),
                            )),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
