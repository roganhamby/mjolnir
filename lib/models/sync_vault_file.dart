import 'dart:convert';
import 'server_config.dart';
import 'task_item.dart';
import '../services/crypto_vault_service.dart';

class SyncVaultFile {
  int version;
  String appId;
  DateTime updatedAt;
  String salt;
  List<ServerConfig> servers;
  List<TaskItem> tasks;

  SyncVaultFile({
    this.version = 1,
    this.appId = 'com.serversync.mjolnir',
    DateTime? updatedAt,
    required this.salt,
    List<ServerConfig>? servers,
    List<TaskItem>? tasks,
  })  : updatedAt = updatedAt ?? DateTime.now().toUtc(),
        servers = servers ?? [],
        tasks = tasks ?? [];

  /// Factory for a brand new empty vault file
  factory SyncVaultFile.createEmpty() {
    return SyncVaultFile(
      salt: CryptoVaultService.generateRandomSalt(),
      servers: [],
      tasks: [],
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
        'tasks': tasks.map((t) => t.toJson()).toList(),
      };

  factory SyncVaultFile.fromJson(Map<String, dynamic> json) {
    final cryptoParams = json['crypto_params'] as Map<String, dynamic>? ?? {};
    final serverList = (json['servers'] as List<dynamic>? ?? [])
        .map((e) => ServerConfig.fromJson(e as Map<String, dynamic>))
        .toList();
    final taskList = (json['tasks'] as List<dynamic>? ?? [])
        .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
        .toList();

    return SyncVaultFile(
      version: json['version'] as int? ?? 1,
      appId: json['app_id'] as String? ?? 'com.serversync.mjolnir',
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
      salt: cryptoParams['salt'] as String? ?? CryptoVaultService.generateRandomSalt(),
      servers: serverList,
      tasks: taskList,
    );
  }

  String toFormattedJson() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  /// Merges remote servers and tasks with current vault based on per-item updatedAt timestamps.
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
        (candidate.servers.isNotEmpty || candidate.tasks.isNotEmpty)) {
      return true;
    }
    final effectiveCandidateTime = candidateModifiedAt != null &&
            candidateModifiedAt.isAfter(candidate.updatedAt)
        ? candidateModifiedAt
        : candidate.updatedAt;
    return effectiveCandidateTime.isAfter(baseline.updatedAt);
  }
}
