import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../models/terminal_macro_item.dart';
import '../theme/app_color_schemes.dart';
import 'app_notification.dart';

class MacrosTabWidget extends StatefulWidget {
  final List<TerminalMacroItem> macros;
  final Future<void> Function(TerminalMacroItem item) onSaveMacro;
  final Future<void> Function(String id) onDeleteMacro;

  const MacrosTabWidget({
    super.key,
    required this.macros,
    required this.onSaveMacro,
    required this.onDeleteMacro,
  });

  @override
  State<MacrosTabWidget> createState() => _MacrosTabWidgetState();
}

class _MacrosTabWidgetState extends State<MacrosTabWidget> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _sortBy = 'created'; // 'created', 'updated', 'trigger', 'name'
  String? _copiedId;
  Timer? _copiedResetTimer;

  @override
  void dispose() {
    _copiedResetTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  List<TerminalMacroItem> _getFilteredAndSortedItems() {
    final q = _searchQuery.trim().toLowerCase();
    final filtered = widget.macros.where((item) {
      if (q.isEmpty) return true;
      return item.name.toLowerCase().contains(q) ||
          item.cleanTrigger.toLowerCase().contains(q) ||
          item.replacement.toLowerCase().contains(q);
    }).toList();

    if (_sortBy == 'trigger') {
      filtered.sort((a, b) => a.cleanTrigger.compareTo(b.cleanTrigger));
    } else if (_sortBy == 'name') {
      filtered.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } else if (_sortBy == 'updated') {
      filtered.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    } else {
      filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return filtered;
  }

  Future<void> _copyCommandToClipboard(TerminalMacroItem item) async {
    await Clipboard.setData(ClipboardData(text: item.replacement));
    _copiedResetTimer?.cancel();
    if (mounted) {
      setState(() => _copiedId = item.id);
      AppNotification.show(
        context,
        message: 'Copied replacement command to clipboard.',
        duration: const Duration(seconds: 2),
      );
      _copiedResetTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() => _copiedId = null);
        }
      });
    }
  }

  Future<void> _showAddOrEditDialog([TerminalMacroItem? existing]) async {
    final isEditing = existing != null;
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final triggerCtrl = TextEditingController(
      text: existing != null ? existing.cleanTrigger : '',
    );
    final replacementCtrl = TextEditingController(
      text: existing?.replacement ?? '',
    );
    final secretCtrl = TextEditingController(
      text: existing?.secretValue ?? '',
    );
    bool executeImmediately = existing?.executeImmediately ?? true;
    bool copySecret = existing?.copySecretToClipboard ?? (existing?.secretValue?.isNotEmpty ?? false);
    bool obscureSecret = true;
    int autoClearSeconds = existing?.autoClearClipboardSeconds ?? 60;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final scheme = AppColorScheme.of(context);
          return AlertDialog(
            backgroundColor: scheme.elevatedSurface,
            title: Row(
              children: [
                Icon(Icons.bolt, color: scheme.accentColor, size: 22),
                const SizedBox(width: 8),
                Text(
                  isEditing ? 'Edit Terminal Macro' : 'New Terminal Macro',
                  style: TextStyle(color: scheme.primaryText, fontSize: 16),
                ),
              ],
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      style: TextStyle(color: scheme.primaryText, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'Macro Name / Label',
                        hintText: 'e.g., Send to Nox Server',
                        hintStyle: TextStyle(color: scheme.mutedText),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: triggerCtrl,
                      style: TextStyle(
                        color: scheme.accentColor,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                      decoration: InputDecoration(
                        labelText: 'Trigger Pattern',
                        prefixText: ':: ',
                        prefixStyle: TextStyle(
                          color: scheme.accentColor,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                        hintText: 'send',
                        hintStyle: TextStyle(color: scheme.mutedText),
                        helperText: 'Type ::${triggerCtrl.text.isEmpty ? "trigger" : triggerCtrl.text.replaceFirst(RegExp(r"^:+"), "")} in any shell to invoke',
                        helperStyle: TextStyle(color: scheme.mutedText, fontSize: 11),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: replacementCtrl,
                      minLines: 2,
                      maxLines: 5,
                      style: TextStyle(
                        color: scheme.primaryText,
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                      decoration: InputDecoration(
                        labelText: 'Replacement Command',
                        hintText: 'e.g., scp -oHostKeyAlgorithms=+ssh-rsa {1} rhamby@nox.esilibrary.com:~/temp/',
                        hintStyle: TextStyle(color: scheme.mutedText),
                        helperText: 'Placeholders: {1}, {2}, {args}, or {file} are replaced with arguments',
                        helperStyle: TextStyle(color: scheme.mutedText, fontSize: 11),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        'Execute immediately on Enter',
                        style: TextStyle(color: scheme.primaryText, fontSize: 13),
                      ),
                      subtitle: Text(
                        executeImmediately
                            ? 'Runs command automatically when pressing Enter'
                            : 'Expands onto shell prompt for review before running',
                        style: TextStyle(color: scheme.mutedText, fontSize: 11),
                      ),
                      value: executeImmediately,
                      activeColor: scheme.accentColor,
                      onChanged: (val) => setDialogState(() => executeImmediately = val),
                    ),
                    const Divider(height: 20),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        'Auto-copy Password / Secret to Clipboard',
                        style: TextStyle(color: scheme.primaryText, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        'Copies password to memory upon trigger and clears it after $autoClearSeconds seconds',
                        style: TextStyle(color: scheme.mutedText, fontSize: 11),
                      ),
                      value: copySecret,
                      activeColor: scheme.accentColor,
                      onChanged: (val) {
                        setDialogState(() {
                          copySecret = val ?? false;
                        });
                      },
                    ),
                    if (copySecret) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: secretCtrl,
                        obscureText: obscureSecret,
                        style: TextStyle(
                          color: scheme.primaryText,
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Password / Secret Value',
                          hintText: 'Enter password to inject into clipboard...',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          suffixIcon: IconButton(
                            icon: Icon(
                              obscureSecret ? Icons.visibility_off : Icons.visibility,
                              size: 18,
                            ),
                            onPressed: () => setDialogState(() => obscureSecret = !obscureSecret),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final triggerText = triggerCtrl.text.trim();
                  final replacementText = replacementCtrl.text.trim();
                  if (triggerText.isEmpty || replacementText.isEmpty) {
                    AppNotification.show(
                      context,
                      message: 'Trigger and Replacement cannot be empty.',
                      duration: const Duration(seconds: 2),
                    );
                    return;
                  }

                  final item = TerminalMacroItem(
                    id: existing?.id ?? const Uuid().v4(),
                    name: nameCtrl.text.trim().isNotEmpty
                        ? nameCtrl.text.trim()
                        : '::${triggerText.replaceFirst(RegExp(r"^:+"), "")}',
                    trigger: triggerText,
                    replacement: replacementText,
                    executeImmediately: executeImmediately,
                    copySecretToClipboard: copySecret && secretCtrl.text.isNotEmpty,
                    secretValue: copySecret && secretCtrl.text.isNotEmpty ? secretCtrl.text : null,
                    autoClearClipboardSeconds: autoClearSeconds,
                    createdAt: existing?.createdAt,
                  );

                  await widget.onSaveMacro(item);
                  if (mounted) Navigator.of(ctx).pop();
                },
                child: Text(isEditing ? 'Save Changes' : 'Create Macro'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(TerminalMacroItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Macro?'),
        content: Text('Are you sure you want to delete "${item.name}" (${item.formattedTrigger})?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.onDeleteMacro(item.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = AppColorScheme.of(context);
    final items = _getFilteredAndSortedItems();

    return Column(
      children: [
        // Header Bar
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
                      Icon(Icons.bolt, color: scheme.accentColor, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Terminal Macros (${widget.macros.length})',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: scheme.primaryText,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.accentColor.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Type ::trigger in any shell',
                          style: TextStyle(fontSize: 11, color: scheme.accentColor),
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
                            hintText: 'Filter macros...',
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
                          Text('Sort: ', style: TextStyle(fontSize: 12, color: scheme.mutedText)),
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
                              DropdownMenuItem(value: 'trigger', child: Text('Trigger (A-Z)')),
                              DropdownMenuItem(value: 'name', child: Text('Name (A-Z)')),
                            ],
                            onChanged: (val) {
                              if (val != null) setState(() => _sortBy = val);
                            },
                          ),
                        ],
                      ),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('New Macro'),
                        onPressed: () => _showAddOrEditDialog(),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),

        // List Body
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bolt_outlined, size: 56, color: scheme.mutedText),
                      const SizedBox(height: 12),
                      Text(
                        _searchQuery.isNotEmpty
                            ? 'No macros match "$_searchQuery".'
                            : 'No macros yet. Create a macro above (e.g. ::send) to auto-expand commands and copy passwords!',
                        style: TextStyle(color: scheme.mutedText),
                      ),
                      const SizedBox(height: 16),
                      if (_searchQuery.isEmpty)
                        ElevatedButton.icon(
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Create First Macro'),
                          onPressed: () => _showAddOrEditDialog(),
                        ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: items.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final isCopied = _copiedId == item.id;

                    return Card(
                      color: scheme.panelBackground,
                      shape: RoundedRectangleBorder(
                        side: BorderSide(color: scheme.borderColor),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Trigger Pill
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: scheme.accentColor.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: scheme.accentColor.withOpacity(0.4)),
                              ),
                              child: Text(
                                item.formattedTrigger,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.bold,
                                  color: scheme.accentColor,
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),

                            // Main Details
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [
                                      Text(
                                        item.name,
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: scheme.primaryText,
                                        ),
                                      ),
                                      if (item.executeImmediately)
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                          decoration: BoxDecoration(
                                            color: Colors.green.withOpacity(0.15),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: const Text(
                                            'Auto-Run',
                                            style: TextStyle(fontSize: 10, color: Colors.greenAccent),
                                          ),
                                        )
                                      else
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                          decoration: BoxDecoration(
                                            color: Colors.blue.withOpacity(0.15),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: const Text(
                                            'Review on Prompt',
                                            style: TextStyle(fontSize: 10, color: Colors.lightBlueAccent),
                                          ),
                                        ),
                                      if (item.copySecretToClipboard && item.secretValue != null) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                          decoration: BoxDecoration(
                                            color: Colors.amber.withOpacity(0.15),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(Icons.lock, size: 10, color: Colors.amberAccent),
                                              const SizedBox(width: 3),
                                              Text(
                                                'Password (${item.autoClearClipboardSeconds}s clear)',
                                                style: const TextStyle(fontSize: 10, color: Colors.amberAccent),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  SelectableText(
                                    item.replacement,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                      color: scheme.primaryText.withOpacity(0.9),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // Actions
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(
                                    isCopied ? Icons.check : Icons.copy,
                                    size: 16,
                                    color: isCopied ? Colors.greenAccent : scheme.mutedText,
                                  ),
                                  tooltip: 'Copy command',
                                  onPressed: () => _copyCommandToClipboard(item),
                                ),
                                IconButton(
                                  icon: Icon(Icons.edit_outlined, size: 16, color: scheme.mutedText),
                                  tooltip: 'Edit Macro',
                                  onPressed: () => _showAddOrEditDialog(item),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                                  tooltip: 'Delete Macro',
                                  onPressed: () => _confirmDelete(item),
                                ),
                              ],
                            ),
                          ],
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
