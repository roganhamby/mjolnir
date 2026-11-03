import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mjolnir/main.dart';
import 'package:mjolnir/models/server_config.dart';
import 'package:mjolnir/models/sync_vault_file.dart';
import 'package:mjolnir/services/known_hosts_service.dart';
import 'package:mjolnir/services/ssh_service.dart';
import 'package:mjolnir/services/vault_manager.dart';
import 'package:mjolnir/services/sync_storage_provider.dart';

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

class _OfflineSshService extends SshService {
  @override
  Future<SshSession> startShellSession(
    ServerConfig server, {
    int terminalWidth = 80,
    int terminalHeight = 24,
    int terminalPixelWidth = 0,
    int terminalPixelHeight = 0,
    int Function()? getTerminalWidth,
    int Function()? getTerminalHeight,
    int Function()? getTerminalPixelWidth,
    int Function()? getTerminalPixelHeight,
    HostKeyPromptHandler? onPromptHostKey,
  }) async {
    throw HostKeyUnknownException(
      host: server.host,
      port: server.port,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:offlineTest',
    );
  }
}

void main() {
  group('TabItem Timer Unit Tests', () {
    test('TabItem timer starts, increments, stops, and resets', () {
      final tab = TabItem(
        id: 'test-1',
        title: 'Test Tab',
        icon: Icons.terminal,
        type: 'ssh',
      );

      expect(tab.timerSeconds, equals(0));
      expect(tab.isTimerRunning, isFalse);
      expect(tab.formattedTimer, equals('00:00'));

      int tickCount = 0;
      tab.startTimer(() => tickCount++);
      expect(tab.isTimerRunning, isTrue);

      tab.timerSeconds = 65; // 1 minute 5 seconds
      expect(tab.formattedTimer, equals('01:05'));

      tab.timerSeconds = 3661; // 1 hour 1 minute 1 second
      expect(tab.formattedTimer, equals('1:01:01'));

      tab.stopTimer();
      expect(tab.isTimerRunning, isFalse);
      expect(tab.timerSeconds, equals(3661));

      tab.resetTimer();
      expect(tab.timerSeconds, equals(0));
      expect(tab.formattedTimer, equals('00:00'));
    });
  });

  group('Per-Tab Timer Widget Integration Tests', () {
    late VaultManager vaultManager;
    late SshService sshService;

    setUp(() async {
      final provider = _InMemoryStorageProvider();
      vaultManager = VaultManager(storageProvider: provider);
      await vaultManager.init();
      await vaultManager.unlock('test-password-123');
      await vaultManager.saveServer(
        ServerConfig(
          id: 'srv-1',
          name: 'Alpha',
          host: '10.0.0.1',
          port: 22,
          username: 'root',
        ),
      );
      sshService = _OfflineSshService();
    });

    Widget buildApp() {
      return MaterialApp(
        home: MainScreen(
          vaultManager: vaultManager,
          sshService: sshService,
        ),
      );
    }

    Future<void> openSshTerminalTab(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open SSH Terminal'));
      await tester.pumpAndSettle();
    }

    testWidgets('Timer is positioned left of the recording button and starts, ticks, stops, and resets', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await openSshTerminalTab(tester);

      expect(find.text('Alpha (SSH)'), findsOneWidget);
      expect(find.text('00:00'), findsOneWidget);

      // Verify timer is to the left of the button to start recording
      final timerCenter = tester.getCenter(find.text('00:00'));
      final recordBtnCenter = tester.getCenter(find.byIcon(Icons.fiber_manual_record_outlined));
      expect(timerCenter.dx, lessThan(recordBtnCenter.dx));
      expect((timerCenter.dy - recordBtnCenter.dy).abs(), lessThan(10));

      // Tap timer capsule to start
      final timerFinder = find.ancestor(
        of: find.text('00:00'),
        matching: find.byType(InkWell),
      ).first;

      await tester.tap(timerFinder);
      await tester.pump();

      // Advance by 3 seconds
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('00:03'), findsOneWidget);

      // Tap timer capsule to stop
      final activeTimer = find.ancestor(
        of: find.text('00:03'),
        matching: find.byType(InkWell),
      ).first;

      await tester.tap(activeTimer);
      await tester.pump();

      // Verify timer stayed stopped
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('00:03'), findsOneWidget);

      // Tap Reset button (refresh icon inside timer widget)
      final resetFinder = find.byTooltip('Reset timer to 00:00');
      expect(resetFinder, findsOneWidget);
      await tester.tap(resetFinder);
      await tester.pump();

      // Successfully reset to 00:00
      expect(find.text('00:00'), findsOneWidget);
      expect(resetFinder, findsNothing);
    });

    testWidgets('Timer auto-stops when tab is clicked off (switched)', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      // Open Tasks tab and SSH terminal tab
      await tester.tap(find.text('Tasks'));
      await tester.pumpAndSettle();

      await openSshTerminalTab(tester);

      expect(find.text('Task Manager'), findsOneWidget);
      expect(find.text('Alpha (SSH)'), findsOneWidget);

      // Start timer on SSH terminal tab (currently active)
      final sshTimer = find.ancestor(
        of: find.text('00:00'),
        matching: find.byType(InkWell),
      ).first;

      await tester.tap(sshTimer);
      await tester.pump();

      // Tick for 4 seconds
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('00:04'), findsOneWidget);

      // Click off: switch to Task Manager tab
      await tester.tap(find.text('Task Manager'));
      await tester.pumpAndSettle();

      // Advance 5 seconds while on Task Manager tab
      await tester.pump(const Duration(seconds: 5));

      // Switch back to SSH terminal tab and verify timer auto-stopped at 00:04
      await tester.tap(find.text('Alpha (SSH)'));
      await tester.pumpAndSettle();
      expect(find.text('00:04'), findsOneWidget);
    });

    testWidgets('Timer auto-stops when window loses focus (app lifecycle inactive)', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await openSshTerminalTab(tester);

      // Start timer
      final timerPill = find.ancestor(
        of: find.text('00:00'),
        matching: find.byType(InkWell),
      ).first;

      await tester.tap(timerPill);
      await tester.pump();

      // Advance 5 seconds
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('00:05'), findsOneWidget);

      // Simulate window losing focus (inactive state)
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();

      // Advance time while window is inactive
      await tester.pump(const Duration(seconds: 5));

      // Timer must remain auto-stopped at 00:05
      expect(find.text('00:05'), findsOneWidget);
      expect(find.byIcon(Icons.pause), findsNothing);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });
  });
}
