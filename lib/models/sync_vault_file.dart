import 'dart:convert';
import 'server_config.dart';
import '../services/crypto_vault_service.dart';

class SyncVaultFile {
  int version;
  String appId;
  DateTime updatedAt;
  String salt;
  List<ServerConfig> servers;

  SyncVaultFile({
    this.version = 1,
    this.appId = 'com.serversync.mjolnir',
    DateTime? updatedAt,
    required this.salt,
    List<ServerConfig>? servers,
  })  : updatedAt = updatedAt ?? DateTime.now().toUtc(),
        servers = servers ?? [];

  /// Factory for a brand new empty vault file
  factory SyncVaultFile.createEmpty() {
    return SyncVaultFile(
      salt: CryptoVaultService.generateRandomSalt(),
      servers: [],
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'app_id': appId,
        'updated_at': updatedAt.toIso8601String(),
        'crypto_params': {
          'kdf': 'Argon2id',
          'salt': salt,
          'iterations': 3,
          'memory_kb': 65536,
        },
        'servers': servers.map((s) => s.toJson()).toList(),
      };

  factory SyncVaultFile.fromJson(Map<String, dynamic> json) {
    final cryptoParams = json['crypto_params'] as Map<String, dynamic>? ?? {};
    final serverList = (json['servers'] as List<dynamic>? ?? [])
        .map((e) => ServerConfig.fromJson(e as Map<String, dynamic>))
        .toList();

    return SyncVaultFile(
      version: json['version'] as int? ?? 1,
      appId: json['app_id'] as String? ?? 'com.serversync.mjolnir',
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
      salt: cryptoParams['salt'] as String? ?? CryptoVaultService.generateRandomSalt(),
      servers: serverList,
    );
  }

  String toFormattedJson() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  /// Merges remote servers with current servers based on per-server updatedAt timestamps.
  void mergeWith(SyncVaultFile remoteVault) {
    final Map<String, ServerConfig> currentMap = {
      for (var s in servers) s.id: s,
    };

    for (final remoteServer in remoteVault.servers) {
      if (!currentMap.containsKey(remoteServer.id)) {
        // New remote server
        servers.add(remoteServer);
      } else {
        final localServer = currentMap[remoteServer.id]!;
        if (remoteServer.updatedAt.isAfter(localServer.updatedAt)) {
          // Remote server is newer, replace local
          final index = servers.indexOf(localServer);
          servers[index] = remoteServer;
        }
      }
    }

    updatedAt = DateTime.now().toUtc();
  }
}
