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
  ///
  /// [data] may contain several characters at once (IME/soft keyboards, fast typing,
  /// or "text + Enter" delivered in one event). Multi-character input is processed one
  /// character at a time. If an expansion happens, the engine writes the whole chunk
  /// (passthrough characters included) through [writeRaw] and returns `true`.
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

    // Escape sequences (arrow keys, history navigation, bracketed paste, focus events)
    // move the cursor or change the line in ways we can't track.
    if (data.contains('\x1b')) {
      reset();
      return false;
    }

    final chars = data.runes.map(String.fromCharCode).toList();
    if (chars.isEmpty) return false;
    if (chars.length == 1) {
      return _processChar(
        data: data,
        macros: macros,
        writeRaw: writeRaw,
        onTriggerSecret: onTriggerSecret,
      );
    }

    // Multi-character chunk: feed characters one at a time, buffering passthrough
    // characters so they reach the shell before any expansion backspaces.
    final pending = StringBuffer();
    var expanded = false;
    void flushPending() {
      if (pending.isNotEmpty) {
        writeRaw(utf8.encode(pending.toString()));
        pending.clear();
      }
    }

    var lastHandled = false;
    for (var i = 0; i < chars.length; i++) {
      final c = chars[i];
      // Treat CRLF as a single Enter: if the '\r' triggered an expansion, drop the '\n'.
      if (c == '\n' && i > 0 && chars[i - 1] == '\r') {
        if (!lastHandled) pending.write(c);
        continue;
      }
      final handled = _processChar(
        data: c,
        macros: macros,
        writeRaw: (bytes) {
          flushPending();
          writeRaw(bytes);
        },
        onTriggerSecret: onTriggerSecret,
      );
      lastHandled = handled;
      if (handled) {
        expanded = true;
      } else {
        pending.write(c);
      }
    }

    if (!expanded) {
      // Nothing expanded: let the caller forward the original chunk unchanged.
      return false;
    }
    flushPending();
    return true;
  }

  /// Fallback expansion for Enter, based on the text actually shown on the shell's
  /// current (logical) line rather than tracked keystrokes.
  ///
  /// Keystroke tracking loses sync when the line is changed in ways we can't mirror:
  /// history recall (Up/Down, Ctrl+R), bracketed paste, cursor movement, etc. In those
  /// cases the user still sees `??trigger args` on screen, so read it from there.
  ///
  /// [lineText] is the full logical line (prompt included, wrapped rows joined) and
  /// [cursorOffset] is the cursor's character offset within it.
  /// Returns `true` if a macro was expanded and the Enter key should be consumed.
  bool expandFromScreenLine({
    required String lineText,
    required int cursorOffset,
    required List<TerminalMacroItem> macros,
    required void Function(List<int> bytes) writeRaw,
    required void Function(TerminalMacroItem macro) onTriggerSecret,
  }) {
    final textEnd = lineText.trimRight().length;
    if (textEnd == 0 || macros.isEmpty) return false;
    final visible = lineText.substring(0, textEnd);

    // ?? must start the line or follow whitespace (same boundary rule as typed input).
    final pattern = RegExp(r'(?<=^|\s)\?\?(\S+)');
    for (final match in pattern.allMatches(visible)) {
      final triggerWord = match.group(1)!.toLowerCase();
      TerminalMacroItem? matchedMacro;
      for (final m in macros) {
        if (m.cleanTrigger.isNotEmpty && m.cleanTrigger.toLowerCase() == triggerWord) {
          matchedMacro = m;
          break;
        }
      }
      if (matchedMacro == null) continue;

      final rawArgs = visible.substring(match.end).trim();
      final cursorAtEnd = cursorOffset >= textEnd;
      // If the cursor sits mid-line, jump to end of line (readline Ctrl+E) first so
      // the backspaces erase the whole ??macro invocation.
      final eraseEnd = cursorAtEnd ? cursorOffset : textEnd;
      if (!cursorAtEnd) writeRaw(const [0x05]);
      writeRaw(List.filled(eraseEnd - match.start, 0x7F));
      writeRaw(utf8.encode(matchedMacro.interpolate(rawArgs)));
      if (matchedMacro.executeImmediately) {
        writeRaw(utf8.encode('\r'));
      }
      if (matchedMacro.copySecretToClipboard &&
          matchedMacro.secretValue != null &&
          matchedMacro.secretValue!.isNotEmpty) {
        onTriggerSecret(matchedMacro);
      }
      reset();
      return true;
    }
    return false;
  }

  bool _processChar({
    required String data,
    required List<TerminalMacroItem> macros,
    required void Function(List<int> bytes) writeRaw,
    required void Function(TerminalMacroItem macro) onTriggerSecret,
  }) {
    // Ctrl+L (clear screen) redraws the prompt but keeps the current line intact.
    if (data == '\x0c') {
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

    // Any other control character (Ctrl+C, Ctrl+U, Ctrl+W, Ctrl+A, Ctrl+K, ...) either
    // discards the line or edits/moves within it in ways we can't mirror. Reset tracking
    // rather than recording the control byte as line text, which would otherwise block
    // the start-of-word boundary check for the next ??macro on this line.
    final code = data.codeUnitAt(0);
    if (code < 0x20 && data != '\t' && data != '\r' && data != '\n') {
      reset();
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
