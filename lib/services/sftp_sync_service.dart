import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:dartssh2/dartssh2.dart';
import '../models/server_config.dart';
import '../models/sync_vault_file.dart';
import 'ssh_service.dart';

class SftpSyncConfig {
  String host;
  int port;
  String username;
  AuthType authType;
  String? password;
  String? privateKey;
  String? passphrase;
  String remotePath;
  bool autoSyncOnLoadAndSave;

  SftpSyncConfig({
    this.host = '',
    this.port = 22,
    this.username = '',
    this.authType = AuthType.password,
    this.password,
    this.privateKey,
    this.passphrase,
    this.remotePath = '~/.mjolnir/servers.json',
    this.autoSyncOnLoadAndSave = true,
  });

  bool get isConfigured => host.trim().isNotEmpty && username.trim().isNotEmpty;

  /// Creates a ServerConfig representation used to connect via SshService.
  ServerConfig toServerConfig() {
    return ServerConfig(
      id: 'sftp_sync_server_config',
      name: 'SFTP Sync ($host)',
      host: host.trim(),
      port: port > 0 ? port : 22,
      username: username.trim(),
      authType: authType,
      connectionType: ConnectionType.sftp,
      decryptedCredentials: ServerCredentials(
        password: password,
        privateKey: privateKey,
        passphrase: passphrase,
      ),
    );
  }

  /// Convenience factory to copy connection parameters from an existing ServerConfig.
  factory SftpSyncConfig.fromServerConfig(
    ServerConfig server, {
    String? remotePath,
    bool? autoSync,
  }) {
    return SftpSyncConfig(
      host: server.host,
      port: server.port,
      username: server.username,
      authType: server.authType,
      password: server.decryptedCredentials?.password,
      privateKey: server.decryptedCredentials?.privateKey,
      passphrase: server.decryptedCredentials?.passphrase,
      remotePath: remotePath ?? '~/.mjolnir/servers.json',
      autoSyncOnLoadAndSave: autoSync ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'username': username,
        'auth_type': authType.name,
        if (password != null) 'password': password,
        if (privateKey != null) 'private_key': privateKey,
        if (passphrase != null) 'passphrase': passphrase,
        'remote_path': remotePath,
        'auto_sync': autoSyncOnLoadAndSave,
      };

  factory SftpSyncConfig.fromJson(Map<String, dynamic> json) {
    final rawAuth = json['auth_type'] as String?;
    final auth = rawAuth == AuthType.privateKey.name
        ? AuthType.privateKey
        : AuthType.password;
    final rawPort = json['port'];
    final portNum = rawPort is int ? rawPort : int.tryParse('$rawPort') ?? 22;

    return SftpSyncConfig(
      host: json['host'] as String? ?? '',
      port: portNum > 0 ? portNum : 22,
      username: json['username'] as String? ?? '',
      authType: auth,
      password: json['password'] as String?,
      privateKey: json['private_key'] as String?,
      passphrase: json['passphrase'] as String?,
      remotePath: (json['remote_path'] as String?)?.trim().isNotEmpty == true
          ? json['remote_path'] as String
          : '~/.mjolnir/servers.json',
      autoSyncOnLoadAndSave: json['auto_sync'] as bool? ?? true,
    );
  }
}

class SftpFileMeta {
  final String name;
  final String fullPath;
  final DateTime modifiedAt;
  final int size;

  SftpFileMeta({
    required this.name,
    required this.fullPath,
    required this.modifiedAt,
    required this.size,
  });
}

class SftpSyncService {
  final SshService sshService;
  SftpSyncConfig _config = SftpSyncConfig();

  SftpSyncService({SshService? sshService})
      : sshService = sshService ?? SshService();

  SftpSyncConfig get config => _config;

  String get displayRemotePath {
    final raw = _config.remotePath.trim();
    if (raw.isEmpty) return '~/.mjolnir/servers.json';
    return raw;
  }

  Future<File> _getConfigFile() async {
    final docDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docDir.path, 'Mjolnir'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File(p.join(dir.path, 'sftp_sync_config.json'));
  }

  Future<void> loadConfig() async {
    try {
      final file = await _getConfigFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final json = jsonDecode(content) as Map<String, dynamic>;
          _config = SftpSyncConfig.fromJson(json);
        }
      }
    } catch (e) {
      debugPrint('Failed to load SFTP sync config: $e');
    }
  }

  Future<void> saveConfig(SftpSyncConfig newConfig) async {
    _config = newConfig;
    try {
      final file = await _getConfigFile();
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_config.toJson()),
        flush: true,
      );
    } catch (e) {
      debugPrint('Failed to save SFTP sync config: $e');
    }
  }

  /// Resolves the remote home directory for the authenticated session.
  Future<String> _resolveHomePath(SftpClient sftp, ServerConfig server) async {
    try {
      final realHome = await sftp.absolute('.');
      if (realHome.trim().isNotEmpty) {
        return realHome.trim();
      }
    } catch (_) {}
    return server.username == 'root' ? '/root' : '/home/${server.username}';
  }

  /// Ensures that all directory segments along [dirPath] exist remotely.
  Future<void> _ensureRemoteDirectory(SftpClient sftp, String dirPath) async {
    final normalized = p.posix.normalize(dirPath.trim());
    if (normalized == '/' || normalized == '.') return;

    try {
      final stat = await sftp.stat(normalized);
      if (stat.isDirectory) return;
    } catch (_) {}

    final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();
    var current = normalized.startsWith('/') ? '' : '.';
    for (final seg in segments) {
      current = current == '.' ? seg : '$current/$seg';
      if (current == '') current = '/';
      try {
        final stat = await sftp.stat(current);
        if (!stat.isDirectory) {
          throw Exception('Remote path $current already exists and is not a directory.');
        }
      } catch (_) {
        try {
          await sftp.mkdir(current);
        } catch (_) {}
      }
    }
  }

  /// Connects to SFTP, verifies authentication, ensures remote path exists, and lists JSON files.
  Future<({bool success, String message, int fileCount})> testConnection([
    SftpSyncConfig? testConfig,
  ]) async {
    final active = testConfig ?? _config;
    if (!active.isConfigured) {
      return (
        success: false,
        message: 'Host and Username are required.',
        fileCount: 0,
      );
    }

    final server = active.toServerConfig();
    SftpSession? session;
    try {
      session = await sshService.startSftpSession(server);
      final homePath = await _resolveHomePath(session.sftp, server);
      final resolvedRaw = SshService.resolveRemotePath(
        active.remotePath.trim().isEmpty ? '~/.mjolnir/servers.json' : active.remotePath.trim(),
        homePath: homePath,
      );

      final isJsonFile = resolvedRaw.endsWith('.json');
      final targetDir = isJsonFile ? p.posix.dirname(resolvedRaw) : resolvedRaw;

      await _ensureRemoteDirectory(session.sftp, targetDir);

      final files = await _listJsonFilesInDirectory(session.sftp, targetDir);
      return (
        success: true,
        message: 'Connected to ${active.host}:${active.port}! Remote directory "$targetDir" is ready (${files.length} JSON file(s) found).',
        fileCount: files.length,
      );
    } catch (e) {
      return (
        success: false,
        message: 'SFTP connection failed: $e',
        fileCount: 0,
      );
    } finally {
      session?.close();
    }
  }

  Future<List<SftpFileMeta>> _listJsonFilesInDirectory(
    SftpClient sftp,
    String dirPath,
  ) async {
    try {
      final items = await sftp.listdir(dirPath);
      final results = <SftpFileMeta>[];
      for (final item in items) {
        if (item.filename == '.' || item.filename == '..') continue;
        if (item.attr.isDirectory) continue;
        if (!item.filename.toLowerCase().endsWith('.json')) continue;

        final mtimeSecs = item.attr.mtime ?? 0;
        final modifiedAt = mtimeSecs > 0
            ? DateTime.fromMillisecondsSinceEpoch(mtimeSecs * 1000, isUtc: true)
            : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

        results.add(
          SftpFileMeta(
            name: item.filename,
            fullPath: p.posix.normalize(p.posix.join(dirPath, item.filename)),
            modifiedAt: modifiedAt,
            size: item.attr.size ?? 0,
          ),
        );
      }
      return results;
    } catch (_) {
      return [];
    }
  }

  /// Downloads the content of a remote file as a UTF-8 string.
  Future<String> _readRemoteFile(SftpClient sftp, String remoteFilePath) async {
    final remoteFile = await sftp.open(remoteFilePath);
    final builder = BytesBuilder();
    try {
      await for (final chunk in remoteFile.read()) {
        builder.add(chunk);
      }
    } finally {
      await remoteFile.close();
    }
    return utf8.decode(builder.takeBytes());
  }

  /// Fetches the newest valid `SyncVaultFile` from the SFTP server.
  Future<({SyncVaultFile vault, String rawJson, String filePath, DateTime modifiedAt})?> fetchNewestVaultFromSftp() async {
    if (!_config.isConfigured) return null;

    final server = _config.toServerConfig();
    SftpSession? session;
    try {
      session = await sshService.startSftpSession(server);
      final homePath = await _resolveHomePath(session.sftp, server);
      final resolvedRaw = SshService.resolveRemotePath(
        _config.remotePath.trim().isEmpty ? '~/.mjolnir/servers.json' : _config.remotePath.trim(),
        homePath: homePath,
      );

      final isJsonFile = resolvedRaw.endsWith('.json');
      final targetDir = isJsonFile ? p.posix.dirname(resolvedRaw) : resolvedRaw;

      final files = await _listJsonFilesInDirectory(session.sftp, targetDir);

      // If the target is a specific file that wasn't in listdir, try statting it directly
      if (isJsonFile && !files.any((f) => f.fullPath == resolvedRaw)) {
        try {
          final stat = await session.sftp.stat(resolvedRaw);
          final mtimeSecs = stat.mtime ?? 0;
          final modifiedAt = mtimeSecs > 0
              ? DateTime.fromMillisecondsSinceEpoch(mtimeSecs * 1000, isUtc: true)
              : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
          files.add(
            SftpFileMeta(
              name: p.posix.basename(resolvedRaw),
              fullPath: resolvedRaw,
              modifiedAt: modifiedAt,
              size: stat.size ?? 0,
            ),
          );
        } catch (_) {}
      }

      if (files.isEmpty) return null;

      ({SyncVaultFile vault, String rawJson, String filePath, DateTime modifiedAt})? newest;

      for (final fileMeta in files) {
        try {
          final rawJson = await _readRemoteFile(session.sftp, fileMeta.fullPath);
          if (rawJson.trim().isEmpty) continue;
          final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
          final vault = SyncVaultFile.fromJson(decoded);

          final effectiveTime = vault.updatedAt.isAfter(fileMeta.modifiedAt)
              ? vault.updatedAt
              : fileMeta.modifiedAt;

          if (newest == null || effectiveTime.isAfter(newest.modifiedAt)) {
            newest = (
              vault: vault,
              rawJson: rawJson,
              filePath: fileMeta.fullPath,
              modifiedAt: effectiveTime,
            );
          }
        } catch (e) {
          debugPrint('Skipping invalid vault JSON on SFTP (${fileMeta.fullPath}): $e');
        }
      }

      return newest;
    } finally {
      session?.close();
    }
  }

  /// Uploads a JSON vault string to the SFTP server.
  Future<String> uploadVaultJson(
    String jsonString, {
    String? fileName,
  }) async {
    if (!_config.isConfigured) {
      throw Exception('SFTP sync is not configured.');
    }

    final server = _config.toServerConfig();
    SftpSession? session;
    try {
      session = await sshService.startSftpSession(server);
      final homePath = await _resolveHomePath(session.sftp, server);
      final resolvedRaw = SshService.resolveRemotePath(
        _config.remotePath.trim().isEmpty ? '~/.mjolnir/servers.json' : _config.remotePath.trim(),
        homePath: homePath,
      );

      final isJsonFile = resolvedRaw.endsWith('.json');
      final targetDir = isJsonFile ? p.posix.dirname(resolvedRaw) : resolvedRaw;

      await _ensureRemoteDirectory(session.sftp, targetDir);

      final cleanFileName = fileName != null && fileName.trim().isNotEmpty
          ? fileName.trim()
          : (isJsonFile ? p.posix.basename(resolvedRaw) : 'servers.json');

      final targetFilePath = p.posix.normalize(p.posix.join(targetDir, cleanFileName));
      final bytes = Uint8List.fromList(utf8.encode(jsonString));

      final remoteFile = await session.sftp.open(
        targetFilePath,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
      );

      try {
        await remoteFile.writeBytes(bytes);
      } finally {
        await remoteFile.close();
      }

      return targetFilePath;
    } finally {
      session?.close();
    }
  }
}
