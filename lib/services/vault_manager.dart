import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import '../models/server_config.dart';
import '../models/task_item.dart';
import '../models/sync_vault_file.dart';
import 'crypto_vault_service.dart';
import 'dropbox_sync_service.dart';
import 'sync_storage_provider.dart';

class VaultManager with ChangeNotifier {
  final CryptoVaultService cryptoService = CryptoVaultService();
  final SyncStorageProvider storageProvider;
  final DropboxSyncService dropboxService;

  SyncVaultFile? _vault;
  SecretKey? _masterKey;
  bool _isUnlocked = false;
  String? _errorMessage;
  String _loadedSource = 'Local';

  VaultManager({
    required this.storageProvider,
    DropboxSyncService? dropboxService,
  }) : dropboxService = dropboxService ?? DropboxSyncService();

  bool get isUnlocked => _isUnlocked;
  SyncVaultFile? get vault => _vault;
  List<ServerConfig> get servers => _vault?.servers ?? [];
  List<TaskItem> get tasks => _vault?.tasks ?? [];
  String? get errorMessage => _errorMessage;
  String get loadedSource => _loadedSource;

  /// Loads the vault metadata from storage and checks Dropbox (/App/Mjolnir) if configured,
  /// automatically selecting the newest vault when loading.
  Future<void> init() async {
    try {
      await dropboxService.loadConfig();
      final localExisted = await storageProvider.vaultExists();
      var activeVault = await storageProvider.loadVault();
      _loadedSource = 'Local';

      if (dropboxService.config.isConfigured &&
          dropboxService.config.autoSyncOnLoadAndSave) {
        try {
          final remoteNewest = await dropboxService.fetchNewestVaultFromDropbox();
          if (remoteNewest != null) {
            final localHasData = localExisted &&
                (activeVault.servers.isNotEmpty || activeVault.tasks.isNotEmpty);
            if (SyncVaultFile.isNewerVault(
              remoteNewest.vault,
              activeVault,
              candidateModifiedAt: remoteNewest.modifiedAt,
              baselineExistedOnDisk: localHasData,
            )) {
              activeVault = remoteNewest.vault;
              await storageProvider.saveVault(activeVault);
              _loadedSource = 'Dropbox (${remoteNewest.filePath})';
            }
          }
        } catch (dropboxErr) {
          debugPrint('Dropbox load check failed (using local vault): $dropboxErr');
        }
      }

      _vault = activeVault;
      _errorMessage = null;
      notifyListeners();
    } catch (e) {
      _errorMessage = 'Failed to load vault file: $e';
      notifyListeners();
    }
  }

  /// Saves the vault locally and, if Dropbox auto-sync is enabled, uploads to `/App/Mjolnir/servers.json`.
  Future<void> _persistVault() async {
    if (_vault == null) return;
    await storageProvider.saveVault(_vault!);
    if (dropboxService.config.isConfigured &&
        dropboxService.config.autoSyncOnLoadAndSave) {
      try {
        await dropboxService.uploadVaultJson(
          _vault!.toFormattedJson(),
          fileName: 'servers.json',
        );
      } catch (e) {
        debugPrint('Dropbox auto-sync upload failed: $e');
      }
    }
  }

  /// Unlocks the vault using the given master password.
  /// Derives the key and decrypts in-memory server credentials.
  Future<bool> unlock(String masterPassword) async {
    if (_vault == null) await init();
    if (_vault == null) return false;

    try {
      final key = await cryptoService.deriveMasterKey(masterPassword, _vault!.salt);
      _masterKey = key;

      // Try decrypting servers. If any server fails auth tag check, bad password.
      for (final server in _vault!.servers) {
        if (server.encryptedCredentials != null) {
          try {
            await server.decrypt(cryptoService, key);
          } catch (e) {
            _masterKey = null;
            _errorMessage = 'Invalid master password or corrupted credential payload.';
            notifyListeners();
            return false;
          }
        }
      }

      _isUnlocked = true;
      _errorMessage = null;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = 'Unlock failed: $e';
      _isUnlocked = false;
      _masterKey = null;
      notifyListeners();
      return false;
    }
  }

  /// Locks the vault and clears the encryption key and plain credentials from memory.
  void lock() {
    _masterKey = null;
    _isUnlocked = false;
    for (final server in _vault?.servers ?? <ServerConfig>[]) {
      server.decryptedCredentials = null;
    }
    notifyListeners();
  }

  /// Adds or updates a server, re-encrypting its credentials and persisting the JSON file.
  Future<void> saveServer(ServerConfig server) async {
    if (!_isUnlocked || _masterKey == null || _vault == null) {
      throw StateError('Cannot modify servers while vault is locked.');
    }

    await server.encrypt(cryptoService, _masterKey!);

    final existingIndex = _vault!.servers.indexWhere((s) => s.id == server.id);
    if (existingIndex >= 0) {
      _vault!.servers[existingIndex] = server;
    } else {
      _vault!.servers.add(server);
    }

    _vault!.updatedAt = DateTime.now().toUtc();
    await _persistVault();
    notifyListeners();
  }

  /// Imports servers from a decrypted or same-master-key JSON string.
  /// Merges remote servers using updatedAt timestamps and saves.
  Future<int> importVaultJson(String jsonString, String masterPassword) async {
    if (!_isUnlocked || _masterKey == null || _vault == null) {
      throw StateError('Vault must be unlocked before importing.');
    }

    final Map<String, dynamic> data = jsonDecode(jsonString) as Map<String, dynamic>;
    final importedVault = SyncVaultFile.fromJson(data);

    // Derive the imported vault's key using the supplied password and the imported salt
    final importedKey = await cryptoService.deriveMasterKey(masterPassword, importedVault.salt);

    int count = 0;
    for (final server in importedVault.servers) {
      // Decrypt with the imported key first if encrypted
      if (server.encryptedCredentials != null) {
        await server.decrypt(cryptoService, importedKey);
      }
      // Re-encrypt with the current vault's master key
      await server.encrypt(cryptoService, _masterKey!);

      final existingIndex = _vault!.servers.indexWhere((s) => s.id == server.id);
      if (existingIndex >= 0) {
        if (server.updatedAt.isAfter(_vault!.servers[existingIndex].updatedAt)) {
          _vault!.servers[existingIndex] = server;
          count++;
        }
      } else {
        _vault!.servers.add(server);
        count++;
      }
    }

    for (final task in importedVault.tasks) {
      final existingIndex = _vault!.tasks.indexWhere((t) => t.id == task.id);
      if (existingIndex >= 0) {
        if (task.updatedAt.isAfter(_vault!.tasks[existingIndex].updatedAt)) {
          task.assignedTabId = _vault!.tasks[existingIndex].assignedTabId;
          _vault!.tasks[existingIndex] = task;
        }
      } else {
        _vault!.tasks.add(task);
      }
    }

    _vault!.updatedAt = DateTime.now().toUtc();
    await _persistVault();
    notifyListeners();
    return count;
  }

  /// Deletes a server by ID and saves the vault.
  Future<void> deleteServer(String serverId) async {
    if (!_isUnlocked || _vault == null) {
      throw StateError('Cannot modify servers while vault is locked.');
    }

    _vault!.servers.removeWhere((s) => s.id == serverId);
    _vault!.updatedAt = DateTime.now().toUtc();
    await _persistVault();
    notifyListeners();
  }

  /// Adds or updates a task and persists the vault.
  Future<void> saveTask(TaskItem task) async {
    if (!_isUnlocked || _vault == null) {
      throw StateError('Cannot modify tasks while vault is locked.');
    }

    task.updatedAt = DateTime.now().toUtc();
    final existingIndex = _vault!.tasks.indexWhere((t) => t.id == task.id);
    if (existingIndex >= 0) {
      _vault!.tasks[existingIndex] = task;
    } else {
      _vault!.tasks.add(task);
    }

    _vault!.updatedAt = DateTime.now().toUtc();
    await _persistVault();
    notifyListeners();
  }

  /// Deletes/completes a task by ID and persists the vault.
  Future<void> deleteTask(String taskId) async {
    if (!_isUnlocked || _vault == null) {
      throw StateError('Cannot modify tasks while vault is locked.');
    }

    _vault!.tasks.removeWhere((t) => t.id == taskId);
    _vault!.updatedAt = DateTime.now().toUtc();
    await _persistVault();
    notifyListeners();
  }

  /// Exports the current vault as an encrypted JSON string
  String exportVaultJson() {
    if (_vault == null) {
      throw StateError('Vault not loaded.');
    }
    return _vault!.toFormattedJson();
  }

  /// Exports the current vault JSON directly to Dropbox in `/App/Mjolnir`.
  Future<String> exportVaultToDropbox({String? fileName}) async {
    if (_vault == null) {
      throw StateError('Vault not loaded.');
    }
    _vault!.updatedAt = DateTime.now().toUtc();
    await storageProvider.saveVault(_vault!);
    final jsonString = _vault!.toFormattedJson();
    final targetName = (fileName != null && fileName.trim().isNotEmpty)
        ? fileName.trim()
        : 'servers.json';
    return await dropboxService.uploadVaultJson(
      jsonString,
      fileName: targetName,
    );
  }

  /// Imports the newest JSON vault found in Dropbox's `/App/Mjolnir` directory.
  /// If unlocked, merges servers and tasks by `updatedAt` timestamps and persists.
  Future<({int serverCount, String filePath})> importNewestFromDropbox(
    String masterPassword,
  ) async {
    final newest = await dropboxService.fetchNewestVaultFromDropbox();
    if (newest == null) {
      throw Exception(
        'No JSON vault files found in Dropbox directory ${dropboxService.normalizedFolderPath}.',
      );
    }

    if (!_isUnlocked) {
      // When locked, replace local vault if Dropbox is newer (or force adopt it) and unlock
      _vault = newest.vault;
      await storageProvider.saveVault(_vault!);
      _loadedSource = 'Dropbox (${newest.filePath})';
      final ok = await unlock(masterPassword);
      if (!ok) {
        throw Exception(_errorMessage ?? 'Invalid master password for Dropbox vault.');
      }
      return (serverCount: _vault!.servers.length, filePath: newest.filePath);
    }

    final count = await importVaultJson(newest.rawJson, masterPassword);
    _loadedSource = 'Dropbox (${newest.filePath})';
    return (serverCount: count, filePath: newest.filePath);
  }

  /// Checks Dropbox for a newer vault while on the lock screen and loads it if newer.
  Future<String?> checkAndLoadNewestFromDropbox() async {
    final newest = await dropboxService.fetchNewestVaultFromDropbox();
    if (newest == null) return null;

    final localHasData = _vault != null &&
        (_vault!.servers.isNotEmpty || _vault!.tasks.isNotEmpty);
    if (_vault == null ||
        SyncVaultFile.isNewerVault(
          newest.vault,
          _vault!,
          candidateModifiedAt: newest.modifiedAt,
          baselineExistedOnDisk: localHasData,
        )) {
      _vault = newest.vault;
      await storageProvider.saveVault(_vault!);
      _loadedSource = 'Dropbox (${newest.filePath})';
      notifyListeners();
      return newest.filePath;
    }
    return null;
  }
}
