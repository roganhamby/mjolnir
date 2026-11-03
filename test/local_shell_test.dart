import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mjolnir/main.dart';
import 'package:mjolnir/models/sync_vault_file.dart';
import 'package:mjolnir/services/local_shell_service.dart';
import 'package:mjolnir/services/sync_storage_provider.dart';
import 'package:mjolnir/services/vault_manager.dart';

class _InMemoryStorageProvider implements SyncStorageProvider {
  SyncVaultFile? stored;

  @override
  Future<String> getProviderName() async => 'Memory';

  @override
  Future<bool> vaultExists() async => true;

  @override
  Future<SyncVaultFile> loadVault() async {
    stored ??= SyncVaultFile.createEmpty();
    return stored!;
  }

  @override
  Future<void> saveVault(SyncVaultFile vault) async {
    stored = vault;
  }
}

class _FakeLocalShellSession implements LocalShellSession {
  @override
  final String shellPath = '/bin/bash';

  final StreamController<Uint8List> _stdoutController =
      StreamController<Uint8List>.broadcast();
  final StreamController<Uint8List> _stderrController =
      StreamController<Uint8List>.broadcast();

  final List<String> writtenInputs = [];
  int lastWidth = 80;
  int lastHeight = 24;
  bool _closed = false;

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  int? get exitCode => _closed ? 0 : null;

  @override
  bool get isClosed => _closed;

  @override
  void write(Uint8List data) {
    final text = utf8.decode(data, allowMalformed: true);
    writtenInputs.add(text);
    _stdoutController.add(data);
  }

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {
    lastWidth = width;
    lastHeight = height;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _stdoutController.close();
    _stderrController.close();
  }
}

class _FakeLocalShellService extends LocalShellService {
  final List<_FakeLocalShellSession> sessions = [];

  @override
  Future<LocalShellSession> startLocalShellSession({
    int terminalWidth = 80,
    int terminalHeight = 24,
    int terminalPixelWidth = 0,
    int terminalPixelHeight = 0,
  }) async {
    final session = _FakeLocalShellSession()
      ..lastWidth = terminalWidth
      ..lastHeight = terminalHeight;
    sessions.add(session);
    return session;
  }
}

void main() {
  group('LocalShellService POSIX PTY Unit Tests', () {
    test('Spawns real POSIX PTY local shell, executes commands, and resizes', () async {
      const service = LocalShellService();
      final session = await service.startLocalShellSession(
        terminalWidth: 100,
        terminalHeight: 30,
      );

      final outputBuffer = StringBuffer();
      final completer = Completer<void>();

      final sub = session.stdout.listen((chunk) {
        outputBuffer.write(utf8.decode(chunk, allowMalformed: true));
        if (outputBuffer.toString().contains('MJOLNIR_PTY_OK') &&
            !completer.isCompleted) {
          completer.complete();
        }
      });

      session.resizeTerminal(120, 40);
      session.write(
        Uint8List.fromList(utf8.encode('echo MJOLNIR_PTY_OK\r\nexit\r\n')),
      );

      await completer.future.timeout(const Duration(seconds: 5));
      expect(outputBuffer.toString(), contains('MJOLNIR_PTY_OK'));

      await sub.cancel();
      session.close();
      expect(session.isClosed, isTrue);
    });
  });

  group('Sidebar Local Shell Integration Tests', () {
    late VaultManager vaultManager;

    setUp(() async {
      final provider = _InMemoryStorageProvider();
      vaultManager = VaultManager(storageProvider: provider);
      await vaultManager.init();
      await vaultManager.unlock('test-password-123');
    });

    testWidgets('Clicking Local Shell in left sidebar opens a Local Shell terminal tab', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeShellService = _FakeLocalShellService();

      await tester.pumpWidget(
        MaterialApp(
          home: MainScreen(
            vaultManager: vaultManager,
            localShellService: fakeShellService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify Local Shell option is visible under the SERVERS header in the left sidebar
      expect(find.text('Local Shell'), findsOneWidget);
      expect(find.text('LOCAL'), findsOneWidget);

      // Tap Local Shell in the sidebar
      await tester.tap(find.text('Local Shell'));
      await tester.pumpAndSettle();

      // Verify Local Shell tab opened and session started
      expect(fakeShellService.sessions.length, equals(1));
      expect(find.text('Local Shell (/bin/bash)'), findsOneWidget);
      expect(find.text('00:00'), findsOneWidget);
    });
  });
}
