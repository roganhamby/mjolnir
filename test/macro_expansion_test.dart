import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mjolnir/models/server_config.dart';
import 'package:mjolnir/models/terminal_macro_item.dart';
import 'package:mjolnir/models/sync_vault_file.dart';
import 'package:mjolnir/services/crypto_vault_service.dart';
import 'package:mjolnir/services/ssh_service.dart';
import 'package:mjolnir/services/terminal_macro_service.dart';
import 'package:mjolnir/ui/macros_tab_widget.dart';
import 'package:mjolnir/ui/terminal_tab_widget.dart';
import 'package:mjolnir/theme/app_color_schemes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalMacroItem Model & Interpolation', () {
    test('interpolates single positional argument {1}', () {
      final macro = TerminalMacroItem(
        id: '1',
        name: 'Send to Nox',
        trigger: '::send',
        replacement: 'scp -oHostKeyAlgorithms=+ssh-rsa {1} rhamby@nox.esilibrary.com:~/temp/',
      );

      expect(macro.cleanTrigger, 'send');
      expect(macro.formattedTrigger, '::send');

      final result = macro.interpolate('this.txt');
      expect(
        result,
        'scp -oHostKeyAlgorithms=+ssh-rsa this.txt rhamby@nox.esilibrary.com:~/temp/',
      );
    });

    test('interpolates {file} and {filename} aliases', () {
      final macro = TerminalMacroItem(
        id: '2',
        name: 'File alias',
        trigger: 'sendfile',
        replacement: 'cat {file} | tee backup/{file}',
      );

      final result = macro.interpolate('data.csv');
      expect(result, 'cat data.csv | tee backup/data.csv');
    });

    test('interpolates multiple arguments {1} and {2}', () {
      final macro = TerminalMacroItem(
        id: '3',
        name: 'Copy remote',
        trigger: 'cpr',
        replacement: 'scp {1} host:{2}',
      );

      final result = macro.interpolate('local.txt /var/log/remote.txt');
      expect(result, 'scp local.txt host:/var/log/remote.txt');
    });

    test('handles quoted arguments containing spaces', () {
      final macro = TerminalMacroItem(
        id: '4',
        name: 'Send quoted',
        trigger: 'send',
        replacement: 'scp "{1}" user@host:/dest/',
      );

      final result = macro.interpolate('"my report 2026.pdf"');
      expect(result, 'scp "my report 2026.pdf" user@host:/dest/');
    });

    test('interpolates {args} for full trailing arguments', () {
      final macro = TerminalMacroItem(
        id: '5',
        name: 'Git commit',
        trigger: 'gc',
        replacement: 'git commit -m "{args}"',
      );

      final result = macro.interpolate('fix: resolved terminal issue');
      expect(result, 'git commit -m "fix: resolved terminal issue"');
    });

    test('appends arguments if no placeholders exist in replacement', () {
      final macro = TerminalMacroItem(
        id: '6',
        name: 'Checkout',
        trigger: 'co',
        replacement: 'git checkout',
      );

      final result = macro.interpolate('feature-branch');
      expect(result, 'git checkout feature-branch');
    });

    test('toJson and fromJson preserves all fields', () {
      final macro = TerminalMacroItem(
        id: '7',
        name: 'Deploy',
        trigger: '::deploy',
        replacement: './deploy.sh {1}',
        executeImmediately: true,
        copySecretToClipboard: true,
        secretValue: 'SuperSecret123!',
        autoClearClipboardSeconds: 60,
      );

      final json = macro.toJson();
      expect(json['trigger'], 'deploy');
      expect(json['copy_secret_to_clipboard'], true);
      expect(json['secret_value'], 'SuperSecret123!');
      expect(json['auto_clear_clipboard_seconds'], 60);

      final fromJson = TerminalMacroItem.fromJson(json);
      expect(fromJson.id, macro.id);
      expect(fromJson.name, macro.name);
      expect(fromJson.cleanTrigger, 'deploy');
      expect(fromJson.replacement, macro.replacement);
      expect(fromJson.copySecretToClipboard, true);
      expect(fromJson.secretValue, 'SuperSecret123!');
      expect(fromJson.autoClearClipboardSeconds, 60);
    });
  });

  group('SyncVaultFile Encrypted Payload with Macros', () {
    test('encrypts and decrypts macros in SyncVaultFile', () async {
      final cryptoService = CryptoVaultService();
      final masterKey = await cryptoService.deriveMasterKey(
        'TestVaultPassword123!',
        CryptoVaultService.generateRandomSalt(),
      );

      final vault = SyncVaultFile.createEmpty();
      final macro = TerminalMacroItem(
        id: 'macro-1',
        name: 'Send to Nox',
        trigger: 'send',
        replacement: 'scp -oHostKeyAlgorithms=+ssh-rsa {1} rhamby@nox.esilibrary.com:~/temp/',
        copySecretToClipboard: true,
        secretValue: 'NoxPassword!',
        autoClearClipboardSeconds: 60,
      );
      vault.macros.add(macro);

      // Encrypt
      await vault.encryptPayload(cryptoService, masterKey);
      expect(vault.vaultPayload, isNotNull);

      // Decrypt into empty lists
      vault.macros = [];
      await vault.decryptPayload(cryptoService, masterKey);

      expect(vault.macros.length, 1);
      expect(vault.macros.first.name, 'Send to Nox');
      expect(vault.macros.first.cleanTrigger, 'send');
      expect(vault.macros.first.secretValue, 'NoxPassword!');
      expect(vault.macros.first.copySecretToClipboard, true);
      expect(vault.macros.first.autoClearClipboardSeconds, 60);
    });

    test('merges remote macros based on timestamps', () {
      final vault1 = SyncVaultFile.createEmpty();
      final macroLocal = TerminalMacroItem(
        id: 'm1',
        name: 'Local Version',
        trigger: 'run',
        replacement: 'echo local',
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      vault1.macros.add(macroLocal);

      final vault2 = SyncVaultFile.createEmpty();
      final macroRemoteNewer = TerminalMacroItem(
        id: 'm1',
        name: 'Remote Newer',
        trigger: 'run',
        replacement: 'echo remote',
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      final macroRemoteNew = TerminalMacroItem(
        id: 'm2',
        name: 'Brand New',
        trigger: 'new',
        replacement: 'echo new',
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      vault2.macros.addAll([macroRemoteNewer, macroRemoteNew]);

      vault1.mergeWith(vault2);
      expect(vault1.macros.length, 2);
      expect(vault1.macros.firstWhere((m) => m.id == 'm1').name, 'Remote Newer');
      expect(vault1.macros.firstWhere((m) => m.id == 'm2').name, 'Brand New');
    });
  });

  group('TerminalMacroService Clipboard Auto-Clear', () {
    testWidgets('copies secret and auto-clears after timer', (tester) async {
      String? currentClipboardText;

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            final args = methodCall.arguments as Map<dynamic, dynamic>;
            currentClipboardText = args['text'] as String?;
            return null;
          } else if (methodCall.method == 'Clipboard.getData') {
            return {'text': currentClipboardText};
          }
          return null;
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppColorSchemes.mjolnirAmber.toThemeData(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return ElevatedButton(
                  onPressed: () {
                    TerminalMacroService.copySecretWithAutoClear(
                      context: context,
                      secret: 'SuperSecret123',
                      macroName: 'Send to Nox',
                      clearSeconds: 1, // 1 second for test speed
                    );
                  },
                  child: const Text('Trigger'),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('Trigger'));
      await tester.pump();

      expect(currentClipboardText, 'SuperSecret123');

      // Fast-forward past the 1s auto-clear timer
      await tester.pump(const Duration(seconds: 2));
      expect(currentClipboardText, '');
    });
  });

  group('MacrosTabWidget UI', () {
    testWidgets('renders macro list, search, and displays trigger pills', (tester) async {
      final macros = [
        TerminalMacroItem(
          id: 'm1',
          name: 'Send to Nox',
          trigger: 'send',
          replacement: 'scp -oHostKeyAlgorithms=+ssh-rsa {1} rhamby@nox.esilibrary.com:~/temp/',
          copySecretToClipboard: true,
          secretValue: 'noxPass',
          autoClearClipboardSeconds: 60,
        ),
        TerminalMacroItem(
          id: 'm2',
          name: 'Git Status',
          trigger: 'gs',
          replacement: 'git status',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: AppColorSchemes.mjolnirAmber.toThemeData(),
          home: Scaffold(
            body: MacrosTabWidget(
              macros: macros,
              onSaveMacro: (_) async {},
              onDeleteMacro: (_) async {},
            ),
          ),
        ),
      );

      expect(find.text('Terminal Macros (2)'), findsOneWidget);
      expect(find.text('::send'), findsOneWidget);
      expect(find.text('Send to Nox'), findsOneWidget);
      expect(find.text('::gs'), findsOneWidget);
      expect(find.text('Git Status'), findsOneWidget);
      expect(find.text('Password (60s clear)'), findsOneWidget);

      // Test search filter
      await tester.enterText(find.byType(TextField).first, 'nox');
      await tester.pump();

      expect(find.text('::send'), findsOneWidget);
      expect(find.text('::gs'), findsNothing);
    });
  });
}
