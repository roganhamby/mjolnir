import 'package:cryptography/cryptography.dart';
import '../services/crypto_vault_service.dart';

enum AuthType {
  password,
  privateKey,
}

enum ConnectionType {
  ssh,
  sftp,
}

class ServerCredentials {
  final String? password;
  final String? privateKey;
  final String? passphrase;

  ServerCredentials({
    this.password,
    this.privateKey,
    this.passphrase,
  });

  Map<String, dynamic> toJson() => {
        if (password != null) 'password': password,
        if (privateKey != null) 'privateKey': privateKey,
        if (passphrase != null) 'passphrase': passphrase,
      };

  factory ServerCredentials.fromJson(Map<String, dynamic> json) {
    return ServerCredentials(
      password: json['password'] as String?,
      privateKey: json['privateKey'] as String?,
      passphrase: json['passphrase'] as String?,
    );
  }
}

class ServerConfig {
  final String id;
  String name;
  String host;
  int port;
  String username;
  String group;
  String defaultRemotePath;
  bool customRemotePathSet;
  ConnectionType connectionType;
  AuthType authType;
  double terminalFontSize;
  String terminalTheme;
  String? expectedHostKey;
  Map<String, dynamic>? encryptedCredentials;
  DateTime updatedAt;

  // Cached decrypted credentials (only present in memory while unlocked)
  ServerCredentials? decryptedCredentials;

  ServerConfig({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.group = 'Default',
    this.defaultRemotePath = '~/',
    this.customRemotePathSet = false,
    this.connectionType = ConnectionType.ssh,
    this.authType = AuthType.password,
    this.terminalFontSize = 13.0,
    this.terminalTheme = 'Default Dark',
    this.expectedHostKey,
    this.encryptedCredentials,
    DateTime? updatedAt,
    this.decryptedCredentials,
  }) : updatedAt = updatedAt ?? DateTime.now().toUtc();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'group': group,
        'default_remote_path': defaultRemotePath,
        'custom_remote_path_set': customRemotePathSet,
        'connection_type': connectionType.name,
        'auth_type': authType.name,
        'terminal_font_size': terminalFontSize,
        'terminal_theme': terminalTheme,
        if (expectedHostKey != null && expectedHostKey!.trim().isNotEmpty)
          'expected_host_key': expectedHostKey!.trim(),
        'encrypted_credentials': encryptedCredentials,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    final rawPath = (json['default_remote_path'] as String?)?.trim();
    final customSet = json['custom_remote_path_set'] as bool? ??
        (rawPath != null && rawPath.isNotEmpty && rawPath != '/' && rawPath != '~/');
    final resolvedDefaultPath = (rawPath == null ||
            rawPath.isEmpty ||
            (rawPath == '/' && !customSet))
        ? '~/'
        : rawPath;

    return ServerConfig(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Untitled Server',
      host: json['host'] as String? ?? 'localhost',
      port: json['port'] as int? ?? 22,
      username: json['username'] as String? ?? 'root',
      group: json['group'] as String? ?? 'Default',
      defaultRemotePath: resolvedDefaultPath,
      customRemotePathSet: customSet,
      connectionType: ConnectionType.values.firstWhere(
        (e) => e.name == json['connection_type'],
        orElse: () => ConnectionType.ssh,
      ),
      authType: AuthType.values.firstWhere(
        (e) => e.name == json['auth_type'],
        orElse: () => AuthType.password,
      ),
      terminalFontSize: (json['terminal_font_size'] as num?)?.toDouble() ?? 13.0,
      terminalTheme: json['terminal_theme'] as String? ?? 'Default Dark',
      expectedHostKey: json['expected_host_key'] as String?,
      encryptedCredentials: json['encrypted_credentials'] as Map<String, dynamic>?,
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
    );
  }

  /// Encrypts in-memory credentials into encryptedCredentials blob.
  Future<void> encrypt(CryptoVaultService vaultService, SecretKey masterKey) async {
    if (decryptedCredentials == null) return;
    encryptedCredentials = await vaultService.encryptPayload(
      payload: decryptedCredentials!.toJson(),
      masterKey: masterKey,
    );
    updatedAt = DateTime.now().toUtc();
  }

  /// Decrypts stored encryptedCredentials into in-memory decryptedCredentials.
  Future<void> decrypt(CryptoVaultService vaultService, SecretKey masterKey) async {
    if (encryptedCredentials == null) return;
    final payload = await vaultService.decryptPayload(
      encryptedData: encryptedCredentials!,
      masterKey: masterKey,
    );
    decryptedCredentials = ServerCredentials.fromJson(payload);
  }
}
