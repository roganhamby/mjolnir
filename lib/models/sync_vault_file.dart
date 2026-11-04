import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'server_config.dart';
import 'stored_string_item.dart';
import 'task_item.dart';
import 'terminal_macro_item.dart';
import '../services/crypto_vault_service.dart';

class SyncVaultFile {
  int version;
  String appId;
  DateTime updatedAt;
  String salt;
  Map<String, dynamic>? encryptedSftpSyncConfig;
  Map<String, dynamic>? vaultPayload;
  List<ServerConfig> servers;
  List<TaskItem> tasks;
  List<StoredStringItem> storedStrings;
  List<TerminalMacroItem> macros;

  SyncVaultFile({
    this.version = 1,
    this.appId = 'com.serversync.mjolnir',
    DateTime? updatedAt,
    required this.salt,
    this.encryptedSftpSyncConfig,
    this.vaultPayload,
    List<ServerConfig>? servers,
    List<TaskItem>? tasks,
    List<StoredStringItem>? storedStrings,
    List<TerminalMacroItem>? macros,
  })  : updatedAt = updatedAt ?? DateTime.now().toUtc(),
        servers = servers ?? [],
        tasks = tasks ?? [],
        storedStrings = storedStrings ?? [],
        macros = macros ?? [];

  bool get isEncryptedEnvelope => vaultPayload != null;

  /// Factory for a brand new empty vault file
  factory SyncVaultFile.createEmpty() {
    return SyncVaultFile(
      version: 2,
      salt: CryptoVaultService.generateRandomSalt(),
      servers: [],
      tasks: [],
      storedStrings: [],
      macros: [],
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
        if (encryptedSftpSyncConfig != null)
          'encrypted_sftp_sync_config': encryptedSftpSyncConfig,
        if (vaultPayload != null)
          'vault_payload': vaultPayload
        else ...{
          'servers': servers.map((s) => s.toJson()).toList(),
          'tasks': tasks.map((t) => t.toJson()).toList(),
          'stored_strings': storedStrings.map((s) => s.toJson()).toList(),
          'macros': macros.map((m) => m.toJson()).toList(),
        },
      };

  factory SyncVaultFile.fromJson(Map<String, dynamic> json) {
    final cryptoParams = json['crypto_params'] as Map<String, dynamic>? ?? {};
    final vPayload = json['vault_payload'] as Map<String, dynamic>?;

    final serverList = (json['servers'] as List<dynamic>? ?? [])
        .map((e) => ServerConfig.fromJson(e as Map<String, dynamic>))
        .toList();
    final taskList = (json['tasks'] as List<dynamic>? ?? [])
        .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
        .toList();
    final stringList = (json['stored_strings'] as List<dynamic>? ?? [])
        .map((e) => StoredStringItem.fromJson(e as Map<String, dynamic>))
        .toList();
    final macroList = (json['macros'] as List<dynamic>? ?? [])
        .map((e) => TerminalMacroItem.fromJson(e as Map<String, dynamic>))
        .toList();

    return SyncVaultFile(
      version: json['version'] as int? ?? (vPayload != null ? 2 : 1),
      appId: json['app_id'] as String? ?? 'com.serversync.mjolnir',
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
      salt: cryptoParams['salt'] as String? ?? CryptoVaultService.generateRandomSalt(),
      encryptedSftpSyncConfig:
          json['encrypted_sftp_sync_config'] as Map<String, dynamic>?,
      vaultPayload: vPayload,
      servers: serverList,
      tasks: taskList,
      storedStrings: stringList,
      macros: macroList,
    );
  }

  /// Decrypts the inner zero-knowledge vault payload using the derived master key.
  Future<void> decryptPayload(CryptoVaultService cryptoService, SecretKey masterKey) async {
    if (vaultPayload == null) return;
    final decryptedMap = await cryptoService.decryptPayload(
      encryptedData: vaultPayload!,
      masterKey: masterKey,
    );

    if (decryptedMap['servers'] is List) {
      servers = (decryptedMap['servers'] as List)
          .map((e) => ServerConfig.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    if (decryptedMap['tasks'] is List) {
      tasks = (decryptedMap['tasks'] as List)
          .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    if (decryptedMap['stored_strings'] is List) {
      storedStrings = (decryptedMap['stored_strings'] as List)
          .map((e) => StoredStringItem.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    if (decryptedMap['macros'] is List) {
      macros = (decryptedMap['macros'] as List)
          .map((e) => TerminalMacroItem.fromJson(e as Map<String, dynamic>))
          .toList();
    }
  }

  /// Encrypts in-memory servers, tasks, stored_strings, and macros into [vaultPayload].
  Future<void> encryptPayload(CryptoVaultService cryptoService, SecretKey masterKey) async {
    final innerData = {
      'servers': servers.map((s) => s.toJson()).toList(),
      'tasks': tasks.map((t) => t.toJson()).toList(),
      'stored_strings': storedStrings.map((s) => s.toJson()).toList(),
      'macros': macros.map((m) => m.toJson()).toList(),
    };
    vaultPayload = await cryptoService.encryptPayload(
      payload: innerData,
      masterKey: masterKey,
    );
    version = 2;
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

    final Map<String, TerminalMacroItem> currentMacroMap = {
      for (var m in macros) m.id: m,
    };

    for (final remoteMacro in remoteVault.macros) {
      if (!currentMacroMap.containsKey(remoteMacro.id)) {
        macros.add(remoteMacro);
      } else {
        final localMacro = currentMacroMap[remoteMacro.id]!;
        if (remoteMacro.updatedAt.isAfter(localMacro.updatedAt)) {
          final index = macros.indexOf(localMacro);
          macros[index] = remoteMacro;
        }
      }
    }

    if (remoteVault.encryptedSftpSyncConfig != null &&
        (encryptedSftpSyncConfig == null ||
            remoteVault.updatedAt.isAfter(updatedAt))) {
      encryptedSftpSyncConfig = remoteVault.encryptedSftpSyncConfig;
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
            candidate.macros.isNotEmpty ||
            candidate.encryptedSftpSyncConfig != null ||
            candidate.vaultPayload != null)) {
      return true;
    }
    final effectiveCandidateTime = candidateModifiedAt != null &&
            candidateModifiedAt.isAfter(candidate.updatedAt)
        ? candidateModifiedAt
        : candidate.updatedAt;
    return effectiveCandidateTime.isAfter(baseline.updatedAt);
  }
}
