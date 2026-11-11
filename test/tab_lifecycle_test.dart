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
  String get machineName => 'test-box';

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
  group('Tab session persistence when closing other tabs', () {
    late VaultManager vaultManager;

    setUp(() async {
      final provider = _InMemoryStorageProvider();
      vaultManager = VaultManager(storageProvider: provider);
      await vaultManager.init();
      await vaultManager.unlock('test-password-123');
    });

    testWidgets('Closing a tab does not reset or reconnect other open terminal tabs', (tester) async {
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

      // Open Tab 1: Local Shell
      await tester.tap(find.text('Local Shell').first);
      await tester.pumpAndSettle();

      expect(fakeShellService.sessions.length, equals(1));
      final session1 = fakeShellService.sessions[0];
      expect(session1.isClosed, isFalse);

      // Open Tab 2: Local Shell
      await tester.tap(find.text('Local Shell').first);
      await tester.pumpAndSettle();

      expect(fakeShellService.sessions.length, equals(2));
      final session2 = fakeShellService.sessions[1];
      expect(session2.isClosed, isFalse);

      // We now have two open tabs.
      // Find the close buttons on the tab strip.
      final closeButtons = find.byIcon(Icons.close);
      expect(closeButtons, findsNWidgets(2));

      // Close the first tab
      await tester.tap(closeButtons.first);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // Tab 1 should be closed
      expect(session1.isClosed, isTrue);

      // Tab 2 MUST remain alive and open!
      expect(session2.isClosed, isFalse, reason: 'Tab 2 session was closed when Tab 1 was closed!');

      // No new sessions should have been spawned (would indicate a reconnect / reset)
      expect(fakeShellService.sessions.length, equals(2),
          reason: 'A new session was spawned, indicating the tab reconnected!');

      // Verify only 1 tab remains in the tab bar
      expect(find.byIcon(Icons.close), findsOneWidget);

      // Verify Tab 2 continues to receive input and can write without error
      session2.write(Uint8List.fromList(utf8.encode('echo active_after_close\r\n')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(session2.writtenInputs, contains('echo active_after_close\r\n'));
      expect(session2.isClosed, isFalse);
    });

    testWidgets('Three tabs: closing first or last tab never resets active tab session', (tester) async {
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

      // Open 3 tabs
      await tester.tap(find.text('Local Shell').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local Shell').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local Shell').first);
      await tester.pumpAndSettle();

      expect(fakeShellService.sessions.length, equals(3));
      final s0 = fakeShellService.sessions[0];
      final s1 = fakeShellService.sessions[1];
      final s2 = fakeShellService.sessions[2];

      expect(s0.isClosed, isFalse);
      expect(s1.isClosed, isFalse);
      expect(s2.isClosed, isFalse);

      // Switch to middle tab (tab index 1 in the tab bar; index 0 is sidebar)
      // find.text('Local Shell'): 0 = sidebar, 1 = tab 0, 2 = tab 1, 3 = tab 2
      await tester.tap(find.text('Local Shell').at(2));
      await tester.pump(const Duration(milliseconds: 100));

      // Close the third tab (index 2)
      var closeButtons = find.byIcon(Icons.close);
      expect(closeButtons, findsNWidgets(3));
      await tester.tap(closeButtons.at(2));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // Tab 3 is closed, tabs 0 and 1 must still be open
      expect(s2.isClosed, isTrue);
      expect(s0.isClosed, isFalse);
      expect(s1.isClosed, isFalse);
      expect(fakeShellService.sessions.length, equals(3), reason: 'No new sessions created');

      // Wait past the tab close debounce cooldown (350ms) using real clock
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pumpAndSettle();

      // Now close the first tab (index 0)
      closeButtons = find.byIcon(Icons.close);
      expect(closeButtons, findsNWidgets(2));
      await tester.tap(closeButtons.at(0));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // Tab 0 is now closed, Tab 1 must still be open and alive
      expect(s0.isClosed, isTrue);
      expect(s1.isClosed, isFalse);
      expect(fakeShellService.sessions.length, equals(3), reason: 'Tab 1 must not have reconnected');

      // Send input to Tab 1 to verify it functions normally
      s1.write(Uint8List.fromList(utf8.encode('echo still_alive\r\n')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(s1.writtenInputs, contains('echo still_alive\r\n'));
      expect(s1.isClosed, isFalse);
    });
  });
}
