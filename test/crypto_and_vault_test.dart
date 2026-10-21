import 'package:flutter_test/flutter_test.dart';
import 'package:mjolnir/models/server_config.dart';
import 'package:mjolnir/models/sync_vault_file.dart';
import 'package:mjolnir/services/crypto_vault_service.dart';

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
  });
}
