import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum HostKeyStatus {
  /// The host key is already known and matches the stored fingerprint.
  trusted,

  /// First time connecting to this host (or key type). Trust On First Use (TOFU).
  unknown,

  /// The host is known, but the received fingerprint DOES NOT MATCH.
  /// Potential Man-In-The-Middle (MITM) attack!
  mismatch,
}

class HostKeyVerificationResult {
  final HostKeyStatus status;
  final String host;
  final int port;
  final String keyType;
  final String fingerprint;
  final String? previousFingerprint;
  final KnownHostEntry? entry;

  const HostKeyVerificationResult({
    required this.status,
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    this.previousFingerprint,
    this.entry,
  });

  bool get isTrusted => status == HostKeyStatus.trusted;
  bool get isUnknown => status == HostKeyStatus.unknown;
  bool get isMismatch => status == HostKeyStatus.mismatch;
}

class KnownHostEntry {
  final String host;
  final int port;
  final String keyType;
  final String fingerprint;
  final DateTime firstSeen;
  final DateTime lastSeen;

  KnownHostEntry({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    DateTime? firstSeen,
    DateTime? lastSeen,
  })  : firstSeen = firstSeen ?? DateTime.now().toUtc(),
        lastSeen = lastSeen ?? DateTime.now().toUtc();

  String get hostIdentifier => '${host.trim().toLowerCase()}:$port';

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'key_type': keyType,
        'fingerprint': fingerprint,
        'first_seen': firstSeen.toIso8601String(),
        'last_seen': lastSeen.toIso8601String(),
      };

  factory KnownHostEntry.fromJson(Map<String, dynamic> json) {
    return KnownHostEntry(
      host: json['host'] as String? ?? 'localhost',
      port: json['port'] as int? ?? 22,
      keyType: json['key_type'] as String? ?? 'unknown',
      fingerprint: json['fingerprint'] as String? ?? '',
      firstSeen: json['first_seen'] != null
          ? DateTime.tryParse(json['first_seen'] as String)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
      lastSeen: json['last_seen'] != null
          ? DateTime.tryParse(json['last_seen'] as String)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
    );
  }

  KnownHostEntry copyWith({
    String? fingerprint,
    DateTime? lastSeen,
  }) {
    return KnownHostEntry(
      host: host,
      port: port,
      keyType: keyType,
      fingerprint: fingerprint ?? this.fingerprint,
      firstSeen: firstSeen,
      lastSeen: lastSeen ?? DateTime.now().toUtc(),
    );
  }
}

/// Thrown when a remote server's host key does not match previously trusted records.
class HostKeyMismatchException implements Exception {
  final String host;
  final int port;
  final String keyType;
  final String expectedFingerprint;
  final String receivedFingerprint;

  String get fingerprint => receivedFingerprint;

  HostKeyMismatchException({
    required this.host,
    required this.port,
    required this.keyType,
    required this.expectedFingerprint,
    required this.receivedFingerprint,
  });

  @override
  String toString() =>
      'WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED for $host:$port ($keyType)!\n'
      'Expected: $expectedFingerprint\n'
      'Received: $receivedFingerprint\n'
      'This could indicate a Man-in-the-Middle attack or an unexpected server key rotation.';
}

/// Thrown when an unknown host key was presented and rejected by policy or user.
class HostKeyUnknownException implements Exception {
  final String host;
  final int port;
  final String keyType;
  final String fingerprint;

  HostKeyUnknownException({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
  });

  @override
  String toString() =>
      'Host key verification failed: $host:$port ($keyType: $fingerprint) is not trusted.';
}

/// Manages known host keys and prevents Man-in-the-Middle (MITM) attacks.
class KnownHostsService {
  static final KnownHostsService instance = KnownHostsService();

  String? _customFilePath;
  bool _isLoaded = false;

  /// Map of `"$host:$port" -> Map<keyType, KnownHostEntry>`
  final Map<String, Map<String, KnownHostEntry>> _entries = {};

  KnownHostsService({String? customFilePath}) : _customFilePath = customFilePath;

  void setCustomFilePath(String? path) {
    _customFilePath = path;
    _isLoaded = false;
  }

  Future<File?> _getFile() async {
    if (_customFilePath != null && _customFilePath!.isNotEmpty) {
      final file = File(_customFilePath!);
      final parent = file.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      return file;
    }
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docDir.path, 'Mjolnir'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return File(p.join(dir.path, 'known_hosts.json'));
    } catch (_) {
      // In unit test environments without path_provider mocks, operate in-memory.
      return null;
    }
  }

  Future<void> _ensureLoaded() async {
    if (_isLoaded) return;
    await load();
  }

  Future<void> load() async {
    try {
      final file = await _getFile();
      if (file != null && await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final json = jsonDecode(content) as Map<String, dynamic>;
          _entries.clear();
          if (json['hosts'] is Map) {
            final hostsMap = json['hosts'] as Map<String, dynamic>;
            for (final hostEntry in hostsMap.entries) {
              final hostId = hostEntry.key.toLowerCase().trim();
              final val = hostEntry.value;
              if (val is Map) {
                final keyMap = <String, KnownHostEntry>{};
                for (final kEntry in val.entries) {
                  if (kEntry.value is Map) {
                    keyMap[kEntry.key.toString()] = KnownHostEntry.fromJson(
                      Map<String, dynamic>.from(kEntry.value as Map),
                    );
                  }
                }
                _entries[hostId] = keyMap;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('KnownHostsService.load error: $e');
    } finally {
      _isLoaded = true;
    }
  }

  Future<void> save() async {
    try {
      final file = await _getFile();
      if (file == null) return;

      final Map<String, dynamic> hostsMap = {};
      for (final hostEntry in _entries.entries) {
        final keyMap = <String, dynamic>{};
        for (final kEntry in hostEntry.value.entries) {
          keyMap[kEntry.key] = kEntry.value.toJson();
        }
        hostsMap[hostEntry.key] = keyMap;
      }

      final json = {
        'version': 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'hosts': hostsMap,
      };

      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
        flush: true,
      );
    } catch (e) {
      debugPrint('KnownHostsService.save error: $e');
    }
  }

  static String formatHostIdentifier(String host, int port) {
    final h = host.trim().toLowerCase();
    final p = port <= 0 ? 22 : port;
    return '$h:$p';
  }

  /// Verifies a received host key against stored known hosts.
  Future<HostKeyVerificationResult> verifyHostKey({
    required String host,
    required int port,
    required String keyType,
    required String fingerprint,
  }) async {
    await _ensureLoaded();

    final hostId = formatHostIdentifier(host, port);
    final normalizedFp = fingerprint.trim();
    final hostEntries = _entries[hostId];

    if (hostEntries != null && hostEntries.containsKey(keyType)) {
      final entry = hostEntries[keyType]!;
      if (entry.fingerprint == normalizedFp) {
        // Trusted match: update lastSeen timestamp
        hostEntries[keyType] = entry.copyWith(lastSeen: DateTime.now().toUtc());
        return HostKeyVerificationResult(
          status: HostKeyStatus.trusted,
          host: host.trim(),
          port: port <= 0 ? 22 : port,
          keyType: keyType,
          fingerprint: normalizedFp,
          previousFingerprint: entry.fingerprint,
          entry: entry,
        );
      } else {
        // Host key has changed! Potential MITM attack!
        return HostKeyVerificationResult(
          status: HostKeyStatus.mismatch,
          host: host.trim(),
          port: port <= 0 ? 22 : port,
          keyType: keyType,
          fingerprint: normalizedFp,
          previousFingerprint: entry.fingerprint,
          entry: entry,
        );
      }
    }

    // First time seeing this host and key type
    return HostKeyVerificationResult(
      status: HostKeyStatus.unknown,
      host: host.trim(),
      port: port <= 0 ? 22 : port,
      keyType: keyType,
      fingerprint: normalizedFp,
      previousFingerprint: null,
      entry: null,
    );
  }

  /// Records or updates a trusted host key.
  Future<void> trustHostKey({
    required String host,
    required int port,
    required String keyType,
    required String fingerprint,
  }) async {
    await _ensureLoaded();

    final hostId = formatHostIdentifier(host, port);
    final normalizedFp = fingerprint.trim();
    final hostEntries = _entries.putIfAbsent(hostId, () => {});

    final existing = hostEntries[keyType];
    final entry = KnownHostEntry(
      host: host.trim(),
      port: port <= 0 ? 22 : port,
      keyType: keyType,
      fingerprint: normalizedFp,
      firstSeen: existing?.firstSeen ?? DateTime.now().toUtc(),
      lastSeen: DateTime.now().toUtc(),
    );

    hostEntries[keyType] = entry;
    await save();
  }

  /// Removes a stored host key, or all keys for a given host:port.
  Future<bool> removeHostKey({
    required String host,
    required int port,
    String? keyType,
  }) async {
    await _ensureLoaded();

    final hostId = formatHostIdentifier(host, port);
    if (!_entries.containsKey(hostId)) return false;

    if (keyType != null) {
      final removed = _entries[hostId]!.remove(keyType) != null;
      if (_entries[hostId]!.isEmpty) {
        _entries.remove(hostId);
      }
      if (removed) await save();
      return removed;
    } else {
      _entries.remove(hostId);
      await save();
      return true;
    }
  }

  /// Returns all stored entries for a given host and port.
  Future<List<KnownHostEntry>> getEntriesForHost({
    required String host,
    required int port,
  }) async {
    await _ensureLoaded();
    final hostId = formatHostIdentifier(host, port);
    final hostEntries = _entries[hostId];
    if (hostEntries == null) return [];
    return hostEntries.values.toList();
  }

  /// Returns all stored known host entries.
  Future<List<KnownHostEntry>> getKnownHosts() async {
    await _ensureLoaded();
    final List<KnownHostEntry> all = [];
    for (final hostMap in _entries.values) {
      all.addAll(hostMap.values);
    }
    all.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return all;
  }

  /// Clears all known host keys in memory and on disk.
  Future<void> clearAll() async {
    _entries.clear();
    await save();
  }
}
