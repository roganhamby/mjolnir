import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/terminal_macro_item.dart';
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

/// Manages interactive shell input monitoring and expansion for ??macros.
///
/// Ensures macros only trigger at natural boundaries (start of line or after whitespace),
/// preventing accidental expansion during SQL type casts (e.g. col::text or a??b).
class TerminalMacroEngine {
  String _macroLineBuffer = '';
  String _inputLineTracker = '';

  String get macroLineBuffer => _macroLineBuffer;
  String get inputLineTracker => _inputLineTracker;

  void reset() {
    _macroLineBuffer = '';
    _inputLineTracker = '';
  }

  /// Processes raw terminal input [data].
  /// Returns `true` if a macro expansion was handled and the raw input should be consumed.
  bool processInput({
    required String data,
    required List<TerminalMacroItem> macros,
    required bool isUsingAltBuffer,
    required void Function(List<int> bytes) writeRaw,
    required void Function(TerminalMacroItem macro) onTriggerSecret,
  }) {
    // If the terminal is using alt buffer (vim, nano, htop, less), do not intercept
    if (isUsingAltBuffer) {
      reset();
      return false;
    }

    // Line resets or interrupts (Ctrl+C, Ctrl+U, Escape)
    if (data.contains('\x03') || data.contains('\x15') || data.contains('\x1b')) {
      reset();
      return false;
    }

    // Backspace handling (\x7f or \x08)
    if (data == '\x7f' || data == '\x08') {
      if (_macroLineBuffer.isNotEmpty) {
        _macroLineBuffer = _macroLineBuffer.substring(0, _macroLineBuffer.length - 1);
      }
      if (_inputLineTracker.isNotEmpty) {
        _inputLineTracker = _inputLineTracker.substring(0, _inputLineTracker.length - 1);
      }
      return false;
    }

    final isEnter = data.contains('\r') || data.contains('\n');
    final isTab = data == '\t';

    if (isEnter || isTab) {
      if (_macroLineBuffer.startsWith('??')) {
        final content = _macroLineBuffer.substring(2).trimLeft();
        if (content.isNotEmpty) {
          final spaceIndex = content.indexOf(' ');
          final triggerWord = (spaceIndex >= 0 ? content.substring(0, spaceIndex) : content).toLowerCase();
          final rawArgs = spaceIndex >= 0 ? content.substring(spaceIndex + 1).trim() : '';

          TerminalMacroItem? matchedMacro;
          for (final m in macros) {
            if (m.cleanTrigger.toLowerCase() == triggerWord) {
              matchedMacro = m;
              break;
            }
          }

          if (matchedMacro != null) {
            final typedLength = _macroLineBuffer.length;
            final expandedCommand = matchedMacro.interpolate(rawArgs);

            // 1. Send backspaces to erase typed ??trigger args from the shell line
            writeRaw(List.filled(typedLength, 0x7F));

            // 2. Write the expanded command
            writeRaw(utf8.encode(expandedCommand));

            // 3. If Enter was pressed and executeImmediately is true, send carriage return
            if (isEnter && matchedMacro.executeImmediately) {
              writeRaw(utf8.encode('\r'));
            }

            // 4. Handle password/secret copy with auto-clear
            if (matchedMacro.copySecretToClipboard &&
                matchedMacro.secretValue != null &&
                matchedMacro.secretValue!.isNotEmpty) {
              onTriggerSecret(matchedMacro);
            }

            reset();
            return true;
          }
        }
      }
      _macroLineBuffer = '';
      if (isEnter) {
        _inputLineTracker = '';
      } else {
        _inputLineTracker += data;
      }
      return false;
    }

    // Space expansion on macros without parameters
    if (data == ' ' && _macroLineBuffer.startsWith('??') && !_macroLineBuffer.contains(' ')) {
      final triggerWord = _macroLineBuffer.substring(2).toLowerCase();
      TerminalMacroItem? matchedMacro;
      for (final m in macros) {
        if (m.cleanTrigger.toLowerCase() == triggerWord) {
          matchedMacro = m;
          break;
        }
      }

      if (matchedMacro != null &&
          !matchedMacro.replacement.contains('{1}') &&
          !matchedMacro.replacement.contains('{args}') &&
          !matchedMacro.replacement.contains(RegExp(r'\{file(name)?\}', caseSensitive: false))) {
        final typedLength = _macroLineBuffer.length;
        writeRaw(List.filled(typedLength, 0x7F));
        writeRaw(utf8.encode(matchedMacro.replacement));

        if (matchedMacro.copySecretToClipboard &&
            matchedMacro.secretValue != null &&
            matchedMacro.secretValue!.isNotEmpty) {
          onTriggerSecret(matchedMacro);
        }

        _macroLineBuffer = '';
        _inputLineTracker = matchedMacro.replacement;
        return true;
      }
    }

    // Accumulate printable characters into _macroLineBuffer.
    // Boundary check: ?? can only start at the beginning of a line or preceded by whitespace.
    final isBoundary = _inputLineTracker.isEmpty ||
        _inputLineTracker.endsWith(' ') ||
        _inputLineTracker.endsWith('\t');

    if (_macroLineBuffer.isEmpty) {
      if (isBoundary) {
        if (data == '?') {
          _macroLineBuffer = '?';
        } else if (data.startsWith('??')) {
          _macroLineBuffer = data;
        }
      }
    } else if (_macroLineBuffer == '?') {
      if (data == '?') {
        _macroLineBuffer = '??';
      } else if (data.startsWith('?')) {
        _macroLineBuffer = '?$data';
      } else {
        _macroLineBuffer = '';
      }
    } else {
      _macroLineBuffer += data;
    }

    _inputLineTracker += data;
    if (_inputLineTracker.length > 2000) {
      _inputLineTracker = _inputLineTracker.substring(_inputLineTracker.length - 1000);
    }

    return false;
  }
}
