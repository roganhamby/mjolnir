import 'package:flutter_test/flutter_test.dart';
import 'package:mjolnir/services/terminal_clipboard_sanitizer.dart';

void main() {
  group('TerminalClipboardSanitizer Tests', () {
    test('Empty or null-safe input returns unchanged', () {
      expect(TerminalClipboardSanitizer.sanitize(''), '');
    });

    test('Clean text with ordinary pipes and slashes is unaltered', () {
      const input = 'cat /var/log/syslog | grep "error" | awk \'{print \$1}\'';
      expect(TerminalClipboardSanitizer.sanitize(input), input);
    });

    test('Converts Gemini KaTeX pipe delimiters (\\vert{}, \\vert{, \\vert, \\lvert, \\rvert, \\mid)', () {
      // \vert{}
      expect(
        TerminalClipboardSanitizer.sanitize('cat file.txt \\vert{} grep "foo"'),
        'cat file.txt | grep "foo"',
      );
      // \vert{
      expect(
        TerminalClipboardSanitizer.sanitize('cat file.txt \\vert{ grep "foo"'),
        'cat file.txt | grep "foo"',
      );
      // \vert followed by space
      expect(
        TerminalClipboardSanitizer.sanitize('cat file.txt \\vert grep "foo"'),
        'cat file.txt | grep "foo"',
      );
      // \lvert and \rvert
      expect(
        TerminalClipboardSanitizer.sanitize('cmd1 \\lvert cmd2 \\rvert cmd3'),
        'cmd1 | cmd2 | cmd3',
      );
      // \mid
      expect(
        TerminalClipboardSanitizer.sanitize('cat file \\mid grep bar'),
        'cat file | grep bar',
      );
      // Double pipe (\Vert, \parallel)
      expect(
        TerminalClipboardSanitizer.sanitize('true \\Vert false'),
        'true || false',
      );
      expect(
        TerminalClipboardSanitizer.sanitize('cmd1 \\parallel cmd2'),
        'cmd1 || cmd2',
      );
    });

    test('Does not corrupt normal words starting with vert or mid', () {
      const input = 'convert file.png vertical.png midpoint.txt';
      expect(TerminalClipboardSanitizer.sanitize(input), input);
    });

    test('Converts LaTeX backslashes (\\textbackslash, \\backslash)', () {
      expect(
        TerminalClipboardSanitizer.sanitize(r'find . -name "*.dart" \textbackslash{} -print'),
        r'find . -name "*.dart" \ -print',
      );
      expect(
        TerminalClipboardSanitizer.sanitize(r'find . \backslash -name "*.log"'),
        r'find . \ -name "*.log"',
      );
    });

    test('Converts LaTeX tilde (\\sim)', () {
      expect(
        TerminalClipboardSanitizer.sanitize(r'cd \sim/project'),
        'cd ~/project',
      );
      expect(
        TerminalClipboardSanitizer.sanitize(r'cp file \sim{}'),
        'cp file ~',
      );
    });

    test('Decodes common HTML entities', () {
      expect(
        TerminalClipboardSanitizer.sanitize('echo &quot;hello&quot; &amp;&amp; cat a &gt; b &lt; c &vert; wc -l'),
        'echo "hello" && cat a > b < c | wc -l',
      );
      expect(
        TerminalClipboardSanitizer.sanitize('cat file &#124; grep test'),
        'cat file | grep test',
      );
      expect(
        TerminalClipboardSanitizer.sanitize('echo &#39;test&#39; &apos;again&apos; &nbsp; foo&#160;bar'),
        "echo 'test' 'again'   foo bar",
      );
    });

    test('Normalizes smart quotes and typographical dashes/minus', () {
      // Smart quotes
      expect(
        TerminalClipboardSanitizer.sanitize('echo “hello” and ‘world’ and „test‟'),
        'echo "hello" and \'world\' and "test"',
      );
      // Em dash converting -- CLI flags
      expect(
        TerminalClipboardSanitizer.sanitize('git commit —m “initial” —verbose'),
        'git commit --m "initial" --verbose',
      );
      // En dash and minus sign
      expect(
        TerminalClipboardSanitizer.sanitize('chmod –R 755 /var/www −v'),
        'chmod -R 755 /var/www -v',
      );
    });

    test('Normalizes unicode whitespace and removes invisible zero-width characters', () {
      // Non-breaking spaces (\u00A0) and narrow no-break space (\u202F)
      expect(
        TerminalClipboardSanitizer.sanitize("echo\u00A0foo\u202Fbar\u2000baz"),
        'echo foo bar baz',
      );
      // Zero width spaces (\u200B, \uFEFF, \u200C, etc.)
      expect(
        TerminalClipboardSanitizer.sanitize("ec\u200Bho \uFEFF'clean\u2060'"),
        "echo 'clean'",
      );
    });

    test('Fixes broken line continuation with trailing spaces after backslash', () {
      // Trailing spaces after backslash before \n
      const brokenLf = "docker run \\\n  -d \\\n  nginx\n";
      const brokenWithSpaces = "docker run \\   \n  -d \\\t \n  nginx\n";
      expect(TerminalClipboardSanitizer.sanitize(brokenWithSpaces), brokenLf);

      // Trailing spaces before CRLF
      const brokenCrlf = "docker run \\   \r\n  -d nginx\r\n";
      expect(TerminalClipboardSanitizer.sanitize(brokenCrlf), "docker run \\\r\n  -d nginx\r\n");
    });

    test('Strips rogue ASCII control characters but preserves \\t, \\n, \\r', () {
      // Stray ESC (0x1b), NUL (0x00), BEL (0x07), DEL (0x7F)
      final input = "echo 'hello'\x1b:q!\x07\x00\x7F\t\r\n";
      final expected = "echo 'hello':q!\t\r\n";
      expect(TerminalClipboardSanitizer.sanitize(input), expected);
    });
  });
}
