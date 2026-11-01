import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mjolnir/models/server_config.dart';
import 'package:mjolnir/services/known_hosts_service.dart';
import 'package:mjolnir/ui/host_key_verify_dialog.dart';
import 'package:mjolnir/ui/app_notification.dart';

void main() {
  group('KnownHostsService Core Tests', () {
    late Directory tempDir;
    late String tempFilePath;
    late KnownHostsService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('known_hosts_test_');
      tempFilePath = '${tempDir.path}/known_hosts.json';
      service = KnownHostsService(customFilePath: tempFilePath);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Unknown host returns HostKeyStatus.unknown (Trust On First Use)', () async {
      final result = await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:abc123firsttimefingerprint',
      );

      expect(result.status, equals(HostKeyStatus.unknown));
      expect(result.isUnknown, isTrue);
      expect(result.isTrusted, isFalse);
      expect(result.isMismatch, isFalse);
      expect(result.previousFingerprint, isNull);
    });

    test('Trusting a host key persists and allows subsequent verification', () async {
      const host = '192.168.1.100';
      const port = 2222;
      const keyType = 'ssh-rsa';
      const fp = 'SHA256:originalValidFingerprint123';

      await service.trustHostKey(
        host: host,
        port: port,
        keyType: keyType,
        fingerprint: fp,
      );

      final result = await service.verifyHostKey(
        host: host,
        port: port,
        keyType: keyType,
        fingerprint: fp,
      );

      expect(result.status, equals(HostKeyStatus.trusted));
      expect(result.isTrusted, isTrue);
      expect(result.fingerprint, equals(fp));
      expect(result.entry, isNotNull);
      expect(result.entry!.host, equals(host));
      expect(result.entry!.port, equals(port));
    });

    test('Fingerprint mismatch triggers HostKeyStatus.mismatch (MITM detection)', () async {
      const host = 'secure.internal.corp';
      const port = 22;
      const keyType = 'ssh-ed25519';
      const genuineFp = 'SHA256:trustedKeyFingerprintA';
      const attackerFp = 'SHA256:maliciousAttackerFingerprintB';

      // 1. Establish trusted key
      await service.trustHostKey(
        host: host,
        port: port,
        keyType: keyType,
        fingerprint: genuineFp,
      );

      // 2. MITM scenario: server returns a different fingerprint
      final result = await service.verifyHostKey(
        host: host,
        port: port,
        keyType: keyType,
        fingerprint: attackerFp,
      );

      expect(result.status, equals(HostKeyStatus.mismatch));
      expect(result.isMismatch, isTrue);
      expect(result.isTrusted, isFalse);
      expect(result.fingerprint, equals(attackerFp));
      expect(result.previousFingerprint, equals(genuineFp));
    });

    test('File persistence: reloaded service retains known hosts across instances', () async {
      const host = 'miskatonicuniversity.net';
      const port = 22;
      const fp = 'SHA256:persistentFingerprintXYZ';

      await service.trustHostKey(
        host: host,
        port: port,
        keyType: 'ssh-ed25519',
        fingerprint: fp,
      );

      // Create a fresh instance reading the same file
      final service2 = KnownHostsService(customFilePath: tempFilePath);
      final entries = await service2.getEntriesForHost(host: host, port: port);

      expect(entries.length, equals(1));
      expect(entries.first.fingerprint, equals(fp));

      final verify = await service2.verifyHostKey(
        host: host,
        port: port,
        keyType: 'ssh-ed25519',
        fingerprint: fp,
      );
      expect(verify.status, equals(HostKeyStatus.trusted));
    });

    test('Removing a host key restores unknown status', () async {
      const host = 'temporary.test.io';
      const port = 22;
      const fp = 'SHA256:tempFingerprint';

      await service.trustHostKey(
        host: host,
        port: port,
        keyType: 'ssh-ed25519',
        fingerprint: fp,
      );

      final removed = await service.removeHostKey(host: host, port: port);
      expect(removed, isTrue);

      final verify = await service.verifyHostKey(
        host: host,
        port: port,
        keyType: 'ssh-ed25519',
        fingerprint: fp,
      );
      expect(verify.status, equals(HostKeyStatus.unknown));
    });

    test('Multiple key types for the same host are managed independently', () async {
      const host = 'multikey.domain.org';
      const port = 22;
      const rsaFp = 'SHA256:rsaKey';
      const edFp = 'SHA256:edKey';

      await service.trustHostKey(host: host, port: port, keyType: 'ssh-rsa', fingerprint: rsaFp);
      await service.trustHostKey(host: host, port: port, keyType: 'ssh-ed25519', fingerprint: edFp);

      final entries = await service.getEntriesForHost(host: host, port: port);
      expect(entries.length, equals(2));

      // Remove only RSA
      await service.removeHostKey(host: host, port: port, keyType: 'ssh-rsa');

      final remaining = await service.getEntriesForHost(host: host, port: port);
      expect(remaining.length, equals(1));
      expect(remaining.first.keyType, equals('ssh-ed25519'));
    });
  });

  group('Pinned Fingerprint Security Tests', () {
    test('ServerConfig with pinned fingerprint matches successfully', () {
      final server = ServerConfig(
        id: 'srv-1',
        name: 'Pinned Server',
        host: 'bastion.infra.net',
        username: 'admin',
        expectedHostKey: 'SHA256:pinnedKeyValid123',
      );

      expect(server.expectedHostKey, equals('SHA256:pinnedKeyValid123'));
    });

    test('ServerConfig JSON serialization preserves expectedHostKey', () {
      final server = ServerConfig(
        id: 'srv-2',
        name: 'Secure Server',
        host: 'prod.infra.net',
        username: 'ops',
        expectedHostKey: 'SHA256:pinnedKeyXYZ',
      );

      final json = server.toJson();
      expect(json['expected_host_key'], equals('SHA256:pinnedKeyXYZ'));

      final reconstructed = ServerConfig.fromJson(json);
      expect(reconstructed.expectedHostKey, equals('SHA256:pinnedKeyXYZ'));
    });
  });

  group('HostKeyVerifyDialog UI Tests', () {
    Widget buildTestHostKeyApp(Widget child) {
      return MaterialApp(
        navigatorKey: AppNotification.navigatorKey,
        home: Scaffold(body: child),
      );
    }

    testWidgets('TOFU Dialog presents unknown host details and Trust button', (tester) async {
      final server = ServerConfig(
        id: 'srv1',
        name: 'Server 1',
        host: 'srv1.example.org',
        port: 22,
        username: 'user',
      );

      await tester.pumpWidget(
        buildTestHostKeyApp(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => HostKeyVerifyDialog.show(
                context,
                server: server,
                keyType: 'ssh-ed25519',
                fingerprint: 'SHA256:abcdef1234567890',
                isMismatch: false,
              ),
              child: const Text('Open Dialog'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      expect(find.text('Verify Host Authenticity'), findsOneWidget);
      expect(find.text('srv1.example.org:22'), findsOneWidget);
      expect(find.text('SHA256:abcdef1234567890'), findsOneWidget);
      expect(find.text('Trust & Connect'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      // Tap Trust & Connect
      await tester.tap(find.text('Trust & Connect'));
      await tester.pumpAndSettle();

      expect(find.text('Verify Host Authenticity'), findsNothing);
    });

    testWidgets('MITM Alert Dialog locks Proceed button until user acknowledges risk', (tester) async {
      final server = ServerConfig(
        id: 'victim',
        name: 'Victim Server',
        host: 'victim.corp.net',
        port: 22,
        username: 'victim',
      );

      await tester.pumpWidget(
        buildTestHostKeyApp(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => HostKeyVerifyDialog.show(
                context,
                server: server,
                keyType: 'ssh-ed25519',
                fingerprint: 'SHA256:NEW_UNEXPECTED_KEY',
                isMismatch: true,
                previousFingerprint: 'SHA256:OLD_TRUSTED_KEY',
              ),
              child: const Text('Open MITM Alert'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open MITM Alert'));
      await tester.pumpAndSettle();

      expect(find.text('REMOTE HOST IDENTIFICATION CHANGED!'), findsOneWidget);
      expect(find.text('SHA256:NEW_UNEXPECTED_KEY'), findsOneWidget);
      expect(find.text('SHA256:OLD_TRUSTED_KEY'), findsOneWidget);

      // The Replace Key button should initially be disabled
      final proceedButtonFinder = find.widgetWithText(OutlinedButton, 'Replace Key & Continue');
      final OutlinedButton proceedButton = tester.widget(proceedButtonFinder);
      expect(proceedButton.onPressed, isNull); // Disabled

      // Toggle acknowledgment checkbox
      final checkboxFinder = find.byType(Checkbox);
      expect(checkboxFinder, findsOneWidget);
      await tester.ensureVisible(checkboxFinder);
      await tester.tap(checkboxFinder);
      await tester.pumpAndSettle();

      // The button should now be enabled
      final OutlinedButton enabledProceedButton = tester.widget(proceedButtonFinder);
      expect(enabledProceedButton.onPressed, isNotNull);

      // Tap Abort Connection
      await tester.tap(find.text('Abort Connection (Recommended)'));
      await tester.pumpAndSettle();

      expect(find.text('REMOTE HOST IDENTIFICATION CHANGED!'), findsNothing);
    });
  });
}
