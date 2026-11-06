import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../models/note_item.dart';
import '../theme/app_color_schemes.dart';

/// Reusable plain-text note editor.
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

  @override
  Widget build(BuildContext context) {
    final scheme = AppColorScheme.of(context);
    final note = widget.note;
    final lineCount = _contentController.text.isEmpty
        ? 0
        : '\n'.allMatches(_contentController.text).length + 1;

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

          // Body
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 0),
              child: TextField(
                controller: _contentController,
                focusNode: _contentFocus,
                expands: true,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                textAlignVertical: TextAlignVertical.top,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.35,
                  color: scheme.primaryText,
                ),
                decoration: InputDecoration(
                  hintText: 'Start typing...',
                  hintStyle: TextStyle(color: scheme.mutedText, fontFamily: 'monospace'),
                  border: InputBorder.none,
                ),
                onChanged: (v) {
                  note.content = v;
                  _markDirty();
                  setState(() {}); // refresh line/char counts
                },
              ),
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
      width: 260,
      color: scheme.scaffoldBackground,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(fontSize: 12),
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
                const SizedBox(width: 6),
                IconButton(
                  icon: Icon(Icons.note_add_outlined, size: 20, color: scheme.accentColor),
                  tooltip: 'New Note',
                  onPressed: _createNote,
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
                OutlinedButton.icon(
                  icon: Icon(Icons.note_add_outlined, size: 16, color: scheme.accentColor),
                  label: const Text('New Note'),
                  onPressed: _createNote,
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
