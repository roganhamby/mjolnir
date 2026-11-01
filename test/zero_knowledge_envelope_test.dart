import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mjolnir/models/server_config.dart';
import 'package:mjolnir/models/stored_string_item.dart';
import 'package:mjolnir/models/task_item.dart';
import 'package:mjolnir/models/sync_vault_file.dart';
import 'package:mjolnir/services/crypto_vault_service.dart';
import 'package:mjolnir/services/sftp_sync_service.dart';
import 'package:mjolnir/services/sync_storage_provider.dart';
import 'package:mjolnir/services/vault_manager.dart';

class _InMemoryStorageProvider implements SyncStorageProvider {
  SyncVaultFile? stored;
  bool existedOnDisk;

  _InMemoryStorageProvider({this.stored, this.existedOnDisk = true});

  @override
  Future<String> getProviderName() async => 'InMemory';

  @override
  Future<bool> vaultExists() async => existedOnDisk;

  @override
  Future<SyncVaultFile> loadVault() async =>
      stored ?? SyncVaultFile.createEmpty();

  @override
  Future<void> saveVault(SyncVaultFile vault) async {
    stored = vault;
    existedOnDisk = true;
  }
}

class _FakeSftpSyncService extends SftpSyncService {
  SftpSyncConfig fakeConfig;

  _FakeSftpSyncService({SftpSyncConfig? config})
      : fakeConfig = config ?? SftpSyncConfig();

  @override
  SftpSyncConfig get config => fakeConfig;

  @override
  Future<void> saveConfig(SftpSyncConfig newConfig) async {
    fakeConfig = newConfig;
  }

  @override
  Future<void> loadConfig() async {}
}

void main() {
  const masterPassword = 'CorrectHorseBatteryStaple123!';
  const wrongPassword = 'WrongPassword456!';
  final salt = CryptoVaultService.generateRandomSalt();

  group('Version 2 Full Zero-Knowledge Vault Envelope Tests', () {
    test('Envelope encrypts all servers, tasks, and pasteboard items at rest', () async {
      final storage = _InMemoryStorageProvider(
        stored: SyncVaultFile(salt: salt),
        existedOnDisk: true,
      );
      final manager = VaultManager(
        storageProvider: storage,
        sftpSyncService: _FakeSftpSyncService(),
      );

      await manager.init();
      final unlocked = await manager.unlock(masterPassword);
      expect(unlocked, isTrue);

      // Add sensitive server
      await manager.saveServer(
        ServerConfig(
          id: 'secret-srv-1',
          name: 'Internal Top-Secret DB',
          host: '10.240.99.12',
          port: 22442,
          username: 'secops_admin',
          defaultRemotePath: '/opt/vault/secrets',
          expectedHostKey: 'SHA256:SuperSecretHostKeyFingerprint',
          decryptedCredentials: ServerCredentials(password: 'dbMasterPass!#'),
        ),
      );

      // Add sensitive task
      await manager.saveTask(
        TaskItem(
          id: 'task-1',
          title: 'Rotate AWS Root Access Key at 10.240.99.12',
          importance: TaskImportance.priority,
          subtasks: [
            SubTaskItem(
              id: 'sub-1',
              title: 'Execute /opt/vault/secrets/rotate.sh with sudo pass',
            ),
          ],
        ),
      );

      // Add sensitive pasteboard item
      await manager.saveStoredString(
        StoredStringItem(
          id: 'snippet-1',
          label: 'Production Stripe Secret',
          value: 'sk_live_51MszSuperConfidentialSecretKey999',
        ),
      );

      // Export the raw JSON produced by the vault manager
      final rawJson = manager.exportVaultJson();
      final decodedJson = jsonDecode(rawJson) as Map<String, dynamic>;

      // 1. Envelope structure verification
      expect(decodedJson['version'], equals(2));
      expect(decodedJson['app_id'], equals('com.serversync.mjolnir'));
      expect(decodedJson['crypto_params']['kdf'], equals('Argon2id'));
      expect(decodedJson['vault_payload'], isNotNull);
      expect(decodedJson['vault_payload']['nonce'], isNotNull);
      expect(decodedJson['vault_payload']['tag'], isNotNull);
      expect(decodedJson['vault_payload']['ciphertext'], isNotNull);

      // 2. Zero-Knowledge: Plaintext top-level lists MUST NOT exist
      expect(decodedJson.containsKey('servers'), isFalse);
      expect(decodedJson.containsKey('tasks'), isFalse);
      expect(decodedJson.containsKey('stored_strings'), isFalse);

      // 3. Zero-Knowledge: No sensitive text strings may leak in raw JSON
      expect(rawJson.contains('Internal Top-Secret DB'), isFalse);
      expect(rawJson.contains('10.240.99.12'), isFalse);
      expect(rawJson.contains('secops_admin'), isFalse);
      expect(rawJson.contains('/opt/vault/secrets'), isFalse);
      expect(rawJson.contains('SuperSecretHostKeyFingerprint'), isFalse);
      expect(rawJson.contains('dbMasterPass!#'), isFalse);
      expect(rawJson.contains('Rotate AWS Root Access Key'), isFalse);
      expect(rawJson.contains('rotate.sh with sudo pass'), isFalse);
      expect(rawJson.contains('Production Stripe Secret'), isFalse);
      expect(rawJson.contains('sk_live_51MszSuperConfidentialSecretKey999'), isFalse);
    });

    test('Wrong password fails envelope decryption and clears memory', () async {
      final storage = _InMemoryStorageProvider(
        stored: SyncVaultFile(salt: salt),
        existedOnDisk: true,
      );
      final manager1 = VaultManager(
        storageProvider: storage,
        sftpSyncService: _FakeSftpSyncService(),
      );
      await manager1.init();
      await manager1.unlock(masterPassword);

      await manager1.saveServer(
        ServerConfig(
          id: 'srv-locked',
          name: 'Production Node',
          host: 'prod.corp.internal',
          username: 'admin',
          decryptedCredentials: ServerCredentials(password: 'topsecret'),
        ),
      );

      final exportedJson = manager1.exportVaultJson();

      // Launch a new station instance with the exported JSON
      final storage2 = _InMemoryStorageProvider(
        stored: SyncVaultFile.fromJson(jsonDecode(exportedJson) as Map<String, dynamic>),
        existedOnDisk: true,
      );
      final manager2 = VaultManager(
        storageProvider: storage2,
        sftpSyncService: _FakeSftpSyncService(),
      );
      await manager2.init();

      // Attempt unlock with wrong password
      final unlockOk = await manager2.unlock(wrongPassword);
      expect(unlockOk, isFalse);
      expect(manager2.isUnlocked, isFalse);
      expect(manager2.servers, isEmpty);
      expect(manager2.tasks, isEmpty);
      expect(manager2.storedStrings, isEmpty);
      expect(manager2.errorMessage, contains('Invalid master password'));

      // Now unlock with correct password
      final unlockCorrect = await manager2.unlock(masterPassword);
      expect(unlockCorrect, isTrue);
      expect(manager2.isUnlocked, isTrue);
      expect(manager2.servers.length, equals(1));
      expect(manager2.servers.first.name, equals('Production Node'));
      expect(manager2.servers.first.host, equals('prod.corp.internal'));
      expect(manager2.servers.first.decryptedCredentials?.password, equals('topsecret'));
    });

    test('Locking the vault clears sensitive in-memory items from RAM', () async {
      final storage = _InMemoryStorageProvider(
        stored: SyncVaultFile(salt: salt),
        existedOnDisk: true,
      );
      final manager = VaultManager(
        storageProvider: storage,
        sftpSyncService: _FakeSftpSyncService(),
      );
      await manager.init();
      await manager.unlock(masterPassword);

      await manager.saveServer(
        ServerConfig(
          id: 'srv-1',
          name: 'Sensitive Server',
          host: '1.2.3.4',
          username: 'root',
        ),
      );
      await manager.saveStoredString(
        StoredStringItem(id: 's-1', value: 'secret-clipboard-value'),
      );

      expect(manager.servers.length, equals(1));
      expect(manager.storedStrings.length, equals(1));

      // Lock vault
      manager.lock();
      expect(manager.isUnlocked, isFalse);
      expect(manager.servers, isEmpty);
      expect(manager.storedStrings, isEmpty);

      // Re-unlock
      final unlocked = await manager.unlock(masterPassword);
      expect(unlocked, isTrue);
      expect(manager.servers.length, equals(1));
      expect(manager.servers.first.name, equals('Sensitive Server'));
      expect(manager.storedStrings.first.value, equals('secret-clipboard-value'));
    });

    test('Seamless backward compatibility: automatically upgrades legacy V1 vault to V2 envelope', () async {
      // Construct a legacy Version 1 vault JSON with plaintext servers
      final cryptoService = CryptoVaultService();
      final key = await cryptoService.deriveMasterKey(masterPassword, salt);
      final legacyServer = ServerConfig(
        id: 'legacy-srv-1',
        name: 'Legacy Server v1',
        host: 'legacy.internal.net',
        username: 'legacyuser',
        decryptedCredentials: ServerCredentials(password: 'legacyPass123'),
      );
      await legacyServer.encrypt(cryptoService, key);

      final legacyV1Json = {
        'version': 1,
        'app_id': 'com.serversync.mjolnir',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'crypto_params': {
          'kdf': 'Argon2id',
          'salt': salt,
          'iterations': 3,
          'memory_kb': 65536,
        },
        'servers': [legacyServer.toJson()],
        'tasks': [
          {
            'id': 't-legacy',
            'title': 'Legacy Task',
            'importance': 'low',
            'subtasks': [],
            'created_at': DateTime.now().toUtc().toIso8601String(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }
        ],
        'stored_strings': [
          {
            'id': 's-legacy',
            'label': 'Legacy Snippet',
            'value': 'echo legacy',
            'created_at': DateTime.now().toUtc().toIso8601String(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }
        ],
      };

      final storage = _InMemoryStorageProvider(
        stored: SyncVaultFile.fromJson(legacyV1Json),
        existedOnDisk: true,
      );
      final manager = VaultManager(
        storageProvider: storage,
        sftpSyncService: _FakeSftpSyncService(),
      );
      await manager.init();

      // Unlock legacy V1 vault
      final unlocked = await manager.unlock(masterPassword);
      expect(unlocked, isTrue);
      expect(manager.servers.length, equals(1));
      expect(manager.servers.first.name, equals('Legacy Server v1'));
      expect(manager.servers.first.decryptedCredentials?.password, equals('legacyPass123'));
      expect(manager.tasks.length, equals(1));
      expect(manager.storedStrings.length, equals(1));

      // After unlocking and saving, verify it has been converted to Version 2 Zero-Knowledge envelope
      final upgradedJson = manager.exportVaultJson();
      final decodedUpgraded = jsonDecode(upgradedJson) as Map<String, dynamic>;

      expect(decodedUpgraded['version'], equals(2));
      expect(decodedUpgraded['vault_payload'], isNotNull);
      expect(decodedUpgraded.containsKey('servers'), isFalse);
      expect(decodedUpgraded.containsKey('tasks'), isFalse);
      expect(decodedUpgraded.containsKey('stored_strings'), isFalse);
    });

    test('Zero-knowledge envelope import and station setup roundtrip', () async {
      final storage1 = _InMemoryStorageProvider(
        stored: SyncVaultFile(salt: salt),
        existedOnDisk: true,
      );
      final manager1 = VaultManager(
        storageProvider: storage1,
        sftpSyncService: _FakeSftpSyncService(
          config: SftpSyncConfig(
            host: 'sftp.zero-knowledge.net',
            port: 22,
            username: 'sync_daemon',
            password: 'daemon_sync_pass',
          ),
        ),
      );
      await manager1.init();
      await manager1.unlock(masterPassword);

      await manager1.saveServer(
        ServerConfig(
          id: 'prod-api',
          name: 'API Cluster Gateway',
          host: '10.0.1.1',
          username: 'api_admin',
          decryptedCredentials: ServerCredentials(password: 'clusterSecret!'),
        ),
      );

      final exportedEnvelopeJson = await manager1.prepareAndExportVaultJson();

      // Station 2: brand new station imports the zero-knowledge envelope
      final storage2 = _InMemoryStorageProvider(existedOnDisk: false);
      final manager2 = VaultManager(
        storageProvider: storage2,
        sftpSyncService: _FakeSftpSyncService(),
      );
      await manager2.init();

      final setup = await manager2.importAndUnlockVaultJson(
        exportedEnvelopeJson,
        masterPassword,
      );
      expect(setup.serverCount, equals(1));
      expect(setup.sftpConfigured, isTrue);
      expect(manager2.isUnlocked, isTrue);
      expect(manager2.servers.first.name, equals('API Cluster Gateway'));
      expect(manager2.servers.first.decryptedCredentials?.password, equals('clusterSecret!'));
    });
  });
}
