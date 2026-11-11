import 'package:flutter_test/flutter_test.dart';
import 'package:mjolnir/services/ssh_service.dart';

void main() {
  group('Terminal Context Actions - URL and File Detection', () {
    String cleanUrl(String raw) {
      var url = raw.trim();
      while (url.isNotEmpty &&
          (url.startsWith('(') || url.startsWith('<') || url.startsWith('['))) {
        url = url.substring(1);
      }
      while (url.isNotEmpty &&
          (url.endsWith('.') ||
              url.endsWith(',') ||
              url.endsWith(';') ||
              url.endsWith(')') ||
              url.endsWith(']') ||
              url.endsWith('>'))) {
        url = url.substring(0, url.length - 1);
      }
      return url;
    }

    String cleanFilePath(String raw) {
      var path = raw.trim();
      if ((path.startsWith('"') && path.endsWith('"')) ||
          (path.startsWith("'") && path.endsWith("'")) ||
          (path.startsWith('`') && path.endsWith('`'))) {
        path = path.substring(1, path.length - 1).trim();
      }
      while (path.isNotEmpty &&
          (path.endsWith(':') ||
              path.endsWith(',') ||
              urlEndsWith(path, ';') ||
              path.endsWith(')') ||
              path.endsWith(']'))) {
        path = path.substring(0, path.length - 1);
      }
      while (path.isNotEmpty && (path.startsWith('(') || path.startsWith('['))) {
        path = path.substring(1);
      }
      return path.trim();
    }

    bool isValidFilePathCandidate(String s, {bool isSelected = false}) {
      if (s.isEmpty || s.length > 1024) return false;
      if (s.startsWith('http://') || s.startsWith('https://')) return false;
      if (s.contains('\n') || s.contains('\r') || s.contains('\x00')) return false;
      if (s.startsWith('-')) return false;
      if (RegExp(r'^[-rwxstldcbp]{9,10}$').hasMatch(s)) return false;
      if (RegExp(r'^\d+$').hasMatch(s)) return false;
      if (s == '.' || s == '..' || s == '/' || s == '~') return false;

      if (isSelected) {
        return !s.contains(' ') && !s.contains('\t');
      }

      final hasExtension = RegExp(r'\.[a-zA-Z0-9_-]{1,16}$').hasMatch(s);
      final isPath = s.contains('/') || s.startsWith('~/');
      final isHiddenFile = s.startsWith('.') && s.length > 1;

      return hasExtension || isPath || isHiddenFile;
    }

    test('cleanUrl trims trailing punctuation properly', () {
      expect(cleanUrl('https://example.com/api.'), 'https://example.com/api');
      expect(cleanUrl('(https://google.com/search?q=flutter)'), 'https://google.com/search?q=flutter');
      expect(cleanUrl('http://192.168.1.1:8080/metrics;'), 'http://192.168.1.1:8080/metrics');
      expect(cleanUrl('<https://github.com/flutter/flutter>'), 'https://github.com/flutter/flutter');
    });

    test('URL regex accurately extracts URLs from terminal text lines', () {
      final line = 'See docs at https://flutter.dev/get-started and enjoy!';
      final regex = RegExp(r'''https?://[^\s<>"'\]\[\(\)]+''');
      final match = regex.firstMatch(line);
      expect(match, isNotNull);
      expect(match!.group(0), 'https://flutter.dev/get-started');
    });

    test('URL regex parses OAuth authentication URL containing nested URLs as parameters', () {
      final oauthUrl =
          'https://accounts.google.com/o/oauth2/auth?client_id=123.apps.googleusercontent.com&redirect_uri=http://localhost:8085/oauth2callback&response_type=code&scope=https://www.googleapis.com/auth/userinfo.email';
      final text = 'Please visit this URL to authorize Antigravity: $oauthUrl and continue.';
      final regex = RegExp(r'''https?://[^\s<>"'\]\[\(\)]+''');
      final matches = regex.allMatches(text).toList();
      expect(matches.length, 1);
      expect(matches.first.group(0), oauthUrl);
    });

    test('Reconstructs wrapped terminal lines correctly across multiple rows', () {
      // Simulate lines in terminal buffer where continuation rows have isWrapped = true
      final rows = [
        (text: 'https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=123456789', isWrapped: false),
        (text: '012.apps.googleusercontent.com&redirect_uri=http://localhost:8085/oauth2callback', isWrapped: true),
        (text: '&scope=https://www.googleapis.com/auth/cloud-platform', isWrapped: true),
        (text: 'Next non-wrapped line', isWrapped: false),
      ];

      for (var clickedY = 0; clickedY <= 2; clickedY++) {
        var startLineIdx = clickedY;
        while (startLineIdx > 0 && rows[startLineIdx].isWrapped) {
          startLineIdx--;
        }
        var endLineIdx = clickedY;
        while (endLineIdx < rows.length - 1 && rows[endLineIdx + 1].isWrapped) {
          endLineIdx++;
        }

        expect(startLineIdx, 0, reason: 'Failed start line for click on row $clickedY');
        expect(endLineIdx, 2, reason: 'Failed end line for click on row $clickedY');

        final buffer = StringBuffer();
        for (var lIdx = startLineIdx; lIdx <= endLineIdx; lIdx++) {
          buffer.write(rows[lIdx].text);
        }
        final fullText = buffer.toString();
        final regex = RegExp(r'''https?://[^\s<>"'\]\[\(\)]+''');
        final matches = regex.allMatches(fullText).toList();
        expect(matches.length, 1);
        expect(
          matches.first.group(0),
          'https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=123456789012.apps.googleusercontent.com&redirect_uri=http://localhost:8085/oauth2callback&scope=https://www.googleapis.com/auth/cloud-platform',
        );
      }
    });

    test('cleanFilePath removes quotes, surrounding brackets, and trailing colons', () {
      expect(cleanFilePath('"server.log"'), 'server.log');
      expect(cleanFilePath("'config.yaml'"), 'config.yaml');
      expect(cleanFilePath('`main.dart`'), 'main.dart');
      expect(cleanFilePath('/var/log/syslog:'), '/var/log/syslog');
      expect(cleanFilePath('(/etc/nginx/nginx.conf)'), '/etc/nginx/nginx.conf');
    });

    test('isValidFilePathCandidate identifies valid files and filters out non-files', () {
      // Valid file candidates
      expect(isValidFilePathCandidate('index.html'), isTrue);
      expect(isValidFilePathCandidate('/etc/hosts'), isTrue);
      expect(isValidFilePathCandidate('~/data/export.csv'), isTrue);
      expect(isValidFilePathCandidate('.bashrc'), isTrue);
      expect(isValidFilePathCandidate('app.tar.gz'), isTrue);
      expect(isValidFilePathCandidate('src/main.dart'), isTrue);

      // Invalid candidates (should NOT trigger file download)
      expect(isValidFilePathCandidate('https://example.com/file.txt'), isFalse);
      expect(isValidFilePathCandidate('-lah'), isFalse);
      expect(isValidFilePathCandidate('--verbose'), isFalse);
      expect(isValidFilePathCandidate('-rw-r--r--'), isFalse);
      expect(isValidFilePathCandidate('drwxr-xr-x'), isFalse);
      expect(isValidFilePathCandidate('4096'), isFalse);
      expect(isValidFilePathCandidate('.'), isFalse);
      expect(isValidFilePathCandidate('..'), isFalse);
      expect(isValidFilePathCandidate('/'), isFalse);
      expect(isValidFilePathCandidate('~'), isFalse);
    });

    test('Selected text allows file names without extension', () {
      expect(isValidFilePathCandidate('README', isSelected: true), isTrue);
      expect(isValidFilePathCandidate('LICENSE', isSelected: true), isTrue);
      expect(isValidFilePathCandidate('Dockerfile', isSelected: true), isTrue);
      expect(isValidFilePathCandidate('random command with spaces', isSelected: true), isFalse);
    });

    test('SFTP remote path resolution handles tilde, relative, and absolute paths', () {
      expect(
        SshService.resolveRemotePath('config.yaml', homePath: '/home/ubuntu'),
        '/home/ubuntu/config.yaml',
      );
      expect(
        SshService.resolveRemotePath('/var/log/syslog', homePath: '/root'),
        '/var/log/syslog',
      );
      expect(
        SshService.resolveRemotePath('~/test.txt', homePath: '/home/deploy'),
        '/home/deploy/test.txt',
      );
    });

    test('OSC 7 URI parsing correctly parses directory path', () {
      final osc7Payload = 'file://my-server.local/home/user/projects/mjolnir';
      final uri = Uri.tryParse(osc7Payload);
      expect(uri, isNotNull);
      expect(Uri.decodeComponent(uri!.path), '/home/user/projects/mjolnir');
    });

    test('Normalizes standalone line feed to carriage return + line feed (ONLCR)', () {
      String normalizeNewlines(String input, {bool lastChunkEndedWithCR = false}) {
        if (!input.contains('\n')) return input;
        final buffer = StringBuffer();
        for (var i = 0; i < input.length; i++) {
          final char = input[i];
          if (char == '\n') {
            final isPrecededByCR = i > 0
                ? input.codeUnitAt(i - 1) == 0x0D
                : lastChunkEndedWithCR;
            if (!isPrecededByCR) {
              buffer.write('\r');
            }
          }
          buffer.write(char);
        }
        return buffer.toString();
      }

      // Standalone LF becomes CRLF
      expect(normalizeNewlines("line1\nline2"), "line1\r\nline2");
      // Existing CRLF remains unchanged
      expect(normalizeNewlines("line1\r\nline2"), "line1\r\nline2");
      // Multi-line mixed CRLF and LF
      expect(normalizeNewlines("line1\nline2\r\nline3\n"), "line1\r\nline2\r\nline3\r\n");
      // Cross-chunk boundary with CR at end of first chunk
      expect(normalizeNewlines("\nsecond chunk", lastChunkEndedWithCR: true), "\nsecond chunk");
      expect(normalizeNewlines("\nsecond chunk", lastChunkEndedWithCR: false), "\r\nsecond chunk");
    });
  });
}

bool urlEndsWith(String str, String char) => str.endsWith(char);
