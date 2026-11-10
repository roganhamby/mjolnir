/// Sanitizes text copied from AI models (like Gemini/ChatGPT), web browsers,
/// and rich-text renderers before pasting into terminal sessions and editors
/// (such as nano, vi, or bash).
class TerminalClipboardSanitizer {
  /// Sanitizes [input] to eliminate common paste artifacts:
  /// - LaTeX / KaTeX math delimiters for pipes (`\vert{}`, `\vert{`, `\vert`, `\lvert`, `\rvert`, `\mid`) -> `|`
  /// - Double pipe delimiters (`\Vert`, `\parallel`) -> `||`
  /// - LaTeX backslashes (`\textbackslash`, `\backslash`) -> `\`
  /// - LaTeX tilde (`\sim`) -> `~`
  /// - HTML entities (`&vert;`, `&#124;`, `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#39;`, `&nbsp;`)
  /// - Smart / curly quotes (`“ ” „ ‟` -> `"`, `‘ ’ ‚ ‛` -> `'`)
  /// - Typographical dashes and minus (`—` -> `--`, `–` -> `-`, `−` -> `-`)
  /// - Non-breaking and unicode spaces (`\u00A0`, `\u202F`, etc.) -> ASCII space
  /// - Zero-width and invisible characters (`\u200B`, `\u200C`, `\u200D`, `\uFEFF`, etc.) -> stripped
  /// - Broken line continuation (trailing whitespace after `\` before newlines) -> `\`
  /// - Rogue ASCII control characters (`\x00`..`\x08`, `\x0B`, `\x0C`, `\x0E`..`\x1F`, `\x7F`)
  ///   which prematurely exit editor modes or trigger unintended editor commands.
  static String sanitize(String input) {
    if (input.isEmpty) return input;
    var text = input;

    // 1. Strip zero-width & invisible unicode characters that silently break shells and syntax
    text = text.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF\u2060]'), '');

    // 2. Normalize non-breaking and special unicode spaces to standard ASCII space
    text = text.replaceAll(RegExp(r'[\u00A0\u202F\u2000-\u200A]'), ' ');

    // 3. Normalize smart quotes and typographical dashes/minus
    text = text
        .replaceAll(RegExp(r'[\u201C\u201D\u201E\u201F]'), '"')
        .replaceAll(RegExp(r'[\u2018\u2019\u201A\u201B]'), "'")
        .replaceAll('\u2014', '--') // Em dash: commonly converts '--' CLI flags
        .replaceAll('\u2013', '-')  // En dash
        .replaceAll('\u2212', '-'); // Unicode minus sign

    // 4. HTML entities often copied from web/markdown renderers
    text = text
        .replaceAll('&vert;', '|')
        .replaceAll('&#124;', '|')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#160;', ' ');

    // 5. LaTeX / KaTeX math delimiters commonly emitted by Gemini/web renderers
    // Replace \vert{}, \vert{, \vert, \lvert, \rvert, \mid with pipe |
    text = text.replaceAll(RegExp(r'\\(?:lvert|rvert|vert)\{\s*\}'), '|');
    text = text.replaceAll(RegExp(r'\\(?:lvert|rvert|vert)\{'), '|');
    text = text.replaceAll(RegExp(r'\\(?:lvert|rvert|vert)(?![a-zA-Z])'), '|');
    text = text.replaceAll(RegExp(r'\\(?:Vert|parallel)\{\s*\}'), '||');
    text = text.replaceAll(RegExp(r'\\(?:Vert|parallel)(?![a-zA-Z])'), '||');
    text = text.replaceAll(RegExp(r'\\mid\{\s*\}'), '|');
    text = text.replaceAll(RegExp(r'\\mid(?![a-zA-Z])'), '|');

    // Replace LaTeX backslashes \textbackslash{}, \backslash{} with \
    text = text.replaceAll(RegExp(r'\\(?:text)?backslash\{\s*\}'), r'\');
    text = text.replaceAll(RegExp(r'\\(?:text)?backslash(?![a-zA-Z])'), r'\');

    // Replace LaTeX tilde \sim{}, \sim with ~
    text = text.replaceAll(RegExp(r'\\sim\{\s*\}'), '~');
    text = text.replaceAll(RegExp(r'\\sim(?![a-zA-Z])'), '~');

    // 6. Clean broken backslash line continuation (e.g. `\` followed by trailing spaces before newline)
    // In bash/zsh, trailing space after `\` prevents line continuation and causes immediate syntax error
    text = text.replaceAll(RegExp(r'\\[ \t]+(?=\r\n|\r|\n)'), r'\');

    // 7. Strip rogue ASCII control characters that disrupt terminal editors (nano, vi)
    // Preserves: \t (0x09), \n (0x0A), \r (0x0D)
    // Strips: 0x00-0x08, 0x0B (VT), 0x0C (FF), 0x0E-0x1F (including ESC 0x1B), 0x7F (DEL)
    text = text.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');

    return text;
  }
}
