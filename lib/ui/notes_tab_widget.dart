import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import '../models/note_item.dart';
import '../theme/app_color_schemes.dart';
import 'app_notification.dart';

/// View modes supported by the note editor panel.
enum NoteViewMode {
  edit,
  preview,
  split,
}

/// Reusable note editor with formatting toolbar and Markdown support.
///
/// Used both inside the Notes tab and as a docked side panel next to an
/// SSH / SFTP tab. Edits are applied to [note] immediately (in memory) and
/// persisted through [onSave] after a short debounce, on focus loss, and when
/// the editor is disposed.
class NoteEditorPanel extends StatefulWidget {
  final NoteItem note;
  final Future<void> Function(NoteItem note) onSave;

  /// Titles offered as quick suggestions in the "Link to tab" dialog
  /// (typically the titles of currently open SSH / SFTP tabs).
  final List<String> suggestedLinkTitles;

  /// When shown as a side panel, these render as header actions.
  final VoidCallback? onClose;
  final VoidCallback? onOpenInNotesTab;
  final VoidCallback? onDelete;

  /// Compact layout for the docked side panel.
  final bool compact;

  const NoteEditorPanel({
    super.key,
    required this.note,
    required this.onSave,
    this.suggestedLinkTitles = const [],
    this.onClose,
    this.onOpenInNotesTab,
    this.onDelete,
    this.compact = false,
  });

  static final Set<_NoteEditorPanelState> _liveEditors = {};

  /// Immediately persists any pending (debounced) edits in every live editor.
  /// Call before locking the vault so no keystrokes are lost.
  static Future<void> flushAll() async {
    for (final editor in _liveEditors.toList()) {
      await editor._flush();
    }
  }

  @override
  State<NoteEditorPanel> createState() => _NoteEditorPanelState();
}

class _NoteEditorPanelState extends State<NoteEditorPanel> {
  static const _saveDebounce = Duration(milliseconds: 1200);

  late final TextEditingController _titleController;
  late final TextEditingController _contentController;
  final FocusNode _titleFocus = FocusNode();
  final FocusNode _contentFocus = FocusNode();
  Timer? _saveTimer;
  bool _dirty = false;

  NoteViewMode _viewMode = NoteViewMode.edit;
  bool _isMonospace = true;
  double _fontSize = 13.0;
  bool _showFormattingBar = true;

  @override
  void initState() {
    super.initState();
    NoteEditorPanel._liveEditors.add(this);
    _titleController = TextEditingController(text: widget.note.title);
    _contentController = TextEditingController(text: widget.note.content);
    _titleFocus.addListener(_onFocusChanged);
    _contentFocus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(NoteEditorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.note.id != widget.note.id) {
      // Switched to a different note: persist the old one first.
      if (_dirty) {
        _saveTimer?.cancel();
        _dirty = false;
        oldWidget.onSave(oldWidget.note);
      }
      _titleController.text = widget.note.title;
      _contentController.text = widget.note.content;
      return;
    }
    // Same note, possibly edited elsewhere (e.g. open in both the Notes tab and
    // a side panel, or replaced by a sync merge). Only sync when not focused so
    // we never fight the user's cursor.
    if (!_titleFocus.hasFocus && _titleController.text != widget.note.title) {
      _titleController.text = widget.note.title;
    }
    if (!_contentFocus.hasFocus && _contentController.text != widget.note.content) {
      _contentController.text = widget.note.content;
    }
  }

  @override
  void dispose() {
    NoteEditorPanel._liveEditors.remove(this);
    _saveTimer?.cancel();
    if (_dirty) {
      _dirty = false;
      widget.onSave(widget.note);
    }
    _titleFocus.dispose();
    _contentFocus.dispose();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_titleFocus.hasFocus && !_contentFocus.hasFocus) {
      _flush();
    }
  }

  void _markDirty() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _flush);
  }

  Future<void> _flush() async {
    _saveTimer?.cancel();
    if (!_dirty) return;
    _dirty = false;
    await widget.onSave(widget.note);
  }

  Future<void> _saveNow() async {
    _saveTimer?.cancel();
    _dirty = false;
    await widget.onSave(widget.note);
  }

  Future<void> _showAddLinkDialog() async {
    final controller = TextEditingController();
    final suggestions = <String>{};
    for (final t in widget.suggestedLinkTitles) {
      final link = NoteItem.linkTitleForTab(t);
      if (link.isNotEmpty && !widget.note.matchesTabTitle(link)) suggestions.add(link);
    }

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Link Note to Tab Title'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This note will appear in the Related Notes menu for any SSH or SFTP tab with this title '
                '(case-insensitive, " (SSH)" / " (SFTP)" suffix ignored).',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Tab / Server Title',
                  hintText: 'e.g. Prod DB',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (v) => Navigator.of(ctx).pop(v),
              ),
              if (suggestions.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Open tabs:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: suggestions
                      .map((s) => ActionChip(
                            label: Text(s, style: const TextStyle(fontSize: 12)),
                            onPressed: () => Navigator.of(ctx).pop(s),
                          ))
                      .toList(),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Link'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (result == null || result.trim().isEmpty || !mounted) return;
    if (widget.note.linkToTabTitle(result.trim())) {
      setState(() {});
      await _saveNow();
    }
  }

  Future<void> _removeLink(String link) async {
    setState(() => widget.note.linkedTitles.remove(link));
    await _saveNow();
  }

  // --- Formatting Toolbar Actions ---

  void _wrapSelection(String prefix, String suffix, {String defaultText = ''}) {
    final text = _contentController.text;
    final selection = _contentController.selection;
    if (!selection.isValid || selection.isCollapsed) {
      final start = selection.isValid ? selection.baseOffset : text.length;
      final insert = '$prefix$defaultText$suffix';
      final newText = text.replaceRange(start, start, insert);
      _contentController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: start + prefix.length + defaultText.length),
      );
    } else {
      final start = selection.start;
      final end = selection.end;
      final selectedText = text.substring(start, end);
      final insert = '$prefix$selectedText$suffix';
      final newText = text.replaceRange(start, end, insert);
      _contentController.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: start + prefix.length,
          extentOffset: end + prefix.length,
        ),
      );
    }
    widget.note.content = _contentController.text;
    _markDirty();
    setState(() {});
    _contentFocus.requestFocus();
  }

  void _prefixSelectedLines(String prefix) {
    final text = _contentController.text;
    final selection = _contentController.selection;
    final start = selection.isValid ? selection.start : 0;
    final end = selection.isValid ? selection.end : text.length;

    final lineStart = text.lastIndexOf('\n', start - 1) + 1;
    final nextNewline = text.indexOf('\n', end);
    final lineEnd = nextNewline == -1 ? text.length : nextNewline;

    final targetRegion = text.substring(lineStart, lineEnd);
    final lines = targetRegion.split('\n');
    final allHavePrefix = lines.isNotEmpty && lines.every((l) => l.startsWith(prefix));

    final newLines = lines.map((l) {
      if (allHavePrefix) {
        return l.substring(prefix.length);
      } else {
        return '$prefix$l';
      }
    }).join('\n');

    final newText = text.replaceRange(lineStart, lineEnd, newLines);
    _contentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: lineStart,
        extentOffset: lineStart + newLines.length,
      ),
    );
    widget.note.content = _contentController.text;
    _markDirty();
    setState(() {});
    _contentFocus.requestFocus();
  }

  void _insertHeading(int level) {
    final prefix = '${'#' * level} ';
    final text = _contentController.text;
    final selection = _contentController.selection;
    final start = selection.isValid ? selection.start : 0;
    final lineStart = text.lastIndexOf('\n', start - 1) + 1;
    final lineEndIdx = text.indexOf('\n', lineStart);
    final lineEnd = lineEndIdx == -1 ? text.length : lineEndIdx;
    final line = text.substring(lineStart, lineEnd);

    final cleaned = line.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
    final newLine = '$prefix$cleaned';
    final newText = text.replaceRange(lineStart, lineEnd, newLine);

    _contentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: lineStart + newLine.length),
    );
    widget.note.content = _contentController.text;
    _markDirty();
    setState(() {});
    _contentFocus.requestFocus();
  }

  void _insertCodeBlock() {
    final text = _contentController.text;
    final selection = _contentController.selection;
    if (selection.isValid && !selection.isCollapsed) {
      final selected = text.substring(selection.start, selection.end);
      _wrapSelection('```\n', '\n```', defaultText: selected);
    } else {
      _wrapSelection('```\n', '\n```', defaultText: '// code');
    }
  }

  void _insertLinkDialog() async {
    final sel = _contentController.selection;
    final text = _contentController.text;
    final selectedText = (sel.isValid && !sel.isCollapsed)
        ? text.substring(sel.start, sel.end)
        : '';

    final textCtrl = TextEditingController(text: selectedText);
    final urlCtrl = TextEditingController(text: 'https://');

    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Insert Markdown Link'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: textCtrl,
              decoration: const InputDecoration(labelText: 'Link Text', isDense: true),
              autofocus: selectedText.isEmpty,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(labelText: 'URL (https://...)', isDense: true),
              autofocus: selectedText.isNotEmpty,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Insert')),
        ],
      ),
    );

    if (res == true && mounted) {
      final label = textCtrl.text.isEmpty ? 'link' : textCtrl.text;
      final url = urlCtrl.text.trim();
      final linkMd = '[$label]($url)';
      final insertStart = sel.isValid ? sel.start : text.length;
      final insertEnd = sel.isValid ? sel.end : text.length;
      final newText = text.replaceRange(insertStart, insertEnd, linkMd);
      _contentController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: insertStart + linkMd.length),
      );
      widget.note.content = _contentController.text;
      _markDirty();
      setState(() {});
    }
    textCtrl.dispose();
    urlCtrl.dispose();
  }

  void _insertHorizontalRule() {
    final text = _contentController.text;
    final sel = _contentController.selection;
    final offset = sel.isValid ? sel.baseOffset : text.length;
    final insert = offset == 0 || text.endsWith('\n') ? '\n---\n\n' : '\n\n---\n\n';
    final newText = text.replaceRange(offset, offset, insert);
    _contentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: offset + insert.length),
    );
    widget.note.content = _contentController.text;
    _markDirty();
    setState(() {});
    _contentFocus.requestFocus();
  }

  void _stripFormatting() {
    final text = _contentController.text;
    final sel = _contentController.selection;
    if (!sel.isValid || sel.isCollapsed) return;

    final selected = text.substring(sel.start, sel.end);
    final cleaned = selected
        .replaceAll(RegExp(r'\*\*|__|\*|_|~~|`'), '')
        .replaceAll(RegExp(r'^\s*#{1,6}\s*', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*[-*+]\s*(\[[ xX]\]\s*)?', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*\d+\.\s*', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*>\s*', multiLine: true), '')
        .replaceAll(RegExp(r'\[(.*?)\]\(.*?\)'), r'$1');

    final newText = text.replaceRange(sel.start, sel.end, cleaned);
    _contentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection(baseOffset: sel.start, extentOffset: sel.start + cleaned.length),
    );
    widget.note.content = _contentController.text;
    _markDirty();
    setState(() {});
  }

  void _onToggleTask(int lineIndex) {
    final lines = _contentController.text.split('\n');
    if (lineIndex < 0 || lineIndex >= lines.length) return;
    final line = lines[lineIndex];
    if (line.contains('[ ]')) {
      lines[lineIndex] = line.replaceFirst('[ ]', '[x]');
    } else if (line.contains('[x]') || line.contains('[X]')) {
      lines[lineIndex] = line.replaceFirst(RegExp(r'\[[xX]\]'), '[ ]');
    }
    final newContent = lines.join('\n');
    _contentController.text = newContent;
    widget.note.content = newContent;
    _markDirty();
    setState(() {});
  }

  // --- Import / Export Operations ---

  Future<void> _exportAsMarkdown() async {
    try {
      final mdContent = widget.note.toMarkdown();
      final bytes = Uint8List.fromList(utf8.encode(mdContent));
      final safeName = widget.note.displayTitle
          .replaceAll(RegExp(r'[^a-zA-Z0-9_\-\.]'), '_')
          .replaceAll(RegExp(r'_+'), '_');
      final fileName = safeName.isNotEmpty ? '$safeName.md' : 'note.md';

      final savedUri = await FilePicker.saveFile(
        dialogTitle: 'Export Note as Markdown',
        fileName: fileName,
        bytes: bytes,
      );

      if (savedUri != null && mounted) {
        if (!Platform.isAndroid && !Platform.isIOS) {
          try {
            final f = File(savedUri.toFilePath());
            if (!await f.exists() || await f.length() == 0) {
              await f.writeAsBytes(bytes, flush: true);
            }
          } catch (_) {}
        }
        if (mounted) {
          AppNotification.success(context, 'Exported "${widget.note.displayTitle}" to Markdown.');
        }
      }
    } catch (e) {
      if (mounted) {
        AppNotification.error(context, 'Export failed: $e');
      }
    }
  }

  Future<void> _importMarkdownIntoNote() async {
    try {
      final res = await FilePicker.pickFiles(
        dialogTitle: 'Select Markdown File to Import',
        type: FileType.custom,
        allowedExtensions: ['md', 'markdown', 'txt'],
      );
      if (res.isEmpty || res.first.path == null) return;
      final file = File(res.first.path!);
      final content = await file.readAsString();
      if (!mounted) return;

      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import Markdown File'),
          content: Text('Importing "${p.basename(file.path)}". How would you like to apply it to "${widget.note.displayTitle}"?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('cancel'),
              child: const Text('Cancel'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.of(ctx).pop('append'),
              child: const Text('Append to End'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop('replace'),
              child: const Text('Replace Content'),
            ),
          ],
        ),
      );

      if (action == 'replace') {
        _contentController.text = content;
        widget.note.content = content;
        _markDirty();
        setState(() {});
        if (mounted) {
          AppNotification.success(context, 'Replaced note content with imported markdown.');
        }
      } else if (action == 'append') {
        final current = _contentController.text;
        final newText = current.isEmpty ? content : '$current\n\n$content';
        _contentController.text = newText;
        widget.note.content = newText;
        _markDirty();
        setState(() {});
        if (mounted) {
          AppNotification.success(context, 'Appended imported markdown to note.');
        }
      }
    } catch (e) {
      if (mounted) {
        AppNotification.error(context, 'Import failed: $e');
      }
    }
  }

  Widget _buildFormattingToolbar(AppColorScheme scheme) {
    Widget button({
      required Widget icon,
      required String tooltip,
      required VoidCallback onPressed,
      bool isActive = false,
    }) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onPressed,
          child: Container(
            padding: const EdgeInsets.all(5),
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: isActive ? scheme.accentColor.withValues(alpha: 0.2) : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: IconTheme(
              data: IconThemeData(
                size: 15,
                color: isActive ? scheme.accentColor : scheme.primaryText,
              ),
              child: icon,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.elevatedSurface,
        border: Border(bottom: BorderSide(color: scheme.borderColor)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Headings
            PopupMenuButton<int>(
              tooltip: 'Heading Style',
              padding: EdgeInsets.zero,
              icon: Icon(Icons.title, size: 16, color: scheme.primaryText),
              onSelected: (lvl) {
                if (lvl == 0) {
                  _stripFormatting();
                } else {
                  _insertHeading(lvl);
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(value: 1, child: Text('Heading 1 (#)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
                const PopupMenuItem(value: 2, child: Text('Heading 2 (##)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                const PopupMenuItem(value: 3, child: Text('Heading 3 (###)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                const PopupMenuItem(value: 0, child: Text('Normal text', style: TextStyle(fontSize: 12))),
              ],
            ),
            const SizedBox(width: 4),

            // Text Styles
            button(
              icon: const Icon(Icons.format_bold),
              tooltip: 'Bold (**text**)',
              onPressed: () => _wrapSelection('**', '**', defaultText: 'bold'),
            ),
            button(
              icon: const Icon(Icons.format_italic),
              tooltip: 'Italic (*text*)',
              onPressed: () => _wrapSelection('*', '*', defaultText: 'italic'),
            ),
            button(
              icon: const Icon(Icons.format_strikethrough),
              tooltip: 'Strikethrough (~~text~~)',
              onPressed: () => _wrapSelection('~~', '~~', defaultText: 'text'),
            ),
            button(
              icon: const Icon(Icons.code),
              tooltip: 'Inline Code (`text`)',
              onPressed: () => _wrapSelection('`', '`', defaultText: 'code'),
            ),
            button(
              icon: const Icon(Icons.integration_instructions_outlined),
              tooltip: 'Code Block (```)',
              onPressed: _insertCodeBlock,
            ),

            Container(height: 16, width: 1, margin: const EdgeInsets.symmetric(horizontal: 4), color: scheme.borderColor),

            // Lists & Blocks
            button(
              icon: const Icon(Icons.format_list_bulleted),
              tooltip: 'Bullet List (- item)',
              onPressed: () => _prefixSelectedLines('- '),
            ),
            button(
              icon: const Icon(Icons.format_list_numbered),
              tooltip: 'Numbered List (1. item)',
              onPressed: () => _prefixSelectedLines('1. '),
            ),
            button(
              icon: const Icon(Icons.check_box_outlined),
              tooltip: 'Task Checklist (- [ ] item)',
              onPressed: () => _prefixSelectedLines('- [ ] '),
            ),
            button(
              icon: const Icon(Icons.format_quote),
              tooltip: 'Quote (> text)',
              onPressed: () => _prefixSelectedLines('> '),
            ),
            button(
              icon: const Icon(Icons.link),
              tooltip: 'Insert Link ([text](url))',
              onPressed: _insertLinkDialog,
            ),
            button(
              icon: const Icon(Icons.horizontal_rule),
              tooltip: 'Horizontal Rule (---)',
              onPressed: _insertHorizontalRule,
            ),
            button(
              icon: const Icon(Icons.format_clear),
              tooltip: 'Clear Formatting from Selection',
              onPressed: _stripFormatting,
            ),

            Container(height: 16, width: 1, margin: const EdgeInsets.symmetric(horizontal: 4), color: scheme.borderColor),

            // Font & Size Controls
            button(
              icon: Icon(
                _isMonospace ? Icons.code_rounded : Icons.font_download_outlined,
                color: _isMonospace ? scheme.accentColor : scheme.primaryText,
              ),
              tooltip: _isMonospace ? 'Switch to Proportional font' : 'Switch to Monospace font',
              onPressed: () => setState(() => _isMonospace = !_isMonospace),
            ),
            button(
              icon: const Text('A-', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              tooltip: 'Decrease font size',
              onPressed: () {
                if (_fontSize > 10.0) setState(() => _fontSize -= 1.0);
              },
            ),
            button(
              icon: const Text('A+', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              tooltip: 'Increase font size',
              onPressed: () {
                if (_fontSize < 24.0) setState(() => _fontSize += 1.0);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = AppColorScheme.of(context);
    final note = widget.note;
    final lineCount = _contentController.text.isEmpty
        ? 0
        : '\n'.allMatches(_contentController.text).length + 1;

    final editorWidget = Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
      child: TextField(
        controller: _contentController,
        focusNode: _contentFocus,
        expands: true,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        autocorrect: false,
        enableSuggestions: false,
        spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
        style: TextStyle(
          fontFamily: _isMonospace ? 'monospace' : null,
          fontSize: _fontSize,
          height: 1.35,
          color: scheme.primaryText,
        ),
        decoration: InputDecoration(
          hintText: 'Start typing markdown or notes...',
          hintStyle: TextStyle(
            color: scheme.mutedText,
            fontFamily: _isMonospace ? 'monospace' : null,
          ),
          border: InputBorder.none,
        ),
        onChanged: (v) {
          note.content = v;
          _markDirty();
          setState(() {}); // refresh line/char counts & live preview
        },
      ),
    );

    final previewWidget = Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: NoteMarkdownPreview(
        content: _contentController.text,
        onToggleTask: _onToggleTask,
        fontSize: _fontSize,
        isMonospace: _isMonospace,
      ),
    );

    return Container(
      color: scheme.panelBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: title + actions
          Padding(
            padding: EdgeInsets.fromLTRB(12, widget.compact ? 6 : 10, 6, 4),
            child: Row(
              children: [
                Icon(Icons.sticky_note_2_outlined, size: 16, color: scheme.accentColor),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _titleController,
                    focusNode: _titleFocus,
                    autocorrect: false,
                    enableSuggestions: false,
                    spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
                    style: TextStyle(
                      fontSize: widget.compact ? 13 : 15,
                      fontWeight: FontWeight.bold,
                      color: scheme.primaryText,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Untitled note',
                      hintStyle: TextStyle(color: scheme.mutedText),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 6),
                    ),
                    onChanged: (v) {
                      note.title = v;
                      _markDirty();
                    },
                  ),
                ),

                // View Mode buttons: Edit / Preview / Split
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: scheme.elevatedSurface,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: scheme.borderColor),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(Icons.edit_note, size: 16, color: _viewMode == NoteViewMode.edit ? scheme.accentColor : scheme.mutedText),
                        tooltip: 'Edit Mode',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                        onPressed: () => setState(() => _viewMode = NoteViewMode.edit),
                      ),
                      IconButton(
                        icon: Icon(Icons.visibility_outlined, size: 15, color: _viewMode == NoteViewMode.preview ? scheme.accentColor : scheme.mutedText),
                        tooltip: 'Preview Markdown',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                        onPressed: () => setState(() => _viewMode = NoteViewMode.preview),
                      ),
                      if (!widget.compact)
                        IconButton(
                          icon: Icon(Icons.vertical_split_outlined, size: 15, color: _viewMode == NoteViewMode.split ? scheme.accentColor : scheme.mutedText),
                          tooltip: 'Split View',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                          onPressed: () => setState(() => _viewMode = NoteViewMode.split),
                        ),
                    ],
                  ),
                ),

                // Markdown Export / Import Menu
                PopupMenuButton<String>(
                  tooltip: 'Markdown & Note Options',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: Icon(Icons.more_vert, size: 16, color: scheme.mutedText),
                  onSelected: (val) {
                    if (val == 'export_md') {
                      _exportAsMarkdown();
                    } else if (val == 'import_md') {
                      _importMarkdownIntoNote();
                    } else if (val == 'copy_md') {
                      Clipboard.setData(ClipboardData(text: note.toMarkdown()));
                      AppNotification.show(context, message: 'Copied note markdown to clipboard');
                    } else if (val == 'toggle_toolbar') {
                      setState(() => _showFormattingBar = !_showFormattingBar);
                    }
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(
                      value: 'export_md',
                      child: Row(
                        children: [
                          Icon(Icons.file_download_outlined, size: 16),
                          SizedBox(width: 8),
                          Text('Export as Markdown (.md)', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'import_md',
                      child: Row(
                        children: [
                          Icon(Icons.file_upload_outlined, size: 16),
                          SizedBox(width: 8),
                          Text('Import Markdown file...', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'copy_md',
                      child: Row(
                        children: [
                          Icon(Icons.copy, size: 16),
                          SizedBox(width: 8),
                          Text('Copy Markdown', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'toggle_toolbar',
                      child: Row(
                        children: [
                          Icon(_showFormattingBar ? Icons.check_box : Icons.check_box_outline_blank, size: 16),
                          const SizedBox(width: 8),
                          const Text('Show Formatting Bar', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),

                if (widget.onOpenInNotesTab != null)
                  IconButton(
                    icon: Icon(Icons.open_in_new, size: 15, color: scheme.mutedText),
                    tooltip: 'Open in Notes tab',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: () async {
                      await _flush();
                      widget.onOpenInNotesTab!();
                    },
                  ),
                if (widget.onDelete != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                    tooltip: 'Delete note',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: widget.onDelete,
                  ),
                if (widget.onClose != null)
                  IconButton(
                    icon: Icon(Icons.close, size: 16, color: scheme.mutedText),
                    tooltip: 'Close note panel',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: () async {
                      await _flush();
                      widget.onClose!();
                    },
                  ),
              ],
            ),
          ),

          // Linked titles
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(Icons.link, size: 14, color: scheme.mutedText),
                ...note.linkedTitles.map(
                  (link) => InputChip(
                    label: Text(link, style: TextStyle(fontSize: 11, color: scheme.primaryText)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: EdgeInsets.zero,
                    deleteIconColor: scheme.mutedText,
                    onDeleted: () => _removeLink(link),
                    deleteButtonTooltipMessage: 'Unlink',
                  ),
                ),
                ActionChip(
                  avatar: Icon(Icons.add, size: 13, color: scheme.accentColor),
                  label: Text(
                    note.linkedTitles.isEmpty ? 'Link to tab title' : 'Link',
                    style: TextStyle(fontSize: 11, color: scheme.primaryText),
                  ),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: EdgeInsets.zero,
                  onPressed: _showAddLinkDialog,
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: scheme.borderColor),

          // Formatting Toolbar
          if (_showFormattingBar && (_viewMode == NoteViewMode.edit || _viewMode == NoteViewMode.split))
            _buildFormattingToolbar(scheme),

          // Main Content Area
          Expanded(
            child: _viewMode == NoteViewMode.edit
                ? editorWidget
                : _viewMode == NoteViewMode.preview
                    ? previewWidget
                    : Row(
                        children: [
                          Expanded(child: editorWidget),
                          VerticalDivider(width: 1, thickness: 1, color: scheme.borderColor),
                          Expanded(child: previewWidget),
                        ],
                      ),
          ),

          // Footer status
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: scheme.borderColor)),
            ),
            child: Row(
              children: [
                Text(
                  '$lineCount lines • ${_contentController.text.length} chars',
                  style: TextStyle(fontSize: 10, color: scheme.mutedText),
                ),
                const SizedBox(width: 12),
                Text(
                  _viewMode == NoteViewMode.edit
                      ? 'Edit'
                      : _viewMode == NoteViewMode.preview
                          ? 'Preview'
                          : 'Split View',
                  style: TextStyle(fontSize: 10, color: scheme.accentColor),
                ),
                const Spacer(),
                Text(
                  'Updated ${DateFormat('yyyy-MM-dd HH:mm').format(note.updatedAt.toLocal())}',
                  style: TextStyle(fontSize: 10, color: scheme.mutedText),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Lightweight, self-contained Markdown preview widget with task checklist toggling,
/// styled code blocks with copy action, headers, quotes, and links.
class NoteMarkdownPreview extends StatelessWidget {
  final String content;
  final Function(int lineIndex)? onToggleTask;
  final double fontSize;
  final bool isMonospace;

  const NoteMarkdownPreview({
    super.key,
    required this.content,
    this.onToggleTask,
    this.fontSize = 13.0,
    this.isMonospace = false,
  });

  static final RegExp _headingRegex = RegExp(r'^(#{1,6})\s+(.*)$');
  static final RegExp _taskRegex = RegExp(r'^\s*[-*+]\s+\[([ xX])\]\s*(.*)$');
  static final RegExp _bulletRegex = RegExp(r'^\s*[-*+]\s+(.*)$');
  static final RegExp _orderedRegex = RegExp(r'^\s*(\d+)\.\s+(.*)$');
  static final RegExp _quoteRegex = RegExp(r'^\s*>\s*(.*)$');
  static final RegExp _hrRegex = RegExp(r'^\s*([-*_]){3,}\s*$');

  void _launchUrl(String rawUrl, BuildContext context) async {
    try {
      var url = rawUrl.trim();
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        url = 'https://$url';
      }
      final uri = Uri.parse(url);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (context.mounted) {
        AppNotification.error(context, 'Could not open URL: $rawUrl');
      }
    }
  }

  List<InlineSpan> _parseInlineSpans(String text, TextStyle baseStyle, AppColorScheme scheme, BuildContext context) {
    final spans = <InlineSpan>[];
    // Regex matching bold-italic, bold, italic, strikethrough, inline code, and links
    final inlineRegex = RegExp(
      r'(\*\*\*.*?\*\*\*|___.*?___|\*\*.*?\*\*|__.*?__|(?<!\*)\*(?!\*).*?(?<!\*)\*(?!\*)|(?<!_)_(?!_).*?(?<!_)_(?!_)|~~.*?~~|`[^`]+`|\[.*?\]\(.*?\))',
    );

    var lastIndex = 0;
    for (final match in inlineRegex.allMatches(text)) {
      if (match.start > lastIndex) {
        spans.add(TextSpan(text: text.substring(lastIndex, match.start), style: baseStyle));
      }
      final matchStr = match.group(0)!;
      if (matchStr.startsWith('***') && matchStr.endsWith('***') && matchStr.length >= 6) {
        spans.add(TextSpan(
          text: matchStr.substring(3, matchStr.length - 3),
          style: baseStyle.copyWith(fontWeight: FontWeight.bold, fontStyle: FontStyle.italic),
        ));
      } else if ((matchStr.startsWith('**') && matchStr.endsWith('**') && matchStr.length >= 4) ||
          (matchStr.startsWith('__') && matchStr.endsWith('__') && matchStr.length >= 4)) {
        spans.add(TextSpan(
          text: matchStr.substring(2, matchStr.length - 2),
          style: baseStyle.copyWith(fontWeight: FontWeight.bold),
        ));
      } else if ((matchStr.startsWith('*') && matchStr.endsWith('*') && matchStr.length >= 2) ||
          (matchStr.startsWith('_') && matchStr.endsWith('_') && matchStr.length >= 2)) {
        spans.add(TextSpan(
          text: matchStr.substring(1, matchStr.length - 1),
          style: baseStyle.copyWith(fontStyle: FontStyle.italic),
        ));
      } else if (matchStr.startsWith('~~') && matchStr.endsWith('~~') && matchStr.length >= 4) {
        spans.add(TextSpan(
          text: matchStr.substring(2, matchStr.length - 2),
          style: baseStyle.copyWith(decoration: TextDecoration.lineThrough),
        ));
      } else if (matchStr.startsWith('`') && matchStr.endsWith('`') && matchStr.length >= 2) {
        final codeText = matchStr.substring(1, matchStr.length - 1);
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.elevatedSurface,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: scheme.borderColor),
            ),
            child: Text(
              codeText,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: baseStyle.fontSize != null ? baseStyle.fontSize! * 0.9 : 12,
                color: scheme.accentColor,
              ),
            ),
          ),
        ));
      } else if (matchStr.startsWith('[') && matchStr.contains('](') && matchStr.endsWith(')')) {
        final linkClose = matchStr.indexOf('](');
        final label = matchStr.substring(1, linkClose);
        final url = matchStr.substring(linkClose + 2, matchStr.length - 1);
        spans.add(TextSpan(
          text: label,
          style: baseStyle.copyWith(
            color: scheme.accentColor,
            decoration: TextDecoration.underline,
          ),
          recognizer: TapGestureRecognizer()..onTap = () => _launchUrl(url, context),
        ));
      } else {
        spans.add(TextSpan(text: matchStr, style: baseStyle));
      }
      lastIndex = match.end;
    }
    if (lastIndex < text.length) {
      spans.add(TextSpan(text: text.substring(lastIndex), style: baseStyle));
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = AppColorScheme.of(context);
    if (content.trim().isEmpty) {
      return Center(
        child: Text(
          'Empty note. Switch to Edit mode to write markdown.',
          style: TextStyle(color: scheme.mutedText, fontSize: 12),
        ),
      );
    }

    final baseStyle = TextStyle(
      fontSize: fontSize,
      fontFamily: isMonospace ? 'monospace' : null,
      color: scheme.primaryText,
      height: 1.4,
    );

    final rawLines = content.split('\n');
    final widgets = <Widget>[];

    var inCodeBlock = false;
    var codeBlockLanguage = '';
    final codeBlockLines = <String>[];

    for (var i = 0; i < rawLines.length; i++) {
      final line = rawLines[i];

      // Code Block handling
      if (line.trim().startsWith('```')) {
        if (inCodeBlock) {
          // Closing code block
          final codeText = codeBlockLines.join('\n');
          final lang = codeBlockLanguage;
          widgets.add(Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: scheme.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: const BoxDecoration(
                    color: Color(0xFF282828),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(5)),
                  ),
                  child: Row(
                    children: [
                      Text(
                        lang.isNotEmpty ? lang : 'code',
                        style: const TextStyle(fontSize: 10, color: Colors.grey, fontFamily: 'monospace'),
                      ),
                      const Spacer(),
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: codeText));
                          AppNotification.show(context, message: 'Code copied to clipboard');
                        },
                        child: const Row(
                          children: [
                            Icon(Icons.copy, size: 12, color: Colors.grey),
                            SizedBox(width: 4),
                            Text('Copy', style: TextStyle(fontSize: 10, color: Colors.grey)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    codeText,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Color(0xFFD4D4D4),
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ));
          inCodeBlock = false;
          codeBlockLines.clear();
          codeBlockLanguage = '';
        } else {
          inCodeBlock = true;
          codeBlockLanguage = line.trim().substring(3).trim();
          codeBlockLines.clear();
        }
        continue;
      }

      if (inCodeBlock) {
        codeBlockLines.add(line);
        continue;
      }

      // Horizontal Rule
      if (_hrRegex.hasMatch(line)) {
        widgets.add(Divider(height: 20, thickness: 1, color: scheme.borderColor));
        continue;
      }

      // Headings
      final headingMatch = _headingRegex.firstMatch(line);
      if (headingMatch != null) {
        final level = headingMatch.group(1)!.length;
        final hText = headingMatch.group(2)!;
        final hSizes = [22.0, 18.0, 15.0, 13.5, 12.5, 12.0];
        final hSize = (level >= 1 && level <= 6) ? hSizes[level - 1] : 13.0;

        widgets.add(Padding(
          padding: EdgeInsets.only(top: level <= 2 ? 10 : 6, bottom: 4),
          child: SelectableText.rich(
            TextSpan(
              children: _parseInlineSpans(
                hText,
                baseStyle.copyWith(
                  fontSize: hSize,
                  fontWeight: FontWeight.bold,
                  color: level == 1 ? scheme.accentColor : scheme.primaryText,
                ),
                scheme,
                context,
              ),
            ),
          ),
        ));
        continue;
      }

      // Blockquote
      final quoteMatch = _quoteRegex.firstMatch(line);
      if (quoteMatch != null) {
        final qText = quoteMatch.group(1)!;
        widgets.add(Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: scheme.accentColor, width: 3)),
            color: scheme.elevatedSurface.withValues(alpha: 0.5),
          ),
          child: SelectableText.rich(
            TextSpan(
              children: _parseInlineSpans(
                qText,
                baseStyle.copyWith(fontStyle: FontStyle.italic, color: scheme.mutedText),
                scheme,
                context,
              ),
            ),
          ),
        ));
        continue;
      }

      // Task Checklist
      final taskMatch = _taskRegex.firstMatch(line);
      if (taskMatch != null) {
        final checked = taskMatch.group(1)!.toLowerCase() == 'x';
        final tText = taskMatch.group(2)!;
        final lineIdx = i;

        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 20,
                width: 20,
                child: Checkbox(
                  value: checked,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  activeColor: scheme.accentColor,
                  onChanged: onToggleTask != null ? (_) => onToggleTask!(lineIdx) : null,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SelectableText.rich(
                  TextSpan(
                    children: _parseInlineSpans(
                      tText,
                      baseStyle.copyWith(
                        decoration: checked ? TextDecoration.lineThrough : null,
                        color: checked ? scheme.mutedText : scheme.primaryText,
                      ),
                      scheme,
                      context,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ));
        continue;
      }

      // Bullet List
      final bulletMatch = _bulletRegex.firstMatch(line);
      if (bulletMatch != null) {
        final bText = bulletMatch.group(1)!;
        widgets.add(Padding(
          padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('• ', style: TextStyle(color: scheme.accentColor, fontWeight: FontWeight.bold, fontSize: fontSize)),
              Expanded(
                child: SelectableText.rich(
                  TextSpan(children: _parseInlineSpans(bText, baseStyle, scheme, context)),
                ),
              ),
            ],
          ),
        ));
        continue;
      }

      // Numbered List
      final orderedMatch = _orderedRegex.firstMatch(line);
      if (orderedMatch != null) {
        final num = orderedMatch.group(1)!;
        final oText = orderedMatch.group(2)!;
        widgets.add(Padding(
          padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$num. ', style: TextStyle(color: scheme.accentColor, fontWeight: FontWeight.bold, fontSize: fontSize)),
              Expanded(
                child: SelectableText.rich(
                  TextSpan(children: _parseInlineSpans(oText, baseStyle, scheme, context)),
                ),
              ),
            ],
          ),
        ));
        continue;
      }

      // Empty Line
      if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 6));
        continue;
      }

      // Regular Paragraph Line
      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: SelectableText.rich(
          TextSpan(children: _parseInlineSpans(line, baseStyle, scheme, context)),
        ),
      ));
    }

    // Flush any unclosed code block
    if (inCodeBlock && codeBlockLines.isNotEmpty) {
      widgets.add(Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(6),
        ),
        child: SelectableText(
          codeBlockLines.join('\n'),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFFD4D4D4)),
        ),
      ));
    }

    return SelectionArea(
      child: ListView(
        children: widgets,
      ),
    );
  }
}

/// Full Notes tab: searchable note list on the left, editor on the right.
class NotesTabWidget extends StatefulWidget {
  final List<NoteItem> notes;
  final String? selectedNoteId;
  final ValueChanged<String?> onSelectNote;
  final Future<void> Function(NoteItem note) onSaveNote;
  final Future<void> Function(String id) onDeleteNote;
  final List<String> suggestedLinkTitles;

  const NotesTabWidget({
    super.key,
    required this.notes,
    required this.selectedNoteId,
    required this.onSelectNote,
    required this.onSaveNote,
    required this.onDeleteNote,
    this.suggestedLinkTitles = const [],
  });

  /// Creates a new empty note (optionally linked to [linkTitle]).
  static NoteItem createNote({String? linkTitle}) {
    final note = NoteItem(id: const Uuid().v4());
    if (linkTitle != null && linkTitle.trim().isNotEmpty) {
      note.linkToTabTitle(linkTitle);
    }
    return note;
  }

  @override
  State<NotesTabWidget> createState() => _NotesTabWidgetState();
}

class _NotesTabWidgetState extends State<NotesTabWidget> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<NoteItem> get _filteredNotes {
    final sorted = [...widget.notes]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return sorted;
    return sorted.where((n) {
      return n.title.toLowerCase().contains(q) ||
          n.content.toLowerCase().contains(q) ||
          n.linkedTitles.any((l) => l.toLowerCase().contains(q));
    }).toList();
  }

  Future<void> _createNote() async {
    final note = NotesTabWidget.createNote();
    await widget.onSaveNote(note);
    widget.onSelectNote(note.id);
  }

  Future<void> _importMarkdownFiles() async {
    try {
      final res = await FilePicker.pickFiles(
        dialogTitle: 'Select Markdown File(s) to Import',
        type: FileType.custom,
        allowedExtensions: ['md', 'markdown', 'txt'],
      );
      if (res.isEmpty) return;

      var importedCount = 0;
      String? lastImportedId;

      for (final f in res) {
        if (f.path == null) continue;
        final file = File(f.path!);
        if (!await file.exists()) continue;
        final content = await file.readAsString();
        final fileNameWithoutExt = p.basenameWithoutExtension(file.path);
        final note = NoteItem.fromMarkdown(
          content,
          defaultTitle: fileNameWithoutExt,
          id: const Uuid().v4(),
        );
        await widget.onSaveNote(note);
        importedCount++;
        lastImportedId = note.id;
      }

      if (importedCount > 0) {
        if (lastImportedId != null) {
          widget.onSelectNote(lastImportedId);
        }
        if (mounted) {
          AppNotification.success(
            context,
            'Imported $importedCount Markdown note${importedCount == 1 ? '' : 's'}.',
          );
        }
      }
    } catch (e) {
      if (mounted) {
        AppNotification.error(context, 'Import failed: $e');
      }
    }
  }

  Future<void> _exportAllNotesAsMarkdown() async {
    if (widget.notes.isEmpty) {
      AppNotification.show(context, message: 'No notes to export.');
      return;
    }

    try {
      final selectedDir = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select Destination Folder for Markdown Notes',
      );
      if (selectedDir == null || !mounted) return;

      var exportedCount = 0;
      for (final n in widget.notes) {
        final safeName = n.displayTitle
            .replaceAll(RegExp(r'[^a-zA-Z0-9_\-\.]'), '_')
            .replaceAll(RegExp(r'_+'), '_');
        final fileName = safeName.isNotEmpty ? '$safeName.md' : 'note_${n.id.substring(0, 8)}.md';
        final filePath = p.join(selectedDir, fileName);
        final md = n.toMarkdown();
        await File(filePath).writeAsString(md, flush: true);
        exportedCount++;
      }

      if (mounted) {
        AppNotification.success(
          context,
          'Exported $exportedCount note${exportedCount == 1 ? '' : 's'} to $selectedDir',
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.error(context, 'Export failed: $e');
      }
    }
  }

  Future<void> _exportAllNotesAsSingleFile() async {
    if (widget.notes.isEmpty) {
      AppNotification.show(context, message: 'No notes to export.');
      return;
    }

    try {
      final buffer = StringBuffer();
      buffer.writeln('# Mjölnir Notes Archive');
      buffer.writeln('> Exported on ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}\n');

      for (final n in widget.notes) {
        buffer.writeln('---\n');
        buffer.writeln(n.toMarkdown());
        buffer.writeln();
      }

      final bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
      final dateStr = DateTime.now().toIso8601String().split('T').first;

      final savedUri = await FilePicker.saveFile(
        dialogTitle: 'Export All Notes to Single Markdown File',
        fileName: 'mjolnir-all-notes-$dateStr.md',
        bytes: bytes,
      );

      if (savedUri != null && mounted) {
        if (!Platform.isAndroid && !Platform.isIOS) {
          try {
            final f = File(savedUri.toFilePath());
            if (!await f.exists() || await f.length() == 0) {
              await f.writeAsBytes(bytes, flush: true);
            }
          } catch (_) {}
        }
        if (mounted) {
          AppNotification.success(context, 'Exported all notes to Markdown archive.');
        }
      }
    } catch (e) {
      if (mounted) {
        AppNotification.error(context, 'Export failed: $e');
      }
    }
  }

  Future<void> _confirmDelete(NoteItem note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Note'),
        content: Text('Delete "${note.displayTitle}"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.onDeleteNote(note.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = AppColorScheme.of(context);
    final notes = _filteredNotes;
    NoteItem? selected;
    for (final n in widget.notes) {
      if (n.id == widget.selectedNoteId) {
        selected = n;
        break;
      }
    }

    final list = Container(
      width: 270,
      color: scheme.scaffoldBackground,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(fontSize: 12),
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      hintText: 'Search notes...',
                      prefixIcon: const Icon(Icons.search, size: 16),
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 14),
                              onPressed: () => setState(() {
                                _searchController.clear();
                                _query = '';
                              }),
                            ),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: Icon(Icons.note_add_outlined, size: 20, color: scheme.accentColor),
                  tooltip: 'New Note',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                  onPressed: _createNote,
                ),
                PopupMenuButton<String>(
                  tooltip: 'Markdown Import / Export',
                  icon: Icon(Icons.more_vert, size: 18, color: scheme.mutedText),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                  onSelected: (val) {
                    if (val == 'import') {
                      _importMarkdownFiles();
                    } else if (val == 'export_folder') {
                      _exportAllNotesAsMarkdown();
                    } else if (val == 'export_single') {
                      _exportAllNotesAsSingleFile();
                    }
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(
                      value: 'import',
                      child: Row(
                        children: [
                          Icon(Icons.file_upload_outlined, size: 16),
                          SizedBox(width: 8),
                          Text('Import Markdown Files...', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'export_folder',
                      child: Row(
                        children: [
                          Icon(Icons.folder_open_outlined, size: 16),
                          SizedBox(width: 8),
                          Text('Export All to Folder (.md)', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'export_single',
                      child: Row(
                        children: [
                          Icon(Icons.file_download_outlined, size: 16),
                          SizedBox(width: 8),
                          Text('Export All to Single .md', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: notes.isEmpty
                ? Center(
                    child: Text(
                      widget.notes.isEmpty ? 'No notes yet.' : 'No matching notes.',
                      style: TextStyle(color: scheme.mutedText, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    itemCount: notes.length,
                    itemBuilder: (ctx, i) {
                      final n = notes[i];
                      final isSel = n.id == widget.selectedNoteId;
                      return Material(
                        color: isSel ? scheme.panelBackground : Colors.transparent,
                        child: InkWell(
                          onTap: () => widget.onSelectNote(n.id),
                          onSecondaryTap: () => _confirmDelete(n),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                  color: isSel ? scheme.accentColor : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  n.displayTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: scheme.primaryText,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    if (n.linkedTitles.isNotEmpty) ...[
                                      Icon(Icons.link, size: 11, color: scheme.accentColor),
                                      const SizedBox(width: 3),
                                      Flexible(
                                        child: Text(
                                          n.linkedTitles.join(', '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontSize: 10, color: scheme.accentColor),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                    Text(
                                      DateFormat('MMM d, HH:mm').format(n.updatedAt.toLocal()),
                                      style: TextStyle(fontSize: 10, color: scheme.mutedText),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );

    final editor = selected == null
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.sticky_note_2_outlined, size: 48, color: scheme.mutedText),
                const SizedBox(height: 12),
                Text('Select a note or create a new one.', style: TextStyle(color: scheme.mutedText)),
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OutlinedButton.icon(
                      icon: Icon(Icons.note_add_outlined, size: 16, color: scheme.accentColor),
                      label: const Text('New Note'),
                      onPressed: _createNote,
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.file_upload_outlined, size: 16),
                      label: const Text('Import Markdown'),
                      onPressed: _importMarkdownFiles,
                    ),
                  ],
                ),
              ],
            ),
          )
        : NoteEditorPanel(
            note: selected,
            onSave: widget.onSaveNote,
            suggestedLinkTitles: widget.suggestedLinkTitles,
            onDelete: () => _confirmDelete(selected!),
          );

    return Row(
      children: [
        list,
        VerticalDivider(width: 1, thickness: 1, color: scheme.borderColor),
        Expanded(child: editor),
      ],
    );
  }
}
