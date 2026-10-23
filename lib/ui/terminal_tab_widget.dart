import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:xterm/xterm.dart';
import '../models/server_config.dart';
import '../services/ssh_service.dart';
import '../theme/ansi_themes.dart';

class TerminalTabWidget extends StatefulWidget {
  final ServerConfig server;
  final SshService sshService;
  final TerminalTheme theme;
  final String? initialThemeName;
  final double fontSize;
  final bool isActive;
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
    this.onClose,
    this.onFontSizeChanged,
    this.onThemeChanged,
  });

  @override
  State<TerminalTabWidget> createState() => _TerminalTabWidgetState();
}

class _TerminalTabWidgetState extends State<TerminalTabWidget> {
  late final Terminal terminal;
  late final TerminalController _terminalController;
  late final FocusNode _terminalFocusNode;
  SshSession? _sshSession;
  bool _isLoading = true;
  String? _errorMessage;
  bool _isExited = false;
  late double _fontSize;
  late String _currentThemeName;
  late TerminalTheme _currentTheme;

  // Screen logging state
  bool _isScreenLogging = false;
  String? _screenLogPath;
  IOSink? _screenLogSink;
  int _screenLogBytesWritten = 0;
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

  @override
  void initState() {
    super.initState();
    _fontSize = widget.fontSize;
    terminal = Terminal(
      maxLines: 10000,
      platform: _getTerminalPlatform(),
    );
    _terminalController = TerminalController();
    _terminalFocusNode = FocusNode();
    _currentThemeName = widget.server.terminalTheme.isNotEmpty
        ? widget.server.terminalTheme
        : (widget.initialThemeName ?? 'Default Dark');
    _currentTheme = AnsiThemes.all[_currentThemeName] ?? widget.theme;
    _requestTerminalFocus();
    _connect();
  }

  @override
  void didUpdateWidget(TerminalTabWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) {
      _requestTerminalFocus();
    }
    if (oldWidget.fontSize != widget.fontSize) {
      _fontSize = widget.fontSize;
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
    }
    _requestTerminalFocus();
  }

  void _decreaseFontSize() {
    if (_fontSize > 8) {
      setState(() {
        _fontSize -= 1.0;
      });
      widget.onFontSizeChanged?.call(_fontSize);
    }
    _requestTerminalFocus();
  }

  void _resetFontSize() {
    setState(() {
      _fontSize = 13.0;
    });
    widget.onFontSizeChanged?.call(_fontSize);
    _requestTerminalFocus();
  }

  // --- Copy & Paste Support ---

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

    final text = terminal.buffer.getText(selection);
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
      terminal.paste(text);
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
                Platform.isMacOS ? '⌘A' : 'Ctrl+A',
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
    if (event is KeyDownEvent) {
      final isMeta = HardwareKeyboard.instance.isMetaPressed;
      final isCtrl = HardwareKeyboard.instance.isControlPressed;
      final isShift = HardwareKeyboard.instance.isShiftPressed;

      // Copy: Cmd+C (macOS) or Ctrl+Shift+C or (Ctrl+C if text is selected)
      if ((isMeta && event.logicalKey == LogicalKeyboardKey.keyC) ||
          (isCtrl && isShift && event.logicalKey == LogicalKeyboardKey.keyC) ||
          (isCtrl && event.logicalKey == LogicalKeyboardKey.keyC && _terminalController.selection != null)) {
        _copySelection();
        _terminalController.clearSelection();
        return KeyEventResult.handled;
      }

      // Paste: Cmd+V (macOS) or Ctrl+Shift+V or Ctrl+V
      if ((isMeta && event.logicalKey == LogicalKeyboardKey.keyV) ||
          (isCtrl && isShift && event.logicalKey == LogicalKeyboardKey.keyV) ||
          (isCtrl && event.logicalKey == LogicalKeyboardKey.keyV)) {
        _pasteToTerminal();
        return KeyEventResult.handled;
      }

      // Select All: Cmd+A (macOS)
      if (isMeta && event.logicalKey == LogicalKeyboardKey.keyA) {
        _selectAll();
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

    final savedUri = await FilePicker.saveFile(
      dialogTitle: 'Save Screen Log As',
      fileName: fileName,
      bytes: Uint8List.fromList(utf8.encode(header)),
    );

    if (savedUri == null || !mounted) return;

    final selectedPath = savedUri.toFilePath();

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Screen log saved (${(_screenLogBytesWritten / 1024).toStringAsFixed(1)} KB): ${p.basename(path)}'),
          action: SnackBarAction(
            label: Platform.isMacOS ? 'Show in Finder' : 'Open Folder',
            onPressed: () {
              if (Platform.isMacOS) {
                Process.run('open', ['-R', path]);
              } else if (Platform.isWindows) {
                Process.run('explorer.exe', ['/select,', path]);
              } else if (Platform.isLinux) {
                Process.run('xdg-open', [File(path).parent.path]);
              }
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
      final session = await widget.sshService.startShellSession(
        widget.server,
        terminalWidth: 80,
        terminalHeight: 24,
      );

      _sshSession = session;

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
        session.session.stdin.add(utf8.encode(data));
      };

      // Handle terminal resize events
      terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        session.session.resizeTerminal(width, height, pixelWidth, pixelHeight);
      };

      setState(() {
        _isLoading = false;
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
    _sshSession?.close();
    _stopScreenLogging();
    _terminalController.dispose();
    _terminalFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Connection Info & Control Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: const Color(0xFF252526),
          child: Row(
            children: [
              Icon(
                Icons.terminal,
                size: 16,
                color: _errorMessage != null
                    ? Colors.redAccent
                    : (_isLoading ? Colors.amber : Colors.greenAccent),
              ),
              const SizedBox(width: 8),
              Text(
                '${widget.server.name} (${widget.server.username}@${widget.server.host})',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              const Spacer(),

              // Screen Logging Controls
              if (_isScreenLogging)
                InkWell(
                  onTap: _stopScreenLogging,
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
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
                  icon: const Icon(Icons.fiber_manual_record_outlined, size: 15, color: Colors.grey),
                  tooltip: 'Start Screen Log (Save streamed terminal output to file)',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
                  onPressed: _startScreenLogging,
                ),

              // Divider
              Container(
                height: 14,
                width: 1,
                color: Colors.grey.shade700,
                margin: const EdgeInsets.symmetric(horizontal: 4),
              ),

              // Copy & Paste Toolbar Buttons
              IconButton(
                icon: const Icon(Icons.copy, size: 15, color: Colors.grey),
                tooltip: 'Copy Selection (${Platform.isMacOS ? "⌘C" : "Ctrl+Shift+C"})',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
                onPressed: _copySelection,
              ),
              IconButton(
                icon: const Icon(Icons.paste, size: 15, color: Colors.grey),
                tooltip: 'Paste (${Platform.isMacOS ? "⌘V" : "Ctrl+V"})',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
                onPressed: _pasteToTerminal,
              ),

              // Divider
              Container(
                height: 14,
                width: 1,
                color: Colors.grey.shade700,
                margin: const EdgeInsets.symmetric(horizontal: 4),
              ),

              // Font size adjustment buttons
              IconButton(
                icon: const Icon(Icons.remove, size: 14, color: Colors.grey),
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
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, size: 14, color: Colors.grey),
                tooltip: 'Increase Font Size',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                onPressed: _increaseFontSize,
              ),

              // Divider
              Container(
                height: 14,
                width: 1,
                color: Colors.grey.shade700,
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
                    color: const Color(0xFF333333),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey.shade800),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.palette_outlined, size: 12, color: Colors.amberAccent),
                      const SizedBox(width: 4),
                      Text(
                        _currentThemeName,
                        style: const TextStyle(fontSize: 11, color: Colors.white),
                      ),
                      const SizedBox(width: 2),
                      const Icon(Icons.arrow_drop_down, size: 13, color: Colors.grey),
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
                            const Icon(Icons.check, size: 14, color: Colors.amberAccent)
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
                  icon: const Icon(Icons.refresh, size: 16, color: Colors.amber),
                  tooltip: 'Reconnect',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  onPressed: _connect,
                ),
            ],
          ),
        ),

        // Terminal Window
        Expanded(
          child: TerminalView(
            terminal,
            controller: _terminalController,
            focusNode: _terminalFocusNode,
            autofocus: true,
            hardwareKeyboardOnly: Platform.isWindows || Platform.isLinux || Platform.isMacOS,
            theme: _currentTheme,
            textStyle: TerminalStyle(
              fontSize: _fontSize,
            ),
            backgroundOpacity: 1.0,
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
      ],
    );
  }
}
