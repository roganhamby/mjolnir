import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../ui/app_notification.dart';

class TerminalMacroService {
  static Timer? _clearTimer;
  static String? _lastCopiedSecret;

  /// Copies [secret] to the system clipboard and starts an auto-clear timer
  /// for [clearSeconds] (defaults to 60s).
  static Future<void> copySecretWithAutoClear({
    required BuildContext context,
    required String secret,
    required String macroName,
    int clearSeconds = 60,
  }) async {
    if (secret.isEmpty) return;

    await Clipboard.setData(ClipboardData(text: secret));
    _lastCopiedSecret = secret;
    _clearTimer?.cancel();

    if (context.mounted) {
      final msg = clearSeconds > 0
          ? 'Macro "$macroName" triggered. Password copied to clipboard (clears in ${clearSeconds}s).'
          : 'Macro "$macroName" triggered. Password copied to clipboard.';
      AppNotification.show(
        context,
        message: msg,
        duration: const Duration(seconds: 4),
      );
    }

    if (clearSeconds > 0) {
      _clearTimer = Timer(Duration(seconds: clearSeconds), () async {
        try {
          final current = await Clipboard.getData(Clipboard.kTextPlain);
          // Only clear if the clipboard still contains the exact secret we injected
          if (current?.text == _lastCopiedSecret) {
            await Clipboard.setData(const ClipboardData(text: ''));
            _lastCopiedSecret = null;
            if (context.mounted) {
              AppNotification.show(
                context,
                message: 'Macro clipboard password cleared for security.',
                duration: const Duration(seconds: 2),
              );
            }
          }
        } catch (_) {}
      });
    }
  }

  /// Cancels any active auto-clear timer
  static void cancelPendingClear() {
    _clearTimer?.cancel();
    _clearTimer = null;
  }
}
