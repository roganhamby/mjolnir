import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:mjolnir/models/server_config.dart';
import 'package:mjolnir/services/ssh_service.dart';
import 'package:mjolnir/ui/sftp_tab_widget.dart';

class _NoOpSshService extends SshService {
  @override
  Future<SftpSession> startSftpSession(
    ServerConfig server, {
    HostKeyPromptHandler? onPromptHostKey,
  }) async {
    throw Exception('Offline test mode');
  }
}

void main() {
  late Directory tempDir;
  late ServerConfig dummyServer;
  late SshService sshService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mjolnir_sftp_multiselect_');
    await Directory(p.join(tempDir.path, 'alpha_dir')).create();
    await File(p.join(tempDir.path, 'file_a.txt')).writeAsString('A');
    await File(p.join(tempDir.path, 'file_b.txt')).writeAsString('B');
    await File(p.join(tempDir.path, 'file_c.txt')).writeAsString('C');
    await File(p.join(tempDir.path, 'file_d.txt')).writeAsString('D');

    dummyServer = ServerConfig(
      id: 'test-srv',
      name: 'Test Server',
      host: '127.0.0.1',
      port: 22,
      username: 'tester',
    );
    sshService = _NoOpSshService();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Widget buildTestWidget() {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1000,
          height: 700,
          child: SftpTabWidget(
            server: dummyServer,
            sshService: sshService,
            initialLocalPath: tempDir.path,
          ),
        ),
      ),
    );
  }

  testWidgets('Shift+click selects a contiguous range of files in SFTP window', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(buildTestWidget());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(find.text('file_a.txt'), findsOneWidget);
    expect(find.text('file_b.txt'), findsOneWidget);
    expect(find.text('file_c.txt'), findsOneWidget);
    expect(find.text('file_d.txt'), findsOneWidget);

    // Click file_a.txt to select it as anchor
    await tester.tap(find.text('file_a.txt'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);

    // Hold Shift and click file_c.txt -> should select file_a.txt, file_b.txt, file_c.txt
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('file_c.txt'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(find.text('3 selected'), findsOneWidget);

    // Hold Shift and click file_d.txt -> should expand range from anchor file_a.txt to file_d.txt
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('file_d.txt'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(find.text('4 selected'), findsOneWidget);
  });

  testWidgets('Control/Command+click selects and toggles discrete files', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(buildTestWidget());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    // Click file_a.txt
    await tester.tap(find.text('file_a.txt'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);

    // Hold Control and click file_c.txt
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('file_c.txt'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);

    // Hold Command (Meta) and click file_d.txt
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tap(find.text('file_d.txt'));
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);

    // Command+click file_c.txt again to deselect it
    await tester.tap(find.text('file_c.txt'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);

    // Select All button selects all 5 entries (1 folder + 4 files)
    await tester.tap(find.text('Select All'));
    await tester.pump();
    expect(find.text('5 selected'), findsOneWidget);

    // Clear selection via Clear button
    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(find.textContaining('selected'), findsNothing);
  });
}
