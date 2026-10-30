import 'package:flutter_test/flutter_test.dart';
import 'package:mjolnir/models/server_config.dart';
import 'package:mjolnir/models/sync_vault_file.dart';
import 'package:mjolnir/services/sftp_sync_service.dart';
import 'package:mjolnir/services/ssh_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SftpSyncConfig Tests', () {
    test('Default config is unconfigured and points to ~/.mjolnir/servers.json', () {
      final config = SftpSyncConfig();
      expect(config.isConfigured, isFalse);
      expect(config.host, isEmpty);
      expect(config.port, equals(22));
      expect(config.username, isEmpty);
      expect(config.remotePath, equals('~/.mjolnir/servers.json'));
      expect(config.autoSyncOnLoadAndSave, isTrue);
    });

    test('isConfigured is true when host and username are non-empty', () {
      final config = SftpSyncConfig(
        host: 'sftp.example.com',
        username: 'admin',
      );
      expect(config.isConfigured, isTrue);
    });

    test('Serializes to JSON and deserializes accurately', () {
      final config = SftpSyncConfig(
        host: 'ssh.server.net',
        port: 2222,
        username: 'devuser',
        authType: AuthType.privateKey,
        privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----',
        passphrase: 'secret-passphrase',
        remotePath: '/var/backups/mjolnir.json',
        autoSyncOnLoadAndSave: false,
      );

      final json = config.toJson();
      expect(json['host'], equals('ssh.server.net'));
      expect(json['port'], equals(2222));
      expect(json['username'], equals('devuser'));
      expect(json['auth_type'], equals('privateKey'));
      expect(json['private_key'], contains('OPENSSH'));
      expect(json['passphrase'], equals('secret-passphrase'));
      expect(json['remote_path'], equals('/var/backups/mjolnir.json'));
      expect(json['auto_sync'], isFalse);

      final restored = SftpSyncConfig.fromJson(json);
      expect(restored.host, equals(config.host));
      expect(restored.port, equals(config.port));
      expect(restored.username, equals(config.username));
      expect(restored.authType, equals(config.authType));
      expect(restored.privateKey, equals(config.privateKey));
      expect(restored.passphrase, equals(config.passphrase));
      expect(restored.remotePath, equals(config.remotePath));
      expect(restored.autoSyncOnLoadAndSave, equals(config.autoSyncOnLoadAndSave));
    });

    test('fromServerConfig correctly pre-fills connection parameters', () {
      final server = ServerConfig(
        id: 'srv-1',
        name: 'Production Node',
        host: 'prod.company.org',
        port: 2200,
        username: 'sysadmin',
        authType: AuthType.password,
        decryptedCredentials: ServerCredentials(password: 'hunter2'),
      );

      final config = SftpSyncConfig.fromServerConfig(
        server,
        remotePath: '~/.config/mjolnir/vault.json',
      );

      expect(config.host, equals('prod.company.org'));
      expect(config.port, equals(2200));
      expect(config.username, equals('sysadmin'));
      expect(config.authType, equals(AuthType.password));
      expect(config.password, equals('hunter2'));
      expect(config.remotePath, equals('~/.config/mjolnir/vault.json'));
      expect(config.isConfigured, isTrue);

      final asServer = config.toServerConfig();
      expect(asServer.host, equals('prod.company.org'));
      expect(asServer.port, equals(2200));
      expect(asServer.username, equals('sysadmin'));
      expect(asServer.connectionType, equals(ConnectionType.sftp));
      expect(asServer.decryptedCredentials?.password, equals('hunter2'));
    });
  });

  group('SFTP Remote Path Resolution Tests', () {
    test('Resolves ~/ relative to home path', () {
      final resolved = SshService.resolveRemotePath(
        '~/.mjolnir/servers.json',
        homePath: '/home/rogan',
      );
      expect(resolved, equals('/home/rogan/.mjolnir/servers.json'));
    });

    test('Leaves absolute paths unchanged', () {
      final resolved = SshService.resolveRemotePath(
        '/var/vault/servers.json',
        homePath: '/home/rogan',
      );
      expect(resolved, equals('/var/vault/servers.json'));
    });

    test('Expands ~ to homePath', () {
      final resolved = SshService.resolveRemotePath(
        '~',
        homePath: '/root',
      );
      expect(resolved, equals('/root'));
    });
  });

  group('SyncVaultFile with encrypted SFTP Sync Config', () {
    test('Persists and restores encryptedSftpSyncConfig in vault JSON', () {
      final vault = SyncVaultFile(
        salt: 'test-salt-1234',
        encryptedSftpSyncConfig: {
          'nonce': 'abc',
          'cipher_text': 'xyz',
          'mac': '123',
        },
      );

      final json = vault.toJson();
      expect(json['encrypted_sftp_sync_config'], isNotNull);
      expect(json['encrypted_sftp_sync_config']['nonce'], equals('abc'));

      final restored = SyncVaultFile.fromJson(json);
      expect(restored.encryptedSftpSyncConfig, isNotNull);
      expect(restored.encryptedSftpSyncConfig!['nonce'], equals('abc'));
    });

    test('isNewerVault detects candidate with encryptedSftpSyncConfig on fresh baseline', () {
      final baseline = SyncVaultFile.createEmpty();
      final candidate = SyncVaultFile(
        salt: 'cand-salt',
        encryptedSftpSyncConfig: {'dummy': 'config'},
      );

      expect(
        SyncVaultFile.isNewerVault(candidate, baseline, baselineExistedOnDisk: false),
        isTrue,
      );
    });
  });
}
