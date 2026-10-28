import 'package:flutter_test/flutter_test.dart';
import 'package:mjolnir/services/dropbox_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DropboxSyncService Path & Normalization Tests', () {
    test('Default folder path normalizes to root "" and displays "All files / Apps / Mjolnir"', () {
      final service = DropboxSyncService();
      expect(service.config.folderPath, equals(''));
      expect(service.normalizedFolderPath, equals(''));
      expect(service.displayFolderPath, equals('All files / Apps / Mjolnir'));
    });

    test('Migrates legacy /App/Mjolnir and /App to root ""', () {
      final legacyConfig1 = DropboxConfig.fromJson({
        'access_token': 'test-token',
        'folder_path': '/App/Mjolnir',
      });
      expect(legacyConfig1.folderPath, equals(''));

      final legacyConfig2 = DropboxConfig.fromJson({
        'access_token': 'test-token',
        'folder_path': '/App',
      });
      expect(legacyConfig2.folderPath, equals(''));

      final legacyConfig3 = DropboxConfig.fromJson({
        'access_token': 'test-token',
        'folder_path': 'Apps/Mjolnir',
      });
      expect(legacyConfig3.folderPath, equals(''));

      final slashConfig = DropboxConfig.fromJson({
        'access_token': 'test-token',
        'folder_path': '/',
      });
      expect(slashConfig.folderPath, equals(''));
    });

    test('Custom subfolder paths are normalized with leading slash without trailing slash', () {
      final config = DropboxConfig(
        accessToken: 'test-token',
        folderPath: 'backups/staging/',
      );
      final service = DropboxSyncService()..saveConfig(config);
      // Wait for service config
      service.config.folderPath = 'backups/staging/';
      expect(service.normalizedFolderPath, equals('/backups/staging'));
      expect(
        service.displayFolderPath,
        equals('All files / Apps / Mjolnir/backups/staging'),
      );
    });

    test('Root folder target paths do not create double slashes', () {
      final service = DropboxSyncService();
      final folder = service.normalizedFolderPath;
      const fileName = 'servers.json';
      final targetPath = folder.isEmpty ? '/$fileName' : '$folder/$fileName';
      expect(targetPath, equals('/servers.json'));
      expect(targetPath.contains('//'), isFalse);
    });
  });
}
