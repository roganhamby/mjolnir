import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import '../models/server_config.dart';
import '../models/task_item.dart';
import '../models/sync_vault_file.dart';
import 'crypto_vault_service.dart';
import 'sync_storage_provider.dart';

class VaultManager with ChangeNotifier {
  final CryptoVaultService cryptoService = CryptoVaultService();
  final SyncStorageProvider storageProvider;

  SyncVaultFile? _vault;
  SecretKey? _masterKey;
  bool _isUnlocked = false;
  String? _errorMessage;

  VaultManager({required this.storageProvider});

  bool get isUnlocked => _isUnlocked;
  SyncVaultFile? get vault => _vault;
  List<ServerConfig> get servers => _vault?.servers ?? [];
  List<TaskItem> get tasks => _vault?.tasks ?? [];
  String? get errorMessage => _errorMessage;

  /// Loads the vault metadata from storage. Unlocked state is false initially.
  Future<void> init() async {
    try {
      _vault = await storageProvider.loadVault();
      _errorMessage = null;
      notifyListeners();
    } catch (e) {
      _errorMessage = 'Failed to load vault file: $e';
      notifyListeners();
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
    await storageProvider.saveVault(_vault!);
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
    await storageProvider.saveVault(_vault!);
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
    await storageProvider.saveVault(_vault!);
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
    await storageProvider.saveVault(_vault!);
    notifyListeners();
  }

  /// Deletes/completes a task by ID and persists the vault.
  Future<void> deleteTask(String taskId) async {
    if (!_isUnlocked || _vault == null) {
      throw StateError('Cannot modify tasks while vault is locked.');
    }

    _vault!.tasks.removeWhere((t) => t.id == taskId);
    _vault!.updatedAt = DateTime.now().toUtc();
    await storageProvider.saveVault(_vault!);
    notifyListeners();
  }

  /// Exports the current vault as an encrypted JSON string
  String exportVaultJson() {
    if (_vault == null) {
      throw StateError('Vault not loaded.');
    }
    return _vault!.toFormattedJson();
  }
}
