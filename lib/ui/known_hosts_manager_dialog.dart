import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../services/known_hosts_service.dart';
import 'app_notification.dart';

/// Management dialog to review, inspect, and delete remembered SSH host keys.
class KnownHostsManagerDialog extends StatefulWidget {
  final KnownHostsService knownHostsService;

  const KnownHostsManagerDialog({
    super.key,
    required this.knownHostsService,
  });

  static Future<void> show(
    BuildContext context, {
    KnownHostsService? knownHostsService,
  }) async {
    await showDialog(
      context: context,
      builder: (ctx) => KnownHostsManagerDialog(
        knownHostsService: knownHostsService ?? KnownHostsService.instance,
      ),
    );
  }

  @override
  State<KnownHostsManagerDialog> createState() => _KnownHostsManagerDialogState();
}

class _KnownHostsManagerDialogState extends State<KnownHostsManagerDialog> {
  List<KnownHostEntry> _hosts = [];
  bool _isLoading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadHosts();
  }

  Future<void> _loadHosts() async {
    setState(() => _isLoading = true);
    final hosts = await widget.knownHostsService.getKnownHosts();
    if (mounted) {
      setState(() {
        _hosts = hosts;
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteEntry(KnownHostEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF14110E),
        title: const Text('Remove Host Key', style: TextStyle(color: Color(0xFFE6D5BB))),
        content: Text(
          'Remove trusted ${entry.keyType} key for ${entry.host}:${entry.port}?\n\n'
          'You will be prompted to re-verify the fingerprint the next time you connect.',
          style: const TextStyle(color: Color(0xFFC9B89D), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF8F7F69))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await widget.knownHostsService.removeHostKey(
        host: entry.host,
        port: entry.port,
        keyType: entry.keyType,
      );
      if (mounted) {
        AppNotification.show(
          context,
          message: 'Removed ${entry.host}:${entry.port} (${entry.keyType}) from known hosts',
          isSuccess: true,
        );
        _loadHosts();
      }
    }
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF14110E),
        title: const Text('Clear All Known Hosts?', style: TextStyle(color: Colors.redAccent)),
        content: const Text(
          'Are you sure you want to delete all stored known host keys?\n\n'
          'You will be prompted to re-verify all servers on your next connections.',
          style: TextStyle(color: Color(0xFFC9B89D), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF8F7F69))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await widget.knownHostsService.clearAll();
      if (mounted) {
        AppNotification.show(
          context,
          message: 'All known hosts cleared',
          isSuccess: true,
        );
        _loadHosts();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _hosts.where((h) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return h.host.toLowerCase().contains(q) ||
          h.keyType.toLowerCase().contains(q) ||
          h.fingerprint.toLowerCase().contains(q);
    }).toList();

    final dateFormat = DateFormat('yyyy-MM-dd HH:mm');

    return AlertDialog(
      backgroundColor: const Color(0xFF14110E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF3C2C1F)),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      actionsPadding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      title: Row(
        children: [
          const Icon(Icons.security, color: Color(0xFFE6D5BB), size: 22),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Known Host Keys (MITM Protection)',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFFE6D5BB),
              ),
            ),
          ),
          if (_hosts.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined, size: 20),
              tooltip: 'Clear All Known Hosts',
              color: Colors.redAccent.withOpacity(0.8),
              onPressed: _clearAll,
            ),
        ],
      ),
      content: SizedBox(
        width: 620,
        height: 480,
        child: Column(
          children: [
            TextField(
              decoration: InputDecoration(
                hintText: 'Filter by host, key type, or fingerprint...',
                prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF8F7F69)),
                filled: true,
                fillColor: const Color(0xFF0A0806),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF3C2C1F)),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onChanged: (q) => setState(() => _searchQuery = q.trim()),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : filtered.isEmpty
                      ? Center(
                          child: Text(
                            _hosts.isEmpty
                                ? 'No known host keys stored yet.\nKeys are saved when connecting to verified servers.'
                                : 'No matching host keys found.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Color(0xFF8F7F69), fontSize: 13),
                          ),
                        )
                      : ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (context, index) => const Divider(color: Color(0xFF2A1F16), height: 1),
                          itemBuilder: (ctx, index) {
                            final entry = filtered[index];
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                              title: Row(
                                children: [
                                  Text(
                                    '${entry.host}:${entry.port}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFFE6D5BB),
                                      fontSize: 13.5,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF3C2C1F),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      entry.keyType,
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        color: Color(0xFFB57A4C),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: SelectableText(
                                          entry.fingerprint,
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 11,
                                            color: Color(0xFFC9B89D),
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.copy_outlined, size: 14),
                                        tooltip: 'Copy Fingerprint',
                                        color: const Color(0xFF8F7F69),
                                        onPressed: () {
                                          Clipboard.setData(ClipboardData(text: entry.fingerprint));
                                          AppNotification.show(
                                            context,
                                            message: 'Fingerprint copied',
                                            isSuccess: true,
                                            duration: const Duration(seconds: 2),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                  Text(
                                    'Last verified: ${dateFormat.format(entry.lastSeen.toLocal())}',
                                    style: const TextStyle(fontSize: 10.5, color: Color(0xFF8F7F69)),
                                  ),
                                ],
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline, size: 18),
                                color: Colors.redAccent.withOpacity(0.7),
                                tooltip: 'Remove Key',
                                onPressed: () => _deleteEntry(entry),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close', style: TextStyle(color: Color(0xFFE6D5BB))),
        ),
      ],
    );
  }
}
