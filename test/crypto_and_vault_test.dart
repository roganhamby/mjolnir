import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mjolnir/models/server_config.dart';
import 'package:mjolnir/models/stored_string_item.dart';
import 'package:mjolnir/models/task_item.dart';
import 'package:mjolnir/models/sync_vault_file.dart';
import 'package:mjolnir/services/crypto_vault_service.dart';
import 'package:mjolnir/services/dropbox_sync_service.dart';
import 'package:mjolnir/services/ssh_service.dart';
import 'package:mjolnir/services/sync_storage_provider.dart';
import 'package:mjolnir/services/vault_manager.dart';
import 'package:mjolnir/theme/app_color_schemes.dart';

class _InMemoryStorageProvider implements SyncStorageProvider {
  SyncVaultFile? stored;
  bool existedOnDisk;

  _InMemoryStorageProvider({this.stored, this.existedOnDisk = true});

  @override
  Future<String> getProviderName() async => 'Memory';

  @override
  Future<bool> vaultExists() async => existedOnDisk;

  @override
  Future<SyncVaultFile> loadVault() async {
    stored ??= SyncVaultFile.createEmpty();
    return stored!;
  }

  @override
  Future<void> saveVault(SyncVaultFile vault) async {
    stored = vault;
    existedOnDisk = true;
  }
}

class _FakeDropboxSyncService extends DropboxSyncService {
  final ({SyncVaultFile vault, String rawJson, String filePath, DateTime modifiedAt})? remoteResult;
  DropboxConfig fakeConfig;

  _FakeDropboxSyncService({
    required this.remoteResult,
    DropboxConfig? config,
  }) : fakeConfig = config ?? DropboxConfig(accessToken: 'fake-token', folderPath: '/App/Mjolnir');

  @override
  DropboxConfig get config => fakeConfig;

  @override
  Future<void> loadConfig() async {}

  @override
  Future<({SyncVaultFile vault, String rawJson, String filePath, DateTime modifiedAt})?> fetchNewestVaultFromDropbox() async {
    return remoteResult;
  }
}

void main() {
  group('CryptoVaultService & Envelope Encryption Tests', () {
    final cryptoService = CryptoVaultService();
    const masterPassword = 'CorrectHorseBatteryStaple123!';
    final salt = CryptoVaultService.generateRandomSalt();

    test('Derives key and encrypts/decrypts credentials correctly', () async {
      final key = await cryptoService.deriveMasterKey(masterPassword, salt);

      final originalPayload = {
        'password': 'SuperSecretServerPassword',
        'privateKey': '-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----',
        'passphrase': 'key-passphrase',
      };

      final encrypted = await cryptoService.encryptPayload(
        payload: originalPayload,
        masterKey: key,
      );

      expect(encrypted['nonce'], isNotEmpty);
      expect(encrypted['tag'], isNotEmpty);
      expect(encrypted['ciphertext'], isNotEmpty);

      final decrypted = await cryptoService.decryptPayload(
        encryptedData: encrypted,
        masterKey: key,
      );

      expect(decrypted['password'], equals('SuperSecretServerPassword'));
      expect(decrypted['passphrase'], equals('key-passphrase'));
    });

    test('Fails decryption with wrong master password', () async {
      final realKey = await cryptoService.deriveMasterKey(masterPassword, salt);
      final wrongKey = await cryptoService.deriveMasterKey('WrongPassword!', salt);

      final encrypted = await cryptoService.encryptPayload(
        payload: {'password': 'secret'},
        masterKey: realKey,
      );

      expect(
        () async => await cryptoService.decryptPayload(
          encryptedData: encrypted,
          masterKey: wrongKey,
        ),
        throwsA(anything),
      );
    });

    test('ServerConfig model serialization and encryption roundtrip', () async {
      final key = await cryptoService.deriveMasterKey(masterPassword, salt);

      final server = ServerConfig(
        id: 'srv-123',
        name: 'Production Web',
        host: 'example.com',
        port: 2222,
        username: 'admin',
        authType: AuthType.password,
        decryptedCredentials: ServerCredentials(password: 'adminPass123'),
      );

      await server.encrypt(cryptoService, key);
      expect(server.encryptedCredentials, isNotNull);

      final jsonMap = server.toJson();
      final loadedServer = ServerConfig.fromJson(jsonMap);

      expect(loadedServer.id, equals('srv-123'));
      expect(loadedServer.name, equals('Production Web'));
      expect(loadedServer.decryptedCredentials, isNull);

      await loadedServer.decrypt(cryptoService, key);
      expect(loadedServer.decryptedCredentials?.password, equals('adminPass123'));
    });

    test('SyncVaultFile merge strategy preserves latest per-server updates', () {
      final vaultA = SyncVaultFile(
        salt: salt,
        servers: [
          ServerConfig(
            id: 's1',
            name: 'Server 1 v1',
            host: 's1.com',
            username: 'root',
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
          ServerConfig(
            id: 's2',
            name: 'Server 2',
            host: 's2.com',
            username: 'root',
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        ],
      );

      final vaultB = SyncVaultFile(
        salt: salt,
        servers: [
          ServerConfig(
            id: 's1',
            name: 'Server 1 v2 (Updated remotely)',
            host: 's1.com',
            username: 'root',
            updatedAt: DateTime.utc(2026, 1, 2),
          ),
          ServerConfig(
            id: 's3',
            name: 'Server 3 (New remote)',
            host: 's3.com',
            username: 'root',
            updatedAt: DateTime.utc(2026, 1, 2),
          ),
        ],
      );

      vaultA.mergeWith(vaultB);

      expect(vaultA.servers.length, equals(3));
      final s1 = vaultA.servers.firstWhere((s) => s.id == 's1');
      expect(s1.name, equals('Server 1 v2 (Updated remotely)'));
    });

    test('TaskItem serialization, importance levels, subtasks, and due date overdue check', () {
      final pastDue = DateTime.now().subtract(const Duration(minutes: 5));
      final futureDue = DateTime.now().add(const Duration(minutes: 30));

      final overdueTask = TaskItem(
        id: 't1',
        title: 'Rotate SSH keys',
        importance: TaskImportance.priority,
        dueDate: pastDue,
        subtasks: [
          SubTaskItem(id: 'sub1', title: 'Generate new Ed25519 keypair', isCompleted: true),
          SubTaskItem(id: 'sub2', title: 'Deploy to authorized_keys', isCompleted: false),
        ],
      );
      final upcomingTask = TaskItem(
        id: 't2',
        title: 'Verify backup logs',
        importance: TaskImportance.medium,
        dueDate: futureDue,
      );

      expect(overdueTask.isOverdue, isTrue);
      expect(overdueTask.completedSubtaskCount, equals(1));
      expect(upcomingTask.isOverdue, isFalse);
      expect(upcomingTask.completedSubtaskCount, equals(0));

      final vault = SyncVaultFile(
        salt: salt,
        tasks: [overdueTask, upcomingTask],
      );

      final restored = SyncVaultFile.fromJson(vault.toJson());
      expect(restored.tasks.length, equals(2));
      expect(restored.tasks.first.importance, equals(TaskImportance.priority));
      expect(restored.tasks.first.title, equals('Rotate SSH keys'));
      expect(restored.tasks.first.subtasks.length, equals(2));
      expect(restored.tasks.first.completedSubtaskCount, equals(1));
      expect(restored.tasks.first.subtasks[0].title, equals('Generate new Ed25519 keypair'));
      expect(restored.tasks.first.subtasks[0].isCompleted, isTrue);
      expect(restored.tasks.first.subtasks[1].title, equals('Deploy to authorized_keys'));
      expect(restored.tasks.first.subtasks[1].isCompleted, isFalse);
    });

    test('StoredStringItem serialization, JSON export, and import merge', () async {
      final str1 = StoredStringItem(
        id: 'str-1',
        label: 'Docker logs cmd',
        value: 'docker logs -f --tail 100 my-container',
        updatedAt: DateTime.utc(2026, 6, 1, 10, 0),
      );
      final str2 = StoredStringItem(
        id: 'str-2',
        label: '',
        value: 'sudo systemctl restart nginx',
        updatedAt: DateTime.utc(2026, 6, 1, 10, 0),
      );

      final storageA = _InMemoryStorageProvider(
        stored: SyncVaultFile(salt: salt),
        existedOnDisk: true,
      );
      final managerA = VaultManager(
        storageProvider: storageA,
        dropboxService: _FakeDropboxSyncService(remoteResult: null),
      );
      await managerA.init();
      await managerA.unlock(masterPassword);

      await managerA.saveStoredString(str1);
      await managerA.saveStoredString(str2);
      expect(managerA.storedStrings.length, equals(2));

      final exportedJson = managerA.exportVaultJson();

      final storageB = _InMemoryStorageProvider(
        stored: SyncVaultFile(
          salt: salt,
          storedStrings: [
            StoredStringItem(
              id: 'str-1',
              label: 'Old Label',
              value: 'docker logs old',
              updatedAt: DateTime.utc(2026, 5, 1, 10, 0),
            ),
          ],
        ),
        existedOnDisk: true,
      );
      final managerB = VaultManager(
        storageProvider: storageB,
        dropboxService: _FakeDropboxSyncService(remoteResult: null),
      );
      await managerB.init();
      await managerB.unlock(masterPassword);

      await managerB.importVaultJson(exportedJson, masterPassword);
      expect(managerB.storedStrings.length, equals(2));
      final mergedStr1 = managerB.storedStrings.firstWhere((s) => s.id == 'str-1');
      expect(mergedStr1.label, equals('Docker logs cmd'));
      expect(mergedStr1.value, equals('docker logs -f --tail 100 my-container'));

      await managerB.deleteStoredString('str-2');
      expect(managerB.storedStrings.length, equals(1));
    });

    test('VaultManager uses the newest vault between Local and Dropbox (/App/Mjolnir) on load', () async {
      final olderLocalVault = SyncVaultFile(
        salt: salt,
        updatedAt: DateTime.utc(2026, 5, 1, 10, 0),
        servers: [
          ServerConfig(
            id: 'srv-old',
            name: 'Old Local Server',
            host: '10.0.0.1',
            username: 'root',
          ),
        ],
      );

      final newerDropboxVault = SyncVaultFile(
        salt: salt,
        updatedAt: DateTime.utc(2026, 5, 2, 14, 30),
        servers: [
          ServerConfig(
            id: 'srv-new',
            name: 'New Dropbox Server',
            host: '10.0.0.2',
            username: 'ubuntu',
          ),
        ],
      );

      final storage = _InMemoryStorageProvider(
        stored: olderLocalVault,
        existedOnDisk: true,
      );
      final dropbox = _FakeDropboxSyncService(
        remoteResult: (
          vault: newerDropboxVault,
          rawJson: newerDropboxVault.toFormattedJson(),
          filePath: '/App/Mjolnir/servers.json',
          modifiedAt: newerDropboxVault.updatedAt,
        ),
      );

      expect(dropbox.normalizedFolderPath, equals('/App/Mjolnir'));

      final manager = VaultManager(
        storageProvider: storage,
        dropboxService: dropbox,
      );
      await manager.init();

      expect(manager.servers.length, equals(1));
      expect(manager.servers.first.name, equals('New Dropbox Server'));
      expect(manager.loadedSource, contains('Dropbox (/App/Mjolnir/servers.json)'));
    });

    test('AppColorSchemes provides valid dark and light color schemes and ThemeData', () {
      expect(AppColorSchemes.all.length, greaterThanOrEqualTo(10));
      for (final scheme in AppColorSchemes.all.values) {
        final theme = scheme.toThemeData();
        expect(theme.extension<AppColorScheme>()?.name, equals(scheme.name));
        expect(AppColorSchemes.byName(scheme.name).name, equals(scheme.name));
      }
      expect(AppColorSchemes.byName('non_existent_id').name, equals(AppColorSchemes.mjolnirAmber.name));
    });

    test('SshService includes +ssh-rsa hostkey and legacy Kex/Cipher fallbacks', () async {
      final hostkeys = SshService.compatibleAlgorithms.hostkey.map((h) => h.name).toList();
      expect(hostkeys, contains('ssh-rsa'));
      expect(hostkeys.first, equals('ssh-ed25519'));
      expect(hostkeys.last, equals('ssh-rsa'));

      final kexNames = SshService.compatibleAlgorithms.kex.map((k) => k.name).toList();
      expect(kexNames, contains('diffie-hellman-group14-sha1'));
      expect(kexNames, contains('diffie-hellman-group1-sha1'));

      // Verify legacy ssh-rsa PKCS#1 v1.5 SHA-1 signature generation
      // Using a known 512-bit RSA test key (p=2^255+95, q=...) or small valid modulus >= 384 bits
      final p = BigInt.parse('115792089237316195423570985008687907853269984665640564039457584007913129640233');
      final q = BigInt.parse('115792089237316195423570985008687907853269984665640564039457584007913129640381');
      final n = p * q;
      final e = BigInt.from(65537);
      final phi = (p - BigInt.one) * (q - BigInt.one);
      final d = e.modInverse(phi);

      final msg = Uint8List.fromList('ssh-handshake-challenge'.codeUnits);
      final sigBytes = await SshService.rsaPkcs1v15Sha1Sign(n: n, d: d, message: msg);
      final encodedSig = SshService.encodeSshSignature('ssh-rsa', sigBytes);
      expect(SSHSignature.getType(encodedSig.encode()), equals('ssh-rsa'));
    });

    test('ServerConfig defaults SFTP remote path to ~/ and supports alternate defaults', () {
      final defaultServer = ServerConfig(
        id: 'srv-default',
        name: 'Default Path Server',
        host: 'example.com',
        username: 'alice',
      );
      expect(defaultServer.defaultRemotePath, equals('~/'));

      // Legacy server JSON with old hardcoded '/' default migrates to '~/'
      final legacyServer = ServerConfig.fromJson({
        'id': 'srv-legacy',
        'name': 'Legacy Server',
        'host': 'example.com',
        'username': 'alice',
        'default_remote_path': '/',
      });
      expect(legacyServer.defaultRemotePath, equals('~/'));

      // Alternate default path is preserved across serialization
      final customServer = ServerConfig(
        id: 'srv-custom',
        name: 'Custom Path Server',
        host: 'example.com',
        username: 'alice',
        defaultRemotePath: '/var/www/html',
        customRemotePathSet: true,
      );
      final restoredCustom = ServerConfig.fromJson(customServer.toJson());
      expect(restoredCustom.defaultRemotePath, equals('/var/www/html'));
      expect(restoredCustom.customRemotePathSet, isTrue);

      // Explicitly configured '/' as an alternate default is preserved when customRemotePathSet is true
      final explicitRoot = ServerConfig(
        id: 'srv-root',
        name: 'Explicit Root Server',
        host: 'example.com',
        username: 'root',
        defaultRemotePath: '/',
        customRemotePathSet: true,
      );
      final restoredRoot = ServerConfig.fromJson(explicitRoot.toJson());
      expect(restoredRoot.defaultRemotePath, equals('/'));
      expect(restoredRoot.customRemotePathSet, isTrue);
    });

    test('SshService.resolveRemotePath expands ~/ and relative paths against remote home', () {
      const home = '/home/rogan';
      expect(SshService.resolveRemotePath('~/', homePath: home), equals('/home/rogan'));
      expect(SshService.resolveRemotePath('~', homePath: home), equals('/home/rogan'));
      expect(SshService.resolveRemotePath('', homePath: home), equals('/home/rogan'));
      expect(SshService.resolveRemotePath('.', homePath: home), equals('/home/rogan'));
      expect(
        SshService.resolveRemotePath('~/projects/mjolnir', homePath: home),
        equals('/home/rogan/projects/mjolnir'),
      );
      expect(
        SshService.resolveRemotePath('downloads', homePath: home),
        equals('/home/rogan/downloads'),
      );
      expect(
        SshService.resolveRemotePath('/var/www/app', homePath: home),
        equals('/var/www/app'),
      );
      expect(
        SshService.resolveRemotePath('/', homePath: home),
        equals('/'),
      );
    });

    test('SshService.uploadStreamWithOffsets writes multi-chunk streams at sequential offsets without corruption', () async {
      // Simulate a 200 KB file split into multiple unequal chunks (like File.openRead)
      final totalSize = 200 * 1024;
      final expectedBytes = Uint8List(totalSize);
      for (var i = 0; i < totalSize; i++) {
        expectedBytes[i] = (i * 31 + 7) & 0xff;
      }

      final chunks = <List<int>>[
        expectedBytes.sublist(0, 65536),
        expectedBytes.sublist(65536, 131072),
        expectedBytes.sublist(131072, 196608),
        expectedBytes.sublist(196608, totalSize),
      ];

      final remoteBuffer = Uint8List(totalSize);
      final recordedOffsets = <int>[];
      var lastProgress = 0;

      final totalUploaded = await SshService.uploadStreamWithOffsets(
        source: Stream<List<int>>.fromIterable(chunks),
        writeChunk: (chunk, offset) async {
          recordedOffsets.add(offset);
          remoteBuffer.setRange(offset, offset + chunk.length, chunk);
        },
        onProgress: (uploaded) {
          lastProgress = uploaded;
        },
      );

      expect(totalUploaded, equals(totalSize));
      expect(lastProgress, equals(totalSize));
      expect(recordedOffsets, equals([0, 65536, 131072, 196608]));
      expect(remoteBuffer, equals(expectedBytes));
    });
  });
}
