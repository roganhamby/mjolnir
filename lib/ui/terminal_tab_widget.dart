import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';
import '../models/server_config.dart';
import '../services/ssh_service.dart';

class TerminalTabWidget extends StatefulWidget {
  final ServerConfig server;
  final SshService sshService;
  final TerminalTheme theme;
  final double fontSize;
  final VoidCallback? onClose;
  final Function(double newFontSize)? onFontSizeChanged;

  const TerminalTabWidget({
    super.key,
    required this.server,
    required this.sshService,
    this.theme = TerminalThemes.defaultTheme,
    this.fontSize = 13.0,
    this.onClose,
    this.onFontSizeChanged,
  });

  @override
  State<TerminalTabWidget> createState() => _TerminalTabWidgetState();
}

class _TerminalTabWidgetState extends State<TerminalTabWidget> {
  late final Terminal terminal;
  SshSession? _sshSession;
  bool _isLoading = true;
  String? _errorMessage;
  bool _isExited = false;
  late double _fontSize;

  @override
  void initState() {
    super.initState();
    _fontSize = widget.fontSize;
    terminal = Terminal(maxLines: 10000);
    _connect();
  }

  void _increaseFontSize() {
    if (_fontSize < 32) {
      setState(() {
        _fontSize += 1.0;
      });
      widget.onFontSizeChanged?.call(_fontSize);
    }
  }

  void _decreaseFontSize() {
    if (_fontSize > 8) {
      setState(() {
        _fontSize -= 1.0;
      });
      widget.onFontSizeChanged?.call(_fontSize);
    }
  }

  void _resetFontSize() {
    setState(() {
      _fontSize = 13.0;
    });
    widget.onFontSizeChanged?.call(_fontSize);
  }

  Future<void> _connect() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isExited = false;
    });

    terminal.write('Connecting to ${widget.server.username}@${widget.server.host}:${widget.server.port}...\r\n');

    try {
      final session = await widget.sshService.startShellSession(
        widget.server,
        terminalWidth: 80,
        terminalHeight: 24,
      );

      _sshSession = session;

      // Pipe SSH stdout to terminal
      session.session.stdout.listen(
        (data) {
          terminal.write(utf8.decode(data, allowMalformed: true));
        },
        onError: (err) {
          terminal.write('\r\n[SSH stdout error: $err]\r\n');
        },
        onDone: () {
          terminal.write('\r\n[Session closed]\r\n');
          _handleSessionDone();
        },
      );

      // Pipe SSH stderr to terminal
      session.session.stderr.listen((data) {
        terminal.write(utf8.decode(data, allowMalformed: true));
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
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
      terminal.write('\r\n[Connection Failed: $e]\r\n');
    }
  }

  void _handleSessionDone() {
    if (_isExited) return;
    _isExited = true;
    if (mounted && widget.onClose != null) {
      widget.onClose!();
    }
  }

  @override
  void dispose() {
    _sshSession?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Connection Info Bar
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
              const SizedBox(width: 8),
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
                  onPressed: _connect,
                ),
            ],
          ),
        ),
        // Terminal Window
        Expanded(
          child: TerminalView(
            terminal,
            autofocus: true,
            theme: widget.theme,
            textStyle: TerminalStyle(
              fontSize: _fontSize,
            ),
            backgroundOpacity: 1.0,
          ),
        ),
      ],
    );
  }
}
