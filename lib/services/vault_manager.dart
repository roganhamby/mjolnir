import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import '../models/server_config.dart';
import '../models/stored_string_item.dart';
import '../models/task_item.dart';
import '../models/terminal_macro_item.dart';
import '../models/sync_vault_file.dart';
import 'crypto_vault_service.dart';
import 'sftp_sync_service.dart';
import 'sync_storage_provider.dart';

class VaultManager with ChangeNotifier {
  final CryptoVaultService cryptoService = CryptoVaultService();
  final SyncStorageProvider storageProvider;
  final SftpSyncService sftpSyncService;

  SyncVaultFile? _vault;
  SecretKey? _masterKey;
  bool _isUnlocked = false;
  String? _errorMessage;
  String _loadedSource = 'Local';

  VaultManager({
    required this.storageProvider,
    SftpSyncService? sftpSyncService,
  }) : sftpSyncService = sftpSyncService ?? SftpSyncService();

  bool get isUnlocked => _isUnlocked;
  SyncVaultFile? get vault => _vault;
  List<ServerConfig> get servers => _vault?.servers ?? [];
  List<TaskItem> get tasks => _vault?.tasks ?? [];
  List<StoredStringItem> get storedStrings => _vault?.storedStrings ?? [];
  List<TerminalMacroItem> get macros => _vault?.macros ?? [];
  String? get errorMessage => _errorMessage;
  String get loadedSource => _loadedSource;

  /// Loads the vault metadata from storage and checks SFTP if configured,
  /// automatically selecting the newest vault when loading.
  Future<void> init() async {
    try {
      await sftpSyncService.loadConfig();
      final localExisted = await storageProvider.vaultExists();
      var activeVault = await storageProvider.loadVault();
      _loadedSource = 'Local';

      if (sftpSyncService.config.isConfigured &&
          sftpSyncService.config.autoSyncOnLoadAndSave) {
        try {
          final remoteNewest = await sftpSyncService.fetchNewestVaultFromSftp();
          if (remoteNewest != null) {
            final localHasData = localExisted &&
                (activeVault.servers.isNotEmpty ||
                    activeVault.tasks.isNotEmpty ||
                    activeVault.storedStrings.isNotEmpty ||
                    activeVault.macros.isNotEmpty ||
                    activeVault.encryptedSftpSyncConfig != null ||
                    activeVault.vaultPayload != null);
            if (SyncVaultFile.isNewerVault(
              remoteNewest.vault,
              activeVault,
              candidateModifiedAt: remoteNewest.modifiedAt,
              baselineExistedOnDisk: localHasData,
            )) {
              activeVault = remoteNewest.vault;
              await storageProvider.saveVault(activeVault);
              _loadedSource = 'SFTP (${remoteNewest.filePath})';
            }
          }
        } catch (sftpErr) {
          debugPrint('SFTP load check failed (using local vault): $sftpErr');
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

  /// Encrypts the current SFTP sync credentials into the vault if unlocked and configured.
  Future<void> _syncSftpSyncConfigToVault() async {
    if (!_isUnlocked || _masterKey == null || _vault == null) return;
    if (sftpSyncService.config.isConfigured) {
      _vault!.encryptedSftpSyncConfig = await cryptoService.encryptPayload(
        payload: sftpSyncService.config.toJson(),
        masterKey: _masterKey!,
      );
    }
  }

  /// Saves SFTP sync configuration and encrypts it into the vault if unlocked.
  Future<void> saveSftpSyncConfig(SftpSyncConfig newConfig) async {
    await sftpSyncService.saveConfig(newConfig);
    if (_isUnlocked && _masterKey != null && _vault != null) {
      if (newConfig.isConfigured) {
        _vault!.encryptedSftpSyncConfig = await cryptoService.encryptPayload(
          payload: newConfig.toJson(),
          masterKey: _masterKey!,
        );
      } else {
        _vault!.encryptedSftpSyncConfig = null;
      }
      _vault!.updatedAt = DateTime.now().toUtc();
      await storageProvider.saveVault(_vault!);
      notifyListeners();
    }
  }

  /// Saves the vault locally and, if SFTP auto-sync is enabled, uploads to the remote server.
  Future<void> _persistVault() async {
    if (_vault == null) return;
    await _syncSftpSyncConfigToVault();
    if (_masterKey != null) {
      await _vault!.encryptPayload(cryptoService, _masterKey!);
    }
    await storageProvider.saveVault(_vault!);
    if (sftpSyncService.config.isConfigured &&
        sftpSyncService.config.autoSyncOnLoadAndSave) {
      try {
        await sftpSyncService.uploadVaultJson(
          _vault!.toFormattedJson(),
          fileName: 'servers.json',
        );
      } catch (e) {
        debugPrint('SFTP auto-sync upload failed: $e');
      }
    }
  }

  /// Unlocks the vault using the given master password.
  /// Derives the key and decrypts in-memory server credentials and SFTP sync credentials.
  Future<bool> unlock(String masterPassword) async {
    if (_vault == null) await init();
    if (_vault == null) return false;

    try {
      final key = await cryptoService.deriveMasterKey(masterPassword, _vault!.salt);
      _masterKey = key;

      if (_vault!.isEncryptedEnvelope) {
        // Version 2 Zero-Knowledge envelope: decrypt all inner servers, tasks, stored_strings
        try {
          await _vault!.decryptPayload(cryptoService, key);
        } catch (e) {
          _masterKey = null;
          _errorMessage = 'Invalid master password or corrupted vault payload.';
          notifyListeners();
          return false;
        }

        // Decrypt individual server credentials
        for (final server in _vault!.servers) {
          if (server.encryptedCredentials != null) {
            try {
              await server.decrypt(cryptoService, key);
            } catch (_) {}
          }
        }
      } else {
        // Legacy Version 1 vault: check each server credential
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
        if (_vault!.encryptedSftpSyncConfig != null) {
          try {
            await cryptoService.decryptPayload(
              encryptedData: _vault!.encryptedSftpSyncConfig!,
              masterKey: key,
            );
          } catch (e) {
            _masterKey = null;
            _errorMessage = 'Invalid master password or corrupted credential payload.';
            notifyListeners();
            return false;
          }
        }

        // Upgrade legacy V1 vault to Version 2 Zero-Knowledge envelope
        await _vault!.encryptPayload(cryptoService, key);
        await storageProvider.saveVault(_vault!);
      }

      if (_vault!.encryptedSftpSyncConfig != null) {
        try {
          final decryptedSftpMap = await cryptoService.decryptPayload(
            encryptedData: _vault!.encryptedSftpSyncConfig!,
            masterKey: key,
          );
          final vaultSftp = SftpSyncConfig.fromJson(decryptedSftpMap);
          if (!sftpSyncService.config.isConfigured && vaultSftp.isConfigured) {
            await sftpSyncService.saveConfig(vaultSftp);
          }
        } catch (_) {}
      }

      _isUnlocked = true;
      _errorMessage = null;

      if (sftpSyncService.config.isConfigured) {
        await _syncSftpSyncConfigToVault();
        await _persistVault();
      }

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
    // If the vault is an encrypted envelope, clear plaintext lists from memory while locked
    if (_vault?.isEncryptedEnvelope == true) {
      _vault!.servers = [];
      _vault!.tasks = [];
      _vault!.storedStrings = [];
      _vault!.macros = [];
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

    // If imported vault is a Version 2 envelope, decrypt it first
    if (importedVault.isEncryptedEnvelope) {
      await importedVault.decryptPayload(cryptoService, importedKey);
    }

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

    for (final item in importedVault.storedStrings) {
      final existingIndex = _vault!.storedStrings.indexWhere((s) => s.id == item.id);
      if (existingIndex >= 0) {
        if (item.updatedAt.isAfter(_vault!.storedStrings[existingIndex].updatedAt)) {
          _vault!.storedStrings[existingIndex] = item;
        }
      } else {
        _vault!.storedStrings.add(item);
      }
    }

    for (final item in importedVault.macros) {
      final existingIndex = _vault!.macros.indexWhere((m) => m.id == item.id);
      if (existingIndex >= 0) {
        if (item.updatedAt.isAfter(_vault!.macros[existingIndex].updatedAt)) {
          _vault!.macros[existingIndex] = item;
        }
      } else {
        _vault!.macros.add(item);
      }
    }

    if (importedVault.encryptedSftpSyncConfig != null) {
      final decryptedSftpMap = await cryptoService.decryptPayload(
        encryptedData: importedVault.encryptedSftpSyncConfig!,
        masterKey: importedKey,
      );
      final importedSftp = SftpSyncConfig.fromJson(decryptedSftpMap);
      if (importedSftp.isConfigured &&
          (!sftpSyncService.config.isConfigured ||
              importedVault.updatedAt.isAfter(_vault!.updatedAt))) {
        await sftpSyncService.saveConfig(importedSftp);
      }
    }

    _vault!.updatedAt = DateTime.now().toUtc();
    await _persistVault();
    notifyListeners();
    return count;
  }

  /// Imports a vault JSON while locked (e.g. on a brand new station), verifies the master password,
  /// restores encrypted SFTP sync credentials if included, and unlocks the station immediately.
  Future<({int serverCount, bool sftpConfigured})> importAndUnlockVaultJson(
    String jsonString,
    String masterPassword,
  ) async {
    final Map<String, dynamic> data = jsonDecode(jsonString) as Map<String, dynamic>;
    final importedVault = SyncVaultFile.fromJson(data);
    final key = await cryptoService.deriveMasterKey(masterPassword, importedVault.salt);

    if (importedVault.isEncryptedEnvelope) {
      await importedVault.decryptPayload(cryptoService, key);
    }

    for (final server in importedVault.servers) {
      if (server.encryptedCredentials != null) {
        await server.decrypt(cryptoService, key);
      }
    }

    bool sftpRestored = false;
    if (importedVault.encryptedSftpSyncConfig != null) {
      final decryptedSftpMap = await cryptoService.decryptPayload(
        encryptedData: importedVault.encryptedSftpSyncConfig!,
        masterKey: key,
      );
      final importedSftp = SftpSyncConfig.fromJson(decryptedSftpMap);
      if (importedSftp.isConfigured) {
        await sftpSyncService.saveConfig(importedSftp);
        sftpRestored = true;
      }
    }

    _vault = importedVault;
    _masterKey = key;
    _isUnlocked = true;
    _errorMessage = null;
    _loadedSource = 'Imported JSON';

    await _syncSftpSyncConfigToVault();
    await _persistVault();
    notifyListeners();
    return (
      serverCount: _vault!.servers.length,
      sftpConfigured: sftpRestored || sftpSyncService.config.isConfigured,
    );
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

  /// Adds or updates a stored string item and persists the vault.
  Future<void> saveStoredString(StoredStringItem item) async {
    if (!_isUnlocked || _vault == null) {
      throw StateError('Cannot modify stored strings while vault is locked.');
    }

    item.updatedAt = DateTime.now().toUtc();
    final existingIndex = _vault!.storedStrings.indexWhere((s) => s.id == item.id);
    if (existingIndex >= 0) {
      _vault!.storedStrings[existingIndex] = item;
    } else {
      _vault!.storedStrings.add(item);
    }

    _vault!.updatedAt = DateTime.now().toUtc();
    await _persistVault();
    notifyListeners();
  }

  /// Deletes a stored string item by ID and persists the vault.
  Future<void> deleteStoredString(String id) async {
    if (!_isUnlocked || _vault == null) {
      throw StateError('Cannot modify stored strings while vault is locked.');
    }

    _vault!.storedStrings.removeWhere((s) => s.id == id);
    _vault!.updatedAt = DateTime.now().toUtc();
    await _persistVault();
    notifyListeners();
  }

  /// Adds or updates a terminal macro item and persists the vault.
  Future<void> saveMacro(TerminalMacroItem item) async {
    if (!_isUnlocked || _vault == null) {
      throw StateError('Cannot modify macros while vault is locked.');
    }

    item.updatedAt = DateTime.now().toUtc();
    final existingIndex = _vault!.macros.indexWhere((m) => m.id == item.id);
    if (existingIndex >= 0) {
      _vault!.macros[existingIndex] = item;
    } else {
      _vault!.macros.add(item);
    }

    _vault!.updatedAt = DateTime.now().toUtc();
    await _persistVault();
    notifyListeners();
  }

  /// Deletes a terminal macro item by ID and persists the vault.
  Future<void> deleteMacro(String id) async {
    if (!_isUnlocked || _vault == null) {
      throw StateError('Cannot modify macros while vault is locked.');
    }

    _vault!.macros.removeWhere((m) => m.id == id);
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

  /// Ensures encrypted SFTP credentials are up to date in the vault and returns formatted JSON.
  Future<String> prepareAndExportVaultJson() async {
    if (_vault == null) {
      throw StateError('Vault not loaded.');
    }
    if (_isUnlocked && _masterKey != null) {
      await _syncSftpSyncConfigToVault();
      await _vault!.encryptPayload(cryptoService, _masterKey!);
      await storageProvider.saveVault(_vault!);
    }
    return _vault!.toFormattedJson();
  }

  /// Exports the current vault JSON directly to the configured SFTP server.
  Future<String> exportVaultToSftp({String? fileName}) async {
    if (_vault == null) {
      throw StateError('Vault not loaded.');
    }
    _vault!.updatedAt = DateTime.now().toUtc();
    await _syncSftpSyncConfigToVault();
    if (_masterKey != null) {
      await _vault!.encryptPayload(cryptoService, _masterKey!);
    }
    await storageProvider.saveVault(_vault!);
    final jsonString = _vault!.toFormattedJson();
    return await sftpSyncService.uploadVaultJson(
      jsonString,
      fileName: fileName,
    );
  }

  /// Imports the newest JSON vault found on the configured SFTP server.
  /// If unlocked, merges servers and tasks by `updatedAt` timestamps and persists.
  Future<({int serverCount, String filePath})> importNewestFromSftp(
    String masterPassword,
  ) async {
    final newest = await sftpSyncService.fetchNewestVaultFromSftp();
    if (newest == null) {
      throw Exception(
        'No JSON vault files found on SFTP server at ${sftpSyncService.displayRemotePath}.',
      );
    }

    if (!_isUnlocked) {
      // When locked, replace local vault if SFTP is newer (or force adopt it) and unlock
      _vault = newest.vault;
      await storageProvider.saveVault(_vault!);
      _loadedSource = 'SFTP (${newest.filePath})';
      final ok = await unlock(masterPassword);
      if (!ok) {
        throw Exception(_errorMessage ?? 'Invalid master password for SFTP vault.');
      }
      return (serverCount: _vault!.servers.length, filePath: newest.filePath);
    }

    final count = await importVaultJson(newest.rawJson, masterPassword);
    _loadedSource = 'SFTP (${newest.filePath})';
    return (serverCount: count, filePath: newest.filePath);
  }

  /// Checks SFTP for a newer vault while on the lock screen and loads it if newer.
  Future<String?> checkAndLoadNewestFromSftp() async {
    final newest = await sftpSyncService.fetchNewestVaultFromSftp();
    if (newest == null) return null;

    final localHasData = _vault != null &&
        (_vault!.servers.isNotEmpty ||
            _vault!.tasks.isNotEmpty ||
            _vault!.storedStrings.isNotEmpty ||
            _vault!.macros.isNotEmpty ||
            _vault!.encryptedSftpSyncConfig != null ||
            _vault!.vaultPayload != null);
    if (_vault == null ||
        SyncVaultFile.isNewerVault(
          newest.vault,
          _vault!,
          candidateModifiedAt: newest.modifiedAt,
          baselineExistedOnDisk: localHasData,
        )) {
      _vault = newest.vault;
      await storageProvider.saveVault(_vault!);
      _loadedSource = 'SFTP (${newest.filePath})';
      notifyListeners();
      return newest.filePath;
    }
    return null;
  }
}
