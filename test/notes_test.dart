import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mjolnir/models/note_item.dart';
import 'package:mjolnir/models/sync_vault_file.dart';
import 'package:mjolnir/services/crypto_vault_service.dart';
import 'package:mjolnir/services/sftp_sync_service.dart';
import 'package:mjolnir/services/sync_storage_provider.dart';
import 'package:mjolnir/services/vault_manager.dart';
import 'package:mjolnir/theme/app_color_schemes.dart';
import 'package:mjolnir/ui/notes_tab_widget.dart';

class _InMemoryStorageProvider implements SyncStorageProvider {
  SyncVaultFile? stored;

  @override
  Future<String> getProviderName() async => 'InMemory';

  @override
  Future<bool> vaultExists() async => stored != null;

  @override
  Future<SyncVaultFile> loadVault() async => stored ?? SyncVaultFile.createEmpty();

  @override
  Future<void> saveVault(SyncVaultFile vault) async => stored = vault;
}

class _FakeSftpSyncService extends SftpSyncService {
  @override
  SftpSyncConfig get config => SftpSyncConfig();

  @override
  Future<void> loadConfig() async {}
}

void main() {
  group('NoteItem title matching', () {
    test('matches case-insensitively and ignores (SSH)/(SFTP) suffix', () {
      final note = NoteItem(id: 'n1', linkedTitles: ['Prod DB']);
      expect(note.matchesTabTitle('Prod DB (SSH)'), isTrue);
      expect(note.matchesTabTitle('prod db (SFTP)'), isTrue);
      expect(note.matchesTabTitle('  PROD   DB  '), isTrue);
      expect(note.matchesTabTitle('Prod DB 2 (SSH)'), isFalse);
      expect(note.matchesTabTitle('Staging (SSH)'), isFalse);
    });

    test('linkToTabTitle strips suffix and de-duplicates', () {
      final note = NoteItem(id: 'n1');
      expect(note.linkToTabTitle('Web01 (SSH)'), isTrue);
      expect(note.linkedTitles, ['Web01']);
      expect(note.linkToTabTitle('web01 (SFTP)'), isFalse);
      expect(note.linkedTitles, ['Web01']);
      expect(note.unlinkTabTitle('WEB01 (SSH)'), isTrue);
      expect(note.linkedTitles, isEmpty);
    });

    test('displayTitle falls back to first non-empty line', () {
      expect(NoteItem(id: 'a', title: 'Hello').displayTitle, 'Hello');
      expect(NoteItem(id: 'b', content: '\n\n  first line\nsecond').displayTitle, 'first line');
      expect(NoteItem(id: 'c').displayTitle, 'Untitled note');
    });

    test('JSON round trip', () {
      final note = NoteItem(id: 'n1', title: 'T', content: 'line1\nline2', linkedTitles: ['A', 'B']);
      final back = NoteItem.fromJson(note.toJson());
      expect(back.id, 'n1');
      expect(back.title, 'T');
      expect(back.content, 'line1\nline2');
      expect(back.linkedTitles, ['A', 'B']);
    });
  });

  group('Vault persistence of notes', () {
    test('notes are encrypted in the envelope and restored on unlock', () async {
      const password = 'CorrectHorseBatteryStaple123!';
      final storage = _InMemoryStorageProvider();
      final vm = VaultManager(storageProvider: storage, sftpSyncService: _FakeSftpSyncService());
      await vm.init();
      expect(await vm.unlock(password), isTrue);

      await vm.saveNote(NoteItem(id: 'n1', title: 'Secret runbook', content: 'rm -rf /tmp/cache', linkedTitles: ['Prod']));
      expect(vm.notes, hasLength(1));

      final json = storage.stored!.toFormattedJson();
      expect(json.contains('Secret runbook'), isFalse, reason: 'note must be encrypted at rest');
      expect(json.contains('"notes"'), isFalse);

      vm.lock();
      expect(vm.notes, isEmpty);

      final vm2 = VaultManager(storageProvider: storage, sftpSyncService: _FakeSftpSyncService());
      await vm2.init();
      expect(await vm2.unlock(password), isTrue);
      expect(vm2.notes.single.title, 'Secret runbook');
      expect(vm2.notes.single.linkedTitles, ['Prod']);

      await vm2.deleteNote('n1');
      expect(vm2.notes, isEmpty);
    });

    test('mergeWith keeps the newer note', () {
      final older = DateTime.utc(2025, 1, 1);
      final newer = DateTime.utc(2026, 1, 1);
      final local = SyncVaultFile(
        salt: CryptoVaultService.generateRandomSalt(),
        notes: [NoteItem(id: 'n1', content: 'old', updatedAt: older)],
      );
      final remote = SyncVaultFile(
        salt: local.salt,
        notes: [
          NoteItem(id: 'n1', content: 'new', updatedAt: newer),
          NoteItem(id: 'n2', content: 'other'),
        ],
      );
      local.mergeWith(remote);
      expect(local.notes.firstWhere((n) => n.id == 'n1').content, 'new');
      expect(local.notes.map((n) => n.id), containsAll(['n1', 'n2']));
    });
  });

  testWidgets('NoteEditorPanel edits note and persists after debounce', (tester) async {
    final note = NoteItem(id: 'n1', title: 'Start');
    final saved = <String>[];

    await tester.pumpWidget(MaterialApp(
      theme: AppColorSchemes.mjolnirAmber.toThemeData(),
      home: Scaffold(
        body: NoteEditorPanel(
          note: note,
          onSave: (n) async => saved.add(n.content),
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField).last, 'hello\nworld');
    expect(note.content, 'hello\nworld');
    expect(saved, isEmpty);

    await tester.pump(const Duration(milliseconds: 1500));
    expect(saved, ['hello\nworld']);
    expect(find.textContaining('2 lines'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'pending');
    await NoteEditorPanel.flushAll();
    expect(saved.last, 'pending');
  });
}
