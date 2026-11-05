import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../models/stored_string_item.dart';
import '../models/special_character_item.dart';
import '../theme/app_color_schemes.dart';
import 'app_notification.dart';

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

  static String normalizeMultilineValue(String raw) {
    // Preserve standalone \r (Carriage Return) while standardizing Windows CRLF
    return raw.replaceAll('\r\n', '\n');
  }

  static String formatDisplayValue(String val) {
    if (val == '\r') return '^M (Carriage Return / CR)';
    if (val == '\n') return '^J (Line Feed / LF)';
    if (val == '\r\n') return '^M^J (CRLF)';
    if (val == '\t') return '^I (Tab)';
    if (val == '\x1b') return '^[ (Escape / ESC)';
    if (val == '\x16') return '^V (Literal Next / LNEXT)';
    if (val == '\x00') return '^@ (Null / NUL)';
    if (val == '\x03') return '^C (Interrupt / ETX)';
    if (val == '\x04') return '^D (End of File / EOT)';
    if (val == '\x1a') return '^Z (Suspend / SUB)';
    if (val == '\x0c') return '^L (Form Feed / FF)';
    if (val == '\x08') return '^H (Backspace / BS)';
    if (val == '\x7f') return '^? (Delete / DEL)';
    if (val == '\u200B') return 'ZWSP (Zero-Width Space)';
    if (val == '\u00A0') return 'NBSP (Non-Breaking Space)';

    final clean = val.replaceAll('\r\n', ' ').replaceAll('\n', ' ').replaceAll('\t', ' ');
    if (clean.trim().isEmpty && val.isNotEmpty) {
      return val.codeUnits.map((c) => '0x${c.toRadixString(16).padLeft(2, "0").toUpperCase()}').join(' ');
    }
    return val;
  }

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
  String? _copiedSpecialSymbol;
  Timer? _copiedSpecialTimer;
  int _activeViewIndex = 0; // 0: My Strings, 1: Special Characters

  @override
  void dispose() {
    _copiedResetTimer?.cancel();
    _copiedSpecialTimer?.cancel();
    _labelController.dispose();
    _valueController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _handleAddString() async {
    final normalized = StoredStringsTabWidget.normalizeMultilineValue(_valueController.text);
    if (normalized.isEmpty) return;

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
      AppNotification.show(
        context,
        message: item.label.isNotEmpty
            ? 'Copied "${item.label}" to clipboard.'
            : 'Copied string to clipboard.',
        duration: const Duration(seconds: 2),
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

  Future<void> _copySpecialCharacter(SpecialCharacterItem item) async {
    await Clipboard.setData(ClipboardData(text: item.value));
    _copiedSpecialTimer?.cancel();
    if (mounted) {
      setState(() {
        _copiedSpecialSymbol = item.symbol;
      });
      AppNotification.show(
        context,
        message: 'Copied ${item.symbol} (${item.name}) to clipboard.',
        duration: const Duration(seconds: 2),
      );
      _copiedSpecialTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() {
            _copiedSpecialSymbol = null;
          });
        }
      });
    }
  }

  Future<void> _saveSpecialToPasteboard(SpecialCharacterItem item) async {
    final newItem = StoredStringItem(
      id: const Uuid().v4(),
      label: '${item.symbol} ${item.name} (${item.abbreviation})',
      value: item.value,
    );
    await widget.onSaveStoredString(newItem);
    if (mounted) {
      AppNotification.show(
        context,
        message: 'Saved "${item.symbol} ${item.name}" to your Pasteboard strings.',
        duration: const Duration(seconds: 2),
      );
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
              final newValue = StoredStringsTabWidget.normalizeMultilineValue(valueCtrl.text);
              if (newValue.isEmpty) return;
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

  List<SpecialCharacterItem> _getFilteredSpecialCharacters() {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return SpecialCharacterItem.common;
    return SpecialCharacterItem.common.where((item) {
      return item.symbol.toLowerCase().contains(q) ||
          item.name.toLowerCase().contains(q) ||
          item.abbreviation.toLowerCase().contains(q) ||
          item.hexCode.toLowerCase().contains(q) ||
          item.description.toLowerCase().contains(q);
    }).toList();
  }

  Widget _buildQuickSpecialChips(AppColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.panelBackground.withAlpha(200),
        border: Border(bottom: BorderSide(color: scheme.borderColor)),
      ),
      child: Row(
        children: [
          Icon(Icons.keyboard_outlined, size: 15, color: scheme.accentColor),
          const SizedBox(width: 8),
          Text(
            'Quick Control Characters:',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: scheme.mutedText,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: SpecialCharacterItem.common.map((item) {
                  final isCopied = _copiedSpecialSymbol == item.symbol;
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Tooltip(
                      message: '${item.name} (${item.abbreviation} / ${item.hexCode})\n${item.description}\nClick to copy',
                      child: InkWell(
                        onTap: () => _copySpecialCharacter(item),
                        borderRadius: BorderRadius.circular(5),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: isCopied
                                ? Colors.greenAccent.withAlpha(40)
                                : scheme.elevatedSurface,
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: isCopied
                                  ? Colors.greenAccent
                                  : scheme.borderColor,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                item.symbol,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'monospace',
                                  color: isCopied
                                      ? Colors.greenAccent
                                      : scheme.accentColor,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                item.abbreviation,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: isCopied ? Colors.greenAccent : scheme.mutedText,
                                ),
                              ),
                              if (isCopied) ...[
                                const SizedBox(width: 4),
                                const Icon(Icons.check, size: 12, color: Colors.greenAccent),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpecialCharactersList(AppColorScheme scheme) {
    final items = _getFilteredSpecialCharacters();

    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_outlined, size: 52, color: scheme.mutedText),
            const SizedBox(height: 12),
            Text(
              'No special characters match "$_searchQuery".',
              style: TextStyle(color: scheme.mutedText),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      separatorBuilder: (context, index) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final item = items[index];
        final isCopied = _copiedSpecialSymbol == item.symbol;

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _copySpecialCharacter(item),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                  Container(
                    width: 48,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isCopied
                          ? Colors.greenAccent.withAlpha(35)
                          : scheme.elevatedSurface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isCopied
                            ? Colors.greenAccent
                            : scheme.accentColor.withAlpha(120),
                      ),
                    ),
                    child: Text(
                      item.symbol,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        color: isCopied ? Colors.greenAccent : scheme.accentColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              item.name,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: scheme.primaryText,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: scheme.elevatedSurface,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '${item.abbreviation} • ${item.hexCode}',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                  color: scheme.mutedText,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          item.description,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.mutedText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
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
                    onPressed: () => _copySpecialCharacter(item),
                  ),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: 'Save to My Pasteboard Strings',
                    child: IconButton(
                      icon: Icon(Icons.bookmark_add_outlined, size: 18, color: scheme.accentColor),
                      onPressed: () => _saveSpecialToPasteboard(item),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = AppColorScheme.of(context);
    final myItems = _getFilteredAndSortedItems();
    final specialItems = _getFilteredSpecialCharacters();

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
                        'Pasteboard',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: scheme.primaryText,
                        ),
                      ),
                      const SizedBox(width: 16),
                      // View Toggle
                      Container(
                        decoration: BoxDecoration(
                          color: scheme.elevatedSurface,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: scheme.borderColor),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            InkWell(
                              onTap: () => setState(() => _activeViewIndex = 0),
                              borderRadius: const BorderRadius.horizontal(left: Radius.circular(5)),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: _activeViewIndex == 0
                                      ? scheme.accentColor.withAlpha(45)
                                      : Colors.transparent,
                                  borderRadius: const BorderRadius.horizontal(left: Radius.circular(5)),
                                ),
                                child: Text(
                                  'My Strings (${widget.storedStrings.length})',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: _activeViewIndex == 0 ? FontWeight.bold : FontWeight.normal,
                                    color: _activeViewIndex == 0 ? scheme.accentColor : scheme.primaryText,
                                  ),
                                ),
                              ),
                            ),
                            Container(width: 1, height: 18, color: scheme.borderColor),
                            InkWell(
                              onTap: () => setState(() => _activeViewIndex = 1),
                              borderRadius: const BorderRadius.horizontal(right: Radius.circular(5)),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: _activeViewIndex == 1
                                      ? scheme.accentColor.withAlpha(45)
                                      : Colors.transparent,
                                  borderRadius: const BorderRadius.horizontal(right: Radius.circular(5)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'Special Characters (${SpecialCharacterItem.common.length})',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: _activeViewIndex == 1 ? FontWeight.bold : FontWeight.normal,
                                        color: _activeViewIndex == 1 ? scheme.accentColor : scheme.primaryText,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
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
                        width: 220,
                        child: TextField(
                          controller: _searchController,
                          style: const TextStyle(fontSize: 12),
                          decoration: InputDecoration(
                            hintText: _activeViewIndex == 0 ? 'Filter strings...' : 'Filter special characters (e.g. ^M, CR, tab)...',
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
                      if (_activeViewIndex == 0)
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
              if (_activeViewIndex == 0) ...[
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
            ],
          ),
        ),

        // Quick Control Characters Bar
        _buildQuickSpecialChips(scheme),

        // Stored Strings List Body OR Special Characters List Body
        Expanded(
          child: _activeViewIndex == 1
              ? _buildSpecialCharactersList(scheme)
              : (myItems.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.content_paste_off_outlined, size: 52, color: scheme.mutedText),
                          const SizedBox(height: 12),
                          Text(
                            _searchQuery.isNotEmpty
                                ? 'No stored strings match "$_searchQuery".'
                                : 'No custom stored strings yet. Add a string above or copy special characters anytime.',
                            style: TextStyle(color: scheme.mutedText),
                          ),
                          if (_searchQuery.isNotEmpty && specialItems.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            TextButton.icon(
                              icon: const Icon(Icons.arrow_forward, size: 14),
                              label: Text('View ${specialItems.length} matching special character(s)'),
                              onPressed: () => setState(() => _activeViewIndex = 1),
                            ),
                          ],
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: myItems.length,
                      separatorBuilder: (context, index) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final item = myItems[index];
                        final isCopied = _copiedId == item.id;
                        final displayVal = StoredStringsTabWidget.formatDisplayValue(item.value);

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
                                          displayVal,
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
                    )),
        ),
      ],
    );
  }
}
