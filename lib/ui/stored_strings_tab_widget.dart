import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../models/stored_string_item.dart';
import '../theme/app_color_schemes.dart';

class StoredStringsTabWidget extends StatefulWidget {
  final List<StoredStringItem> storedStrings;
  final Future<void> Function(StoredStringItem item) onSaveStoredString;
  final Future<void> Function(String id) onDeleteStoredString;

  const StoredStringsTabWidget({
    super.key,
    required this.storedStrings,
    required this.onSaveStoredString,
    required this.onDeleteStoredString,
  });

  @override
  State<StoredStringsTabWidget> createState() => _StoredStringsTabWidgetState();
}

class _StoredStringsTabWidgetState extends State<StoredStringsTabWidget> {
  final TextEditingController _labelController = TextEditingController();
  final TextEditingController _valueController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _sortBy = 'created'; // 'created', 'updated', 'label'
  String? _copiedId;
  Timer? _copiedResetTimer;

  @override
  void dispose() {
    _copiedResetTimer?.cancel();
    _labelController.dispose();
    _valueController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  static String normalizeMultilineValue(String raw) {
    return raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  Future<void> _handleAddString() async {
    final normalized = normalizeMultilineValue(_valueController.text);
    if (normalized.trim().isEmpty) return;

    final label = _labelController.text.trim();
    final item = StoredStringItem(
      id: const Uuid().v4(),
      label: label,
      value: normalized,
    );

    await widget.onSaveStoredString(item);

    if (mounted) {
      setState(() {
        _labelController.clear();
        _valueController.clear();
      });
    }
  }

  Future<void> _copyToClipboard(StoredStringItem item) async {
    await Clipboard.setData(ClipboardData(text: item.value));
    _copiedResetTimer?.cancel();
    if (mounted) {
      setState(() {
        _copiedId = item.id;
      });
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            item.label.isNotEmpty
                ? 'Copied "${item.label}" to clipboard.'
                : 'Copied string to clipboard.',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
      _copiedResetTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() {
            _copiedId = null;
          });
        }
      });
    }
  }

  Future<void> _showEditDialog(StoredStringItem item) async {
    final labelCtrl = TextEditingController(text: item.label);
    final valueCtrl = TextEditingController(text: item.value);

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Stored String'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: labelCtrl,
                decoration: const InputDecoration(
                  labelText: 'Label / Description (Optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: valueCtrl,
                autofocus: true,
                maxLines: 8,
                minLines: 2,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'String Value',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newValue = normalizeMultilineValue(valueCtrl.text);
              if (newValue.trim().isEmpty) return;
              item.label = labelCtrl.text.trim();
              item.value = newValue;
              await widget.onSaveStoredString(item);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  List<StoredStringItem> _getFilteredAndSortedItems() {
    final q = _searchQuery.trim().toLowerCase();
    final filtered = widget.storedStrings.where((item) {
      if (q.isEmpty) return true;
      return item.label.toLowerCase().contains(q) ||
          item.value.toLowerCase().contains(q);
    }).toList();

    if (_sortBy == 'label') {
      filtered.sort((a, b) {
        final aKey = a.label.isNotEmpty ? a.label.toLowerCase() : a.value.toLowerCase();
        final bKey = b.label.isNotEmpty ? b.label.toLowerCase() : b.value.toLowerCase();
        return aKey.compareTo(bKey);
      });
    } else if (_sortBy == 'updated') {
      filtered.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    } else {
      filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = AppColorScheme.of(context);
    final items = _getFilteredAndSortedItems();

    return Column(
      children: [
        // Top Header & Add Stored String Bar
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.panelBackground,
            border: Border(bottom: BorderSide(color: scheme.borderColor)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.content_paste, color: scheme.accentColor, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Pasteboard (${widget.storedStrings.length})',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: scheme.primaryText,
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 200,
                        child: TextField(
                          controller: _searchController,
                          style: const TextStyle(fontSize: 12),
                          decoration: InputDecoration(
                            hintText: 'Filter strings...',
                            isDense: true,
                            prefixIcon: const Icon(Icons.search, size: 15),
                            prefixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 28),
                            suffixIcon: _searchQuery.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear, size: 14),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() => _searchQuery = '');
                                    },
                                  )
                                : null,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            border: const OutlineInputBorder(),
                          ),
                          onChanged: (val) => setState(() => _searchQuery = val),
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Sort by: ', style: TextStyle(fontSize: 12, color: scheme.mutedText)),
                          const SizedBox(width: 4),
                          DropdownButton<String>(
                            value: _sortBy,
                            isDense: true,
                            underline: const SizedBox.shrink(),
                            style: TextStyle(fontSize: 12, color: scheme.primaryText),
                            dropdownColor: scheme.elevatedSurface,
                            items: const [
                              DropdownMenuItem(value: 'created', child: Text('Newest First')),
                              DropdownMenuItem(value: 'updated', child: Text('Recently Updated')),
                              DropdownMenuItem(value: 'label', child: Text('Alphabetical')),
                            ],
                            onChanged: (val) {
                              if (val != null) setState(() => _sortBy = val);
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Quick Add String Row
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 200,
                    child: TextField(
                      controller: _labelController,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        hintText: 'Label (optional)...',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _handleAddString(),
                    ),
                  ),
                  SizedBox(
                    width: 360,
                    child: TextField(
                      controller: _valueController,
                      minLines: 1,
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                      decoration: const InputDecoration(
                        hintText: 'String to store for quick copy...',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add String'),
                    onPressed: _handleAddString,
                  ),
                ],
              ),
            ],
          ),
        ),

        // Stored Strings List Body
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.content_paste_off_outlined, size: 52, color: scheme.mutedText),
                      const SizedBox(height: 12),
                      Text(
                        _searchQuery.isNotEmpty
                            ? 'No stored strings match "$_searchQuery".'
                            : 'No stored strings yet. Add a string above to click and copy it to the clipboard anytime.',
                        style: TextStyle(color: scheme.mutedText),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: items.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final isCopied = _copiedId == item.id;

                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _copyToClipboard(item),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: scheme.panelBackground,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isCopied
                                  ? Colors.greenAccent.withAlpha(180)
                                  : scheme.borderColor,
                            ),
                          ),
                          child: Row(
                            children: [
                              Tooltip(
                                message: 'Click to copy to clipboard',
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: isCopied
                                        ? Colors.greenAccent.withAlpha(35)
                                        : scheme.elevatedSurface,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Icon(
                                    isCopied ? Icons.check : Icons.copy,
                                    size: 16,
                                    color: isCopied ? Colors.greenAccent : scheme.accentColor,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (item.label.isNotEmpty) ...[
                                      Text(
                                        item.label,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: scheme.accentColor,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                    ],
                                    Text(
                                      item.value,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontFamily: 'monospace',
                                        color: scheme.primaryText,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton.icon(
                                icon: Icon(
                                  isCopied ? Icons.check : Icons.copy,
                                  size: 14,
                                  color: isCopied ? Colors.greenAccent : scheme.accentColor,
                                ),
                                label: Text(
                                  isCopied ? 'Copied!' : 'Copy',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isCopied ? Colors.greenAccent : scheme.primaryText,
                                  ),
                                ),
                                onPressed: () => _copyToClipboard(item),
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: Icon(Icons.edit_outlined, size: 16, color: scheme.mutedText),
                                tooltip: 'Edit String',
                                onPressed: () => _showEditDialog(item),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                                tooltip: 'Delete String',
                                onPressed: () => widget.onDeleteStoredString(item.id),
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
    );
  }
}
