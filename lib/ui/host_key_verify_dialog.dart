import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/server_config.dart';
import 'app_notification.dart';

class HostKeyVerifyDialog extends StatefulWidget {
  final ServerConfig server;
  final String keyType;
  final String fingerprint;
  final bool isMismatch;
  final String? previousFingerprint;

  const HostKeyVerifyDialog({
    super.key,
    required this.server,
    required this.keyType,
    required this.fingerprint,
    required this.isMismatch,
    this.previousFingerprint,
  });

  /// Displays the host key verification dialog.
  ///
  /// Returns `true` if the user trusts and confirms the host key, or `false`
  /// if the connection should be aborted.
  static Future<bool> show(
    BuildContext context, {
    required ServerConfig server,
    required String keyType,
    required String fingerprint,
    required bool isMismatch,
    String? previousFingerprint,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => HostKeyVerifyDialog(
        server: server,
        keyType: keyType,
        fingerprint: fingerprint,
        isMismatch: isMismatch,
        previousFingerprint: previousFingerprint,
      ),
    );
    return result ?? false;
  }

  @override
  State<HostKeyVerifyDialog> createState() => _HostKeyVerifyDialogState();
}

class _HostKeyVerifyDialogState extends State<HostKeyVerifyDialog> {
  bool _acknowledgeMitmRisk = false;

  void _copyToClipboard(BuildContext context, String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    AppNotification.show(
      context,
      message: '$label copied to clipboard',
      isSuccess: true,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMismatch = widget.isMismatch;
    final server = widget.server;

    return AlertDialog(
      backgroundColor: const Color(0xFF14110E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isMismatch ? Colors.redAccent.withOpacity(0.6) : const Color(0xFF8A5631).withOpacity(0.5),
          width: isMismatch ? 1.5 : 1,
        ),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      title: Row(
        children: [
          Icon(
            isMismatch ? Icons.gpp_bad : Icons.shield_outlined,
            color: isMismatch ? Colors.redAccent : const Color(0xFFE6D5BB),
            size: 26,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isMismatch
                  ? 'REMOTE HOST IDENTIFICATION CHANGED!'
                  : 'Verify Host Authenticity',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: isMismatch ? Colors.redAccent : const Color(0xFFE6D5BB),
                letterSpacing: 0.2,
              ),
            ),
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
              if (isMismatch) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.redAccent.withOpacity(0.35)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'POTENTIAL SECURITY BREACH / MAN-IN-THE-MIDDLE ATTACK DETECTED!\n\n'
                          'The host key presented by ${server.host}:${server.port} does NOT match the key previously stored in your known hosts. '
                          'Someone may be eavesdropping on or impersonating this server.',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFFCA5A5),
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ] else ...[
                Text(
                  'You are connecting to "${server.name}" (${server.host}:${server.port}) for the first time. '
                  'Compare the fingerprint below with your server console before trusting.',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFFC9B89D),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Host Details Table
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0806),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF3C2C1F)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildRow('Target Host', '${server.host}:${server.port}'),
                    const Divider(color: Color(0xFF2A1F16), height: 16),
                    _buildRow('Key Algorithm', widget.keyType),
                    if (isMismatch && widget.previousFingerprint != null) ...[
                      const Divider(color: Color(0xFF2A1F16), height: 16),
                      _buildRow(
                        'Previous Key',
                        widget.previousFingerprint!,
                        valueColor: const Color(0xFF8F7F69),
                        onCopy: () => _copyToClipboard(context, widget.previousFingerprint!, 'Previous key'),
                      ),
                    ],
                    const Divider(color: Color(0xFF2A1F16), height: 16),
                    _buildRow(
                      isMismatch ? 'New Received Key' : 'Fingerprint',
                      widget.fingerprint,
                      valueColor: isMismatch ? Colors.redAccent : const Color(0xFFE6D5BB),
                      isHighlight: true,
                      onCopy: () => _copyToClipboard(context, widget.fingerprint, 'Fingerprint'),
                    ),
                  ],
                ),
              ),

              if (isMismatch) ...[
                const SizedBox(height: 16),
                InkWell(
                  onTap: () {
                    setState(() {
                      _acknowledgeMitmRisk = !_acknowledgeMitmRisk;
                    });
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Checkbox(
                          value: _acknowledgeMitmRisk,
                          activeColor: Colors.redAccent,
                          onChanged: (val) {
                            setState(() {
                              _acknowledgeMitmRisk = val ?? false;
                            });
                          },
                        ),
                        const Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(
                              'I acknowledge the security risk and verify that the server host key was legitimately rotated. Replace the trusted key with this new fingerprint.',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFFC9B89D),
                                height: 1.35,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (isMismatch) ...[
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: _acknowledgeMitmRisk ? Colors.redAccent : Colors.grey,
              side: BorderSide(
                color: _acknowledgeMitmRisk ? Colors.redAccent : Colors.grey.withOpacity(0.3),
              ),
            ),
            onPressed: _acknowledgeMitmRisk
                ? () => Navigator.of(context).pop(true)
                : null,
            child: const Text('Replace Key & Continue'),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.block, size: 16),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(false),
            label: const Text('Abort Connection (Recommended)'),
          ),
        ] else ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFC9B89D),
            ),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.check, size: 16),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE6D5BB),
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            label: const Text('Trust & Connect'),
          ),
        ],
      ],
    );
  }

  Widget _buildRow(
    String label,
    String value, {
    Color? valueColor,
    bool isHighlight = false,
    VoidCallback? onCopy,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF8F7F69),
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              fontWeight: isHighlight ? FontWeight.bold : FontWeight.normal,
              color: valueColor ?? const Color(0xFFC9B89D),
            ),
          ),
        ),
        if (onCopy != null)
          IconButton(
            icon: const Icon(Icons.copy_outlined, size: 14),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: 'Copy',
            color: const Color(0xFF8F7F69),
            onPressed: onCopy,
          ),
      ],
    );
  }
}
