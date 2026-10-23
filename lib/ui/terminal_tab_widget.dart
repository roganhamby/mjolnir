import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xterm/xterm.dart';
import '../models/server_config.dart';
import '../models/task_item.dart';
import '../services/ssh_service.dart';
import '../theme/ansi_themes.dart';
import '../theme/app_color_schemes.dart';
import 'task_manager_tab_widget.dart';

class TerminalTabWidget extends StatefulWidget {
  final ServerConfig server;
  final SshService sshService;
  final TerminalTheme theme;
  final String? initialThemeName;
  final double fontSize;
  final bool isActive;
  final TaskItem? assignedTask;
  final VoidCallback? onCompleteAssignedTask;
  final VoidCallback? onUnassignTask;
  final VoidCallback? onClose;
  final Function(double newFontSize)? onFontSizeChanged;
  final Function(String newThemeName)? onThemeChanged;

  const TerminalTabWidget({
    super.key,
    required this.server,
    required this.sshService,
    this.theme = TerminalThemes.defaultTheme,
    this.initialThemeName,
    this.fontSize = 13.0,
    this.isActive = true,
    this.assignedTask,
    this.onCompleteAssignedTask,
    this.onUnassignTask,
    this.onClose,
    this.onFontSizeChanged,
    this.onThemeChanged,
  });

  @override
  State<TerminalTabWidget> createState() => _TerminalTabWidgetState();
}

class _TerminalTabWidgetState extends State<TerminalTabWidget>
    with WidgetsBindingObserver {
  late final Terminal terminal;
  late final TerminalController _terminalController;
  late final ScrollController _scrollController;
  late final FocusNode _terminalFocusNode;
  SshSession? _sshSession;
  bool _isLoading = true;
  String? _errorMessage;
  bool _isExited = false;
  late double _fontSize;
  late String _currentThemeName;
  late TerminalTheme _currentTheme;
  int _lastCellWidth = 0;
  int _lastCellHeight = 0;
  bool _consumedCopyOnCtrlCDown = false;

  // Screen logging state
  bool _isScreenLogging = false;
  String? _screenLogPath;
  IOSink? _screenLogSink;
  int _screenLogBytesWritten = 0;
  bool _ctrlModifierActive = false;
  final RegExp _ansiRegex = RegExp(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])');

  static TerminalTargetPlatform _getTerminalPlatform() {
    if (Platform.isWindows) return TerminalTargetPlatform.windows;
    if (Platform.isMacOS) return TerminalTargetPlatform.macos;
    if (Platform.isLinux) return TerminalTargetPlatform.linux;
    if (Platform.isAndroid) return TerminalTargetPlatform.android;
    if (Platform.isIOS) return TerminalTargetPlatform.ios;
    return TerminalTargetPlatform.unknown;
  }

  void _requestTerminalFocus() {
    if (!mounted || !widget.isActive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isActive && !_terminalFocusNode.hasFocus) {
        _terminalFocusNode.requestFocus();
      }
    });
  }

  void _syncRemotePtySize({
    int? width,
    int? height,
    int? cellWidth,
    int? cellHeight,
  }) {
    final session = _sshSession?.session;
    if (session == null) return;
    final w = width ?? terminal.viewWidth;
    final h = height ?? terminal.viewHeight;
    if (w <= 0 || h <= 0) return;
    final cw = cellWidth ?? _lastCellWidth;
    final ch = cellHeight ?? _lastCellHeight;
    try {
      session.resizeTerminal(
        w,
        h,
        cw > 0 ? w * cw : 0,
        ch > 0 ? h * ch : 0,
      );
    } catch (_) {}
  }

  void _handleTerminalResize(
    int width,
    int height,
    int cellWidth,
    int cellHeight,
  ) {
    _lastCellWidth = cellWidth;
    _lastCellHeight = cellHeight;

    // Track the cursor line across xterm's Buffer.resize + reflow so that
    // unwrapping/wrapping lines when going full screen keeps cursorY aligned
    // with the actual prompt line and resets full-height vertical margins.
    CellAnchor? cursorAnchor;
    if (!terminal.isUsingAltBuffer && terminal.mainBuffer.lines.length > 0) {
      final absY = terminal.mainBuffer.absoluteCursorY.clamp(
        0,
        terminal.mainBuffer.lines.length - 1,
      );
      final curX = terminal.mainBuffer.cursorX.clamp(
        0,
        terminal.viewWidth > 0 ? terminal.viewWidth - 1 : 0,
      );
      cursorAnchor = terminal.mainBuffer.createAnchor(curX, absY);
    }

    _syncRemotePtySize(
      width: width,
      height: height,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
    );

    scheduleMicrotask(() {
      if (cursorAnchor != null) {
        if (cursorAnchor.attached && !terminal.isUsingAltBuffer) {
          final mainBuf = terminal.mainBuffer;
          var changed = false;
          // Trim excess trailing empty lines pushed past viewHeight by reflow
          while (mainBuf.lines.length > terminal.viewHeight &&
              mainBuf.lines.length - 1 > cursorAnchor.y &&
              mainBuf.lines[mainBuf.lines.length - 1].getTrimmedLength() == 0) {
            mainBuf.lines.pop();
            changed = true;
          }
          final targetCursorY = (cursorAnchor.y - mainBuf.scrollBack).clamp(
            0,
            terminal.viewHeight > 0 ? terminal.viewHeight - 1 : 0,
          );
          final targetCursorX = cursorAnchor.x.clamp(
            0,
            terminal.viewWidth > 0 ? terminal.viewWidth - 1 : 0,
          );
          if (mainBuf.cursorX != targetCursorX ||
              mainBuf.cursorY != targetCursorY) {
            mainBuf.setCursor(targetCursorX, targetCursorY);
            changed = true;
          }
          mainBuf.resetVerticalMargins();
          if (changed && mounted) {
            terminal.notifyListeners();
          }
        }
        cursorAnchor.dispose();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fontSize = widget.fontSize;
    terminal = Terminal(
      maxLines: 10000,
      platform: _getTerminalPlatform(),
      onResize: _handleTerminalResize,
      onPrivateOSC: _handlePrivateOSC,
    );
    // Disable sending mouse tap events to the remote application so that
    // mouse drag selection and right-click context menu (Copy / Paste) work
    // reliably even when vim enables mouse mode (set mouse=a).
    _terminalController = TerminalController(
      pointerInputs: const PointerInputs.none(),
    );
    _scrollController = ScrollController();
    _terminalFocusNode = FocusNode();
    _currentThemeName = widget.server.terminalTheme.isNotEmpty
        ? widget.server.terminalTheme
        : (widget.initialThemeName ?? 'Default Dark');
    _currentTheme = AnsiThemes.all[_currentThemeName] ?? widget.theme;
    _requestTerminalFocus();
    _connect();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!terminal.isUsingAltBuffer) {
        terminal.mainBuffer.resetVerticalMargins();
      }
      _syncRemotePtySize();
    });
  }

  @override
  void didUpdateWidget(TerminalTabWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) {
      _requestTerminalFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _syncRemotePtySize();
        }
      });
    }
    if (oldWidget.fontSize != widget.fontSize) {
      _fontSize = widget.fontSize;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _syncRemotePtySize();
        }
      });
    }
    if (oldWidget.server.terminalTheme != widget.server.terminalTheme &&
        widget.server.terminalTheme.isNotEmpty) {
      _currentThemeName = widget.server.terminalTheme;
      _currentTheme = AnsiThemes.all[_currentThemeName] ?? TerminalThemes.defaultTheme;
    }
  }

  void _changeTheme(String newThemeName) {
    setState(() {
      _currentThemeName = newThemeName;
      _currentTheme = AnsiThemes.all[newThemeName] ?? TerminalThemes.defaultTheme;
    });
    widget.server.terminalTheme = newThemeName;
    widget.onThemeChanged?.call(newThemeName);
    _requestTerminalFocus();
  }

  void _increaseFontSize() {
    if (_fontSize < 32) {
      setState(() {
        _fontSize += 1.0;
      });
      widget.onFontSizeChanged?.call(_fontSize);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncRemotePtySize();
      });
    }
    _requestTerminalFocus();
  }

  void _decreaseFontSize() {
    if (_fontSize > 8) {
      setState(() {
        _fontSize -= 1.0;
      });
      widget.onFontSizeChanged?.call(_fontSize);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncRemotePtySize();
      });
    }
    _requestTerminalFocus();
  }

  void _resetFontSize() {
    setState(() {
      _fontSize = 13.0;
    });
    widget.onFontSizeChanged?.call(_fontSize);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncRemotePtySize();
    });
    _requestTerminalFocus();
  }

  // --- Copy & Paste Support ---

  void _handlePrivateOSC(String code, List<String> args) {
    // Support OSC 52 clipboard integration (\x1b]52;c;<base64>\x07) used by
    // vim / neovim / tmux to copy yanked text to the local system clipboard.
    if (code == '52' && args.length >= 2) {
      final payload = args[1];
      if (payload.isNotEmpty && payload != '?') {
        try {
          final cleaned = payload.replaceAll(RegExp(r'\s+'), '');
          final decoded = utf8.decode(base64.decode(cleaned), allowMalformed: true);
          if (decoded.isNotEmpty) {
            Clipboard.setData(ClipboardData(text: decoded));
          }
        } catch (_) {}
      }
    }
  }

  String _extractSelectedText(BufferRange selection) {
    final range = selection.normalized;
    final builder = StringBuffer();
    final buffer = terminal.buffer;
    final segments = range.toSegments().toList();

    for (var sIdx = 0; sIdx < segments.length; sIdx++) {
      final segment = segments[sIdx];
      if (segment.line < 0 || segment.line >= buffer.height) {
        continue;
      }
      final line = buffer.lines[segment.line];
      if (!(segment.line == range.begin.y ||
          segment.line == 0 ||
          line.isWrapped)) {
        builder.write('\n');
      }

      final from = (segment.start ?? 0).clamp(0, line.length);
      final trimmedEnd = line.getTrimmedLength(line.length);
      var nonSpaceEnd = trimmedEnd;
      if (!line.isWrapped) {
        while (nonSpaceEnd > 0) {
          final cp = line.getCodePoint(nonSpaceEnd - 1);
          if (cp != 0 && cp != 0x20) {
            final w = line.getWidth(nonSpaceEnd - 1);
            if (w > 1) {
              nonSpaceEnd = (nonSpaceEnd - 1 + w).clamp(0, line.length);
            }
            break;
          }
          nonSpaceEnd--;
        }
      }

      final maxEnd = segment.end != null
          ? segment.end!.clamp(0, line.length)
          : line.length;
      final effectiveEnd = maxEnd < nonSpaceEnd ? maxEnd : nonSpaceEnd;

      for (var i = from; i < effectiveEnd; i++) {
        final codePoint = line.getCodePoint(i);
        final width = line.getWidth(i);
        if (codePoint == 0) {
          if (i > 0 && line.getWidth(i - 1) == 2) {
            continue;
          }
          builder.write(' ');
        } else if (i + width <= maxEnd) {
          builder.writeCharCode(codePoint);
        }
      }
    }

    return builder.toString();
  }

  Future<void> _copySelection({bool showNotification = true}) async {
    final selection = _terminalController.selection;
    if (selection == null) {
      if (showNotification && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No text selected in terminal'),
            duration: Duration(seconds: 1),
          ),
        );
      }
      _requestTerminalFocus();
      return;
    }

    final text = _extractSelectedText(selection);
    if (text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      if (showNotification && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Copied ${text.length} characters to clipboard'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    }
    _requestTerminalFocus();
  }

  Future<void> _pasteToTerminal() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      // Normalize Windows CRLF (\r\n) and LF (\n) to CR (\r) so vim and remote
      // PTYs do not insert double newlines or literal ^M characters.
      final normalized = text.replaceAll('\r\n', '\r').replaceAll('\n', '\r');
      terminal.paste(normalized);
      _terminalController.clearSelection();
    }
    _requestTerminalFocus();
  }

  void _selectAll() {
    _terminalController.setSelection(
      terminal.buffer.createAnchor(0, 0),
      terminal.buffer.createAnchor(terminal.viewWidth, terminal.buffer.height - 1),
    );
    _requestTerminalFocus();
  }

  void _clearScreen() {
    terminal.eraseDisplay();
    _terminalController.clearSelection();
    _requestTerminalFocus();
  }

  Future<void> _showContextMenu(Offset position) async {
    final hasSelection = _terminalController.selection != null;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      color: const Color(0xFF2D2D2D),
      items: [
        PopupMenuItem<String>(
          value: 'copy',
          enabled: hasSelection,
          height: 36,
          child: Row(
            children: [
              Icon(Icons.copy, size: 16, color: hasSelection ? Colors.white : Colors.grey),
              const SizedBox(width: 8),
              Text(
                'Copy',
                style: TextStyle(
                  fontSize: 13,
                  color: hasSelection ? Colors.white : Colors.grey,
                ),
              ),
              const Spacer(),
              Text(
                Platform.isMacOS ? '⌘C' : 'Ctrl+Shift+C',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'paste',
          height: 36,
          child: Row(
            children: [
              const Icon(Icons.paste, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              const Text('Paste', style: TextStyle(fontSize: 13, color: Colors.white)),
              const Spacer(),
              Text(
                Platform.isMacOS ? '⌘V' : 'Ctrl+V',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(height: 8),
        PopupMenuItem<String>(
          value: 'selectAll',
          height: 36,
          child: Row(
            children: [
              const Icon(Icons.select_all, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              const Text('Select All', style: TextStyle(fontSize: 13, color: Colors.white)),
              const Spacer(),
              Text(
                Platform.isMacOS ? '⌘A' : 'Ctrl+Shift+A',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'clear',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.clear_all, size: 16, color: Colors.white),
              SizedBox(width: 8),
              Text('Clear Screen', style: TextStyle(fontSize: 13, color: Colors.white)),
            ],
          ),
        ),
      ],
    );

    if (selected == 'copy') {
      _copySelection();
    } else if (selected == 'paste') {
      _pasteToTerminal();
    } else if (selected == 'selectAll') {
      _selectAll();
    } else if (selected == 'clear') {
      _clearScreen();
    } else {
      _requestTerminalFocus();
    }
  }

  KeyEventResult _handleTerminalKeyEvent(FocusNode focusNode, KeyEvent event) {
    if (event is KeyUpEvent) {
      if (event.logicalKey == LogicalKeyboardKey.keyC) {
        _consumedCopyOnCtrlCDown = false;
      }
      return KeyEventResult.ignored;
    }

    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final isMeta = HardwareKeyboard.instance.isMetaPressed;
      final isCtrl = HardwareKeyboard.instance.isControlPressed;
      final isShift = HardwareKeyboard.instance.isShiftPressed;

      // Copy: Cmd+C (macOS) or Ctrl+Shift+C or (Ctrl+C if text is selected)
      if ((isMeta && event.logicalKey == LogicalKeyboardKey.keyC) ||
          (isCtrl && isShift && event.logicalKey == LogicalKeyboardKey.keyC)) {
        if (event is KeyDownEvent) {
          _copySelection();
          _terminalController.clearSelection();
        }
        return KeyEventResult.handled;
      }

      if (isCtrl && !isShift && event.logicalKey == LogicalKeyboardKey.keyC) {
        if (event is KeyDownEvent && _terminalController.selection != null) {
          _consumedCopyOnCtrlCDown = true;
          _copySelection();
          _terminalController.clearSelection();
          return KeyEventResult.handled;
        }
        if (event is KeyRepeatEvent && _consumedCopyOnCtrlCDown) {
          return KeyEventResult.handled;
        }
      }

      // Paste: Cmd+V (macOS) or Ctrl+Shift+V or Ctrl+V
      if ((isMeta && event.logicalKey == LogicalKeyboardKey.keyV) ||
          (isCtrl && isShift && event.logicalKey == LogicalKeyboardKey.keyV) ||
          (isCtrl && event.logicalKey == LogicalKeyboardKey.keyV)) {
        if (event is KeyDownEvent) {
          _pasteToTerminal();
        }
        return KeyEventResult.handled;
      }

      // Select All: Cmd+A (macOS) or Ctrl+Shift+A (Windows/Linux)
      if ((isMeta && event.logicalKey == LogicalKeyboardKey.keyA) ||
          (isCtrl && isShift && event.logicalKey == LogicalKeyboardKey.keyA)) {
        if (event is KeyDownEvent) {
          _selectAll();
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  // --- Screen Logging Support ---

  void _logStreamData(String rawText) {
    if (!_isScreenLogging || _screenLogSink == null) return;
    try {
      final cleanText = rawText.replaceAll(_ansiRegex, '');
      if (cleanText.isNotEmpty) {
        _screenLogSink!.write(cleanText);
        _screenLogBytesWritten += cleanText.length;
      }
    } catch (_) {}
  }

  Future<void> _startScreenLogging() async {
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final safeServerName = widget.server.name.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final fileName = 'mjolnir_${safeServerName}_$timestamp.log';

    final header = '''
================================================================================
Mjölnir SSH Screen Log
Server: ${widget.server.name} (${widget.server.username}@${widget.server.host}:${widget.server.port})
Started: ${DateTime.now().toLocal().toString()}
================================================================================
''';

    String selectedPath;
    final isMobile = Platform.isAndroid || Platform.isIOS;

    if (isMobile) {
      // On Android/iOS, FilePicker.saveFile returns a one-shot SAF content:// URI that cannot
      // be opened with File(...).openWrite(mode: FileMode.append). Stream to app documents first,
      // then offer to export when logging stops.
      final docDir = await getApplicationDocumentsDirectory();
      final logDir = Directory(p.join(docDir.path, 'Mjolnir', 'logs'));
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      selectedPath = p.join(logDir.path, fileName);
      await File(selectedPath).writeAsString(header, flush: true);
    } else {
      final savedUri = await FilePicker.saveFile(
        dialogTitle: 'Save Screen Log As',
        fileName: fileName,
        bytes: Uint8List.fromList(utf8.encode(header)),
      );

      if (savedUri == null || !mounted) return;
      selectedPath = savedUri.toFilePath();
    }

    try {
      final file = File(selectedPath);
      final sink = file.openWrite(mode: FileMode.append);

      // Dump current screen buffer lines if available
      final lineCount = terminal.buffer.lines.length;
      if (lineCount > 0) {
        sink.write('--- Screen Buffer Prior to Logging ---\n');
        for (var i = 0; i < lineCount; i++) {
          final line = terminal.buffer.lines[i];
          final lineStr = line.toString().trimRight();
          if (lineStr.isNotEmpty) {
            sink.write('$lineStr\n');
          }
        }
        sink.write('--- Live Screen Stream Begins ---\n\n');
      }
      await sink.flush();

      setState(() {
        _isScreenLogging = true;
        _screenLogPath = selectedPath;
        _screenLogSink = sink;
        _screenLogBytesWritten = 0;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Screen logging started: ${p.basename(selectedPath)}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start screen logging: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _stopScreenLogging() async {
    if (!_isScreenLogging) return;
    final path = _screenLogPath;
    try {
      final footer = '''

================================================================================
Screen Logging Ended: ${DateTime.now().toLocal().toString()}
Total Characters Logged: $_screenLogBytesWritten
================================================================================
''';
      _screenLogSink?.write(footer);
      await _screenLogSink?.flush();
      await _screenLogSink?.close();
    } catch (_) {}

    setState(() {
      _isScreenLogging = false;
      _screenLogSink = null;
    });

    if (mounted && path != null) {
      final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Screen log saved (${(_screenLogBytesWritten / 1024).toStringAsFixed(1)} KB): ${p.basename(path)}'),
          action: isDesktop
              ? SnackBarAction(
                  label: Platform.isMacOS ? 'Show in Finder' : 'Open Folder',
                  onPressed: () {
                    if (Platform.isMacOS) {
                      Process.run('open', ['-R', path]);
                    } else if (Platform.isWindows) {
                      Process.run('explorer.exe', ['/select,$path']);
                    } else if (Platform.isLinux) {
                      Process.run('xdg-open', [File(path).parent.path]);
                    }
                  },
                )
              : SnackBarAction(
                  label: 'Export Log',
                  onPressed: () async {
                    try {
                      final bytes = await File(path).readAsBytes();
                      await FilePicker.saveFile(
                        dialogTitle: 'Save Screen Log As',
                        fileName: p.basename(path),
                        bytes: bytes,
                      );
                    } catch (_) {}
                  },
                ),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  // --- SSH Connection Handling ---

  Future<void> _connect() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isExited = false;
    });

    final connectMsg = 'Connecting to ${widget.server.username}@${widget.server.host}:${widget.server.port}...\r\n';
    terminal.write(connectMsg);
    _logStreamData(connectMsg);

    try {
      // Allow the first layout pass to complete so TerminalView has measured
      // the actual window / full-screen dimensions before requesting the PTY.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      final session = await widget.sshService.startShellSession(
        widget.server,
        terminalWidth: terminal.viewWidth > 0 ? terminal.viewWidth : 80,
        terminalHeight: terminal.viewHeight > 0 ? terminal.viewHeight : 24,
        terminalPixelWidth: _lastCellWidth > 0 ? terminal.viewWidth * _lastCellWidth : 0,
        terminalPixelHeight: _lastCellHeight > 0 ? terminal.viewHeight * _lastCellHeight : 0,
        getTerminalWidth: () => terminal.viewWidth,
        getTerminalHeight: () => terminal.viewHeight,
        getTerminalPixelWidth: () =>
            _lastCellWidth > 0 ? terminal.viewWidth * _lastCellWidth : 0,
        getTerminalPixelHeight: () =>
            _lastCellHeight > 0 ? terminal.viewHeight * _lastCellHeight : 0,
      );

      if (!mounted) {
        session.close();
        return;
      }

      _sshSession = session;

      // Ensure remote PTY and local scroll margins match the current viewport
      // immediately (in case the window was resized/maximized while connecting).
      if (!terminal.isUsingAltBuffer) {
        terminal.mainBuffer.resetVerticalMargins();
      }
      _syncRemotePtySize();

      // Pipe SSH stdout to terminal & screen log
      session.session.stdout.listen(
        (data) {
          final text = utf8.decode(data, allowMalformed: true);
          terminal.write(text);
          _logStreamData(text);
        },
        onError: (err) {
          final errStr = '\r\n[SSH stdout error: $err]\r\n';
          terminal.write(errStr);
          _logStreamData(errStr);
        },
        onDone: () {
          final doneStr = '\r\n[Session closed]\r\n';
          terminal.write(doneStr);
          _logStreamData(doneStr);
          _handleSessionDone();
        },
      );

      // Pipe SSH stderr to terminal & screen log
      session.session.stderr.listen((data) {
        final text = utf8.decode(data, allowMalformed: true);
        terminal.write(text);
        _logStreamData(text);
      });

      // Terminal user input to SSH stdin
      terminal.onOutput = (data) {
        if (data == '\x1b[>0;0;0c') {
          // Report modern xterm patch level (279) for Secondary Device
          // Attributes (DA2) so vim enables bracketed paste (\x1b[?2004h)
          //instead of treating the terminal as version 0.
          session.session.stdin.add(utf8.encode('\x1b[>0;279;0c'));
          return;
        }
        if (_ctrlModifierActive && data.isNotEmpty) {
          final code = data.toLowerCase().codeUnitAt(0);
          setState(() => _ctrlModifierActive = false);
          if (code >= 97 && code <= 122) {
            // Convert 'a'..'z' to Ctrl+A..Ctrl+Z (1..26)
            session.session.stdin.add(Uint8List.fromList([code - 96]));
            if (data.length > 1) {
              session.session.stdin.add(utf8.encode(data.substring(1)));
            }
            return;
          }
        }
        session.session.stdin.add(utf8.encode(data));
      };

      // Handle terminal resize events
      terminal.onResize = _handleTerminalResize;

      setState(() {
        _isLoading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          if (!terminal.isUsingAltBuffer) {
            terminal.mainBuffer.resetVerticalMargins();
          }
          _syncRemotePtySize();
        }
      });
      _requestTerminalFocus();
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
      final failMsg = '\r\n[Connection Failed: $e]\r\n';
      terminal.write(failMsg);
      _logStreamData(failMsg);
    }
  }

  void _handleSessionDone() {
    if (_isExited) return;
    _isExited = true;
    _stopScreenLogging();
    if (mounted && widget.onClose != null) {
      widget.onClose!();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sshSession?.close();
    _stopScreenLogging();
    _terminalController.dispose();
    _scrollController.dispose();
    _terminalFocusNode.dispose();
    super.dispose();
  }

  void _sendRawToShell(List<int> bytes) {
    final session = _sshSession?.session;
    if (session != null) {
      session.stdin.add(Uint8List.fromList(bytes));
    }
    _requestTerminalFocus();
  }

  Widget _buildMobileAccessoryBar(AppColorScheme scheme) {
    Widget keyButton(
      String label, {
      required VoidCallback onTap,
      bool highlighted = false,
      IconData? icon,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Material(
          color: highlighted ? scheme.accentColor : scheme.elevatedSurface,
          borderRadius: BorderRadius.circular(5),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(5),
            child: Container(
              constraints: const BoxConstraints(minWidth: 38, minHeight: 32),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              alignment: Alignment.center,
              child: icon != null
                  ? Icon(
                      icon,
                      size: 16,
                      color: highlighted ? Colors.black : scheme.primaryText,
                    )
                  : Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: highlighted ? Colors.black : scheme.primaryText,
                      ),
                    ),
            ),
          ),
        ),
      );
    }

    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.panelBackground,
        border: Border(top: BorderSide(color: scheme.borderColor)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            keyButton(
              'ESC',
              onTap: () => _sendRawToShell([0x1B]),
            ),
            keyButton(
              'TAB',
              onTap: () => _sendRawToShell([0x09]),
            ),
            keyButton(
              'CTRL',
              highlighted: _ctrlModifierActive,
              onTap: () => setState(() => _ctrlModifierActive = !_ctrlModifierActive),
            ),
            keyButton(
              'CTRL+C',
              onTap: () => _sendRawToShell([0x03]),
            ),
            keyButton(
              '↑',
              onTap: () => terminal.keyInput(TerminalKey.arrowUp),
            ),
            keyButton(
              '↓',
              onTap: () => terminal.keyInput(TerminalKey.arrowDown),
            ),
            keyButton(
              '←',
              onTap: () => terminal.keyInput(TerminalKey.arrowLeft),
            ),
            keyButton(
              '→',
              onTap: () => terminal.keyInput(TerminalKey.arrowRight),
            ),
            keyButton(
              '-',
              onTap: () => _sendRawToShell(utf8.encode('-')),
            ),
            keyButton(
              '/',
              onTap: () => _sendRawToShell(utf8.encode('/')),
            ),
            keyButton(
              '|',
              onTap: () => _sendRawToShell(utf8.encode('|')),
            ),
            keyButton(
              'KB',
              icon: Icons.keyboard_alt_outlined,
              onTap: () {
                _terminalFocusNode.requestFocus();
                SystemChannels.textInput.invokeMethod('TextInput.show');
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final scheme = AppColorScheme.of(context);

    return Column(
      children: [
        // Connection Info & Control Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: scheme.panelBackground,
          child: Row(
            children: [
              Icon(
                Icons.terminal,
                size: 16,
                color: _errorMessage != null
                    ? Colors.redAccent
                    : (_isLoading ? scheme.accentColor : Colors.greenAccent),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${widget.server.name} (${widget.server.username}@${widget.server.host})',
                  style: TextStyle(
                    color: scheme.primaryText,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.assignedTask != null)
                Flexible(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AssignedTabTaskBanner(
                      task: widget.assignedTask!,
                      onCompleteTask: () {
                        widget.onCompleteAssignedTask?.call();
                        _requestTerminalFocus();
                      },
                      onUnassignTask: () {
                        widget.onUnassignTask?.call();
                        _requestTerminalFocus();
                      },
                    ),
                  ),
                )
              else
                const Spacer(),

              // Scrollable right-hand toolbar controls so narrow screens never overflow
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Screen Logging Controls
                    if (_isScreenLogging)
                      InkWell(
                        onTap: _stopScreenLogging,
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.fiber_manual_record, size: 10, color: Colors.redAccent),
                              const SizedBox(width: 4),
                              Text(
                                'REC: ${p.basename(_screenLogPath ?? "log")}',
                                style: const TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.close, size: 12, color: Colors.redAccent),
                            ],
                          ),
                        ),
                      )
                    else
                      IconButton(
                        icon: Icon(Icons.fiber_manual_record_outlined, size: 15, color: scheme.mutedText),
                        tooltip: 'Start Screen Log (Save streamed terminal output to file)',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
                        onPressed: _startScreenLogging,
                      ),

                    // Divider
                    Container(
                      height: 14,
                      width: 1,
                      color: scheme.borderColor,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                    ),

                    // Copy & Paste Toolbar Buttons
                    IconButton(
                      icon: Icon(Icons.copy, size: 15, color: scheme.mutedText),
                      tooltip: 'Copy Selection (${Platform.isMacOS ? "⌘C" : "Ctrl+Shift+C"})',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
                      onPressed: _copySelection,
                    ),
                    IconButton(
                      icon: Icon(Icons.paste, size: 15, color: scheme.mutedText),
                      tooltip: 'Paste (${Platform.isMacOS ? "⌘V" : "Ctrl+V"})',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
                      onPressed: _pasteToTerminal,
                    ),

                    // Divider
                    Container(
                      height: 14,
                      width: 1,
                      color: scheme.borderColor,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                    ),

                    // Font size adjustment buttons
                    IconButton(
                      icon: Icon(Icons.remove, size: 14, color: scheme.mutedText),
                      tooltip: 'Decrease Font Size',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                      onPressed: _decreaseFontSize,
                    ),
                    InkWell(
                      onTap: _resetFontSize,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          '${_fontSize.toInt()}pt',
                          style: TextStyle(color: scheme.mutedText, fontSize: 11),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.add, size: 14, color: scheme.mutedText),
                      tooltip: 'Increase Font Size',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                      onPressed: _increaseFontSize,
                    ),

                    // Divider
                    Container(
                      height: 14,
                      width: 1,
                      color: scheme.borderColor,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                    ),

                    // ANSI Color Scheme Selector
                    PopupMenuButton<String>(
                      tooltip: 'ANSI Color Scheme: $_currentThemeName',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                      onSelected: _changeTheme,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: scheme.elevatedSurface,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: scheme.borderColor),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.palette_outlined, size: 12, color: scheme.accentColor),
                            const SizedBox(width: 4),
                            Text(
                              _currentThemeName,
                              style: TextStyle(fontSize: 11, color: scheme.primaryText),
                            ),
                            const SizedBox(width: 2),
                            Icon(Icons.arrow_drop_down, size: 13, color: scheme.mutedText),
                          ],
                        ),
                      ),
                      itemBuilder: (context) {
                        return AnsiThemes.all.keys.map((name) {
                          final isSelected = name == _currentThemeName;
                          final t = AnsiThemes.all[name]!;
                          return PopupMenuItem<String>(
                            value: name,
                            height: 32,
                            child: Row(
                              children: [
                                if (isSelected)
                                  Icon(Icons.check, size: 14, color: scheme.accentColor)
                                else
                                  const SizedBox(width: 14),
                                const SizedBox(width: 6),
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: t.background,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: t.foreground, width: 1.5),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(name, style: const TextStyle(fontSize: 12)),
                              ],
                            ),
                          );
                        }).toList();
                      },
                    ),

                    const SizedBox(width: 6),
                    if (_isLoading)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else if (_errorMessage != null)
                      IconButton(
                        icon: Icon(Icons.refresh, size: 16, color: scheme.accentColor),
                        tooltip: 'Reconnect',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                        onPressed: _connect,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Terminal Window
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            removeBottom: true,
            removeLeft: true,
            removeRight: true,
            child: TerminalView(
              terminal,
              controller: _terminalController,
              scrollController: _scrollController,
              focusNode: _terminalFocusNode,
              padding: EdgeInsets.zero,
              autofocus: true,
              hardwareKeyboardOnly: Platform.isWindows || Platform.isLinux || Platform.isMacOS,
              theme: _currentTheme,
              textStyle: TerminalStyle(
                fontSize: _fontSize,
              ),
              backgroundOpacity: 1.0,
              shortcuts: const <ShortcutActivator, Intent>{},
              onKeyEvent: _handleTerminalKeyEvent,
              onTapUp: (details, offset) {
                if (!_terminalFocusNode.hasFocus) {
                  _terminalFocusNode.requestFocus();
                }
              },
              onSecondaryTapUp: (details, offset) {
                _showContextMenu(details.globalPosition);
              },
            ),
          ),
        ),

        // Mobile Accessory Key Bar (ESC, TAB, CTRL, Arrows, Keyboard Toggle)
        if (isMobile) _buildMobileAccessoryBar(scheme),
      ],
    );
  }
}
