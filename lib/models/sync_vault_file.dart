import 'dart:convert';
import 'server_config.dart';
import 'stored_string_item.dart';
import 'task_item.dart';
import '../services/crypto_vault_service.dart';

class SyncVaultFile {
  int version;
  String appId;
  DateTime updatedAt;
  String salt;
  Map<String, dynamic>? encryptedDropboxConfig;
  List<ServerConfig> servers;
  List<TaskItem> tasks;
  List<StoredStringItem> storedStrings;

  SyncVaultFile({
    this.version = 1,
    this.appId = 'com.serversync.mjolnir',
    DateTime? updatedAt,
    required this.salt,
    this.encryptedDropboxConfig,
    List<ServerConfig>? servers,
    List<TaskItem>? tasks,
    List<StoredStringItem>? storedStrings,
  })  : updatedAt = updatedAt ?? DateTime.now().toUtc(),
        servers = servers ?? [],
        tasks = tasks ?? [],
        storedStrings = storedStrings ?? [];

  /// Factory for a brand new empty vault file
  factory SyncVaultFile.createEmpty() {
    return SyncVaultFile(
      salt: CryptoVaultService.generateRandomSalt(),
      servers: [],
      tasks: [],
      storedStrings: [],
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
        if (encryptedDropboxConfig != null)
          'encrypted_dropbox_config': encryptedDropboxConfig,
        'servers': servers.map((s) => s.toJson()).toList(),
        'tasks': tasks.map((t) => t.toJson()).toList(),
        'stored_strings': storedStrings.map((s) => s.toJson()).toList(),
      };

  factory SyncVaultFile.fromJson(Map<String, dynamic> json) {
    final cryptoParams = json['crypto_params'] as Map<String, dynamic>? ?? {};
    final serverList = (json['servers'] as List<dynamic>? ?? [])
        .map((e) => ServerConfig.fromJson(e as Map<String, dynamic>))
        .toList();
    final taskList = (json['tasks'] as List<dynamic>? ?? [])
        .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
        .toList();
    final stringList = (json['stored_strings'] as List<dynamic>? ?? [])
        .map((e) => StoredStringItem.fromJson(e as Map<String, dynamic>))
        .toList();

    return SyncVaultFile(
      version: json['version'] as int? ?? 1,
      appId: json['app_id'] as String? ?? 'com.serversync.mjolnir',
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
      salt: cryptoParams['salt'] as String? ?? CryptoVaultService.generateRandomSalt(),
      encryptedDropboxConfig:
          json['encrypted_dropbox_config'] as Map<String, dynamic>?,
      servers: serverList,
      tasks: taskList,
      storedStrings: stringList,
    );
  }

  String toFormattedJson() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  /// Merges remote servers, tasks, and stored strings with current vault based on per-item updatedAt timestamps.
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

    final Map<String, TaskItem> currentTaskMap = {
      for (var t in tasks) t.id: t,
    };

    for (final remoteTask in remoteVault.tasks) {
      if (!currentTaskMap.containsKey(remoteTask.id)) {
        tasks.add(remoteTask);
      } else {
        final localTask = currentTaskMap[remoteTask.id]!;
        if (remoteTask.updatedAt.isAfter(localTask.updatedAt)) {
          remoteTask.assignedTabId = localTask.assignedTabId;
          final index = tasks.indexOf(localTask);
          tasks[index] = remoteTask;
        }
      }
    }

    final Map<String, StoredStringItem> currentStringMap = {
      for (var s in storedStrings) s.id: s,
    };

    for (final remoteString in remoteVault.storedStrings) {
      if (!currentStringMap.containsKey(remoteString.id)) {
        storedStrings.add(remoteString);
      } else {
        final localString = currentStringMap[remoteString.id]!;
        if (remoteString.updatedAt.isAfter(localString.updatedAt)) {
          final index = storedStrings.indexOf(localString);
          storedStrings[index] = remoteString;
        }
      }
    }

    if (remoteVault.encryptedDropboxConfig != null &&
        (encryptedDropboxConfig == null ||
            remoteVault.updatedAt.isAfter(updatedAt))) {
      encryptedDropboxConfig = remoteVault.encryptedDropboxConfig;
    }

    updatedAt = DateTime.now().toUtc();
  }

  /// Returns true if [candidate] should be considered newer than [baseline] when loading.
  static bool isNewerVault(
    SyncVaultFile candidate,
    SyncVaultFile baseline, {
    DateTime? candidateModifiedAt,
    bool baselineExistedOnDisk = true,
  }) {
    if (!baselineExistedOnDisk &&
        (candidate.servers.isNotEmpty ||
            candidate.tasks.isNotEmpty ||
            candidate.storedStrings.isNotEmpty ||
            candidate.encryptedDropboxConfig != null)) {
      return true;
    }
    final effectiveCandidateTime = candidateModifiedAt != null &&
            candidateModifiedAt.isAfter(candidate.updatedAt)
        ? candidateModifiedAt
        : candidate.updatedAt;
    return effectiveCandidateTime.isAfter(baseline.updatedAt);
  }
}
