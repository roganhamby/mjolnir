import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/sync_vault_file.dart';

class DropboxConfig {
  String accessToken;
  String? appKey;
  String? appSecret;
  String? refreshToken;
  String folderPath;
  bool autoSyncOnLoadAndSave;

  DropboxConfig({
    this.accessToken = '',
    this.appKey,
    this.appSecret,
    this.refreshToken,
    this.folderPath = '',
    this.autoSyncOnLoadAndSave = true,
  });

  bool get isConfigured =>
      accessToken.trim().isNotEmpty ||
      ((refreshToken?.trim().isNotEmpty ?? false) &&
          (appKey?.trim().isNotEmpty ?? false));

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'app_key': appKey,
        'app_secret': appSecret,
        'refresh_token': refreshToken,
        'folder_path': folderPath,
        'auto_sync': autoSyncOnLoadAndSave,
      };

  factory DropboxConfig.fromJson(Map<String, dynamic> json) {
    final rawFolder = (json['folder_path'] as String?)?.trim() ?? '';
    // Automatically migrate legacy '/App/Mjolnir' or '/App' to root ''
    final isLegacy = rawFolder == '/App/Mjolnir' ||
        rawFolder == '/App' ||
        rawFolder == 'App/Mjolnir' ||
        rawFolder == 'App' ||
        rawFolder == '/Apps/Mjolnir' ||
        rawFolder == 'Apps/Mjolnir' ||
        rawFolder == '/';
    return DropboxConfig(
      accessToken: json['access_token'] as String? ?? '',
      appKey: json['app_key'] as String?,
      appSecret: json['app_secret'] as String?,
      refreshToken: json['refresh_token'] as String?,
      folderPath: isLegacy ? '' : rawFolder,
      autoSyncOnLoadAndSave: json['auto_sync'] as bool? ?? true,
    );
  }
}

class DropboxFileMetadata {
  final String name;
  final String pathDisplay;
  final DateTime serverModified;

  DropboxFileMetadata({
    required this.name,
    required this.pathDisplay,
    required this.serverModified,
  });
}

class DropboxSyncService {
  DropboxConfig _config = DropboxConfig();

  DropboxConfig get config => _config;

  /// Returns the API folder path (empty string for root of the app folder, or `/subfolder`).
  String get normalizedFolderPath {
    var path = _config.folderPath.trim();
    if (path.isEmpty ||
        path == '/' ||
        path == '/App/Mjolnir' ||
        path == '/App' ||
        path == 'App/Mjolnir' ||
        path == 'App' ||
        path == '/Apps/Mjolnir' ||
        path == 'Apps/Mjolnir') {
      return '';
    }
    if (!path.startsWith('/')) path = '/$path';
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  /// User-friendly display of the Dropbox folder path.
  String get displayFolderPath {
    final norm = normalizedFolderPath;
    if (norm.isEmpty) {
      return 'All files / Apps / Mjolnir';
    }
    return 'All files / Apps / Mjolnir$norm';
  }

  Future<File> _getConfigFile() async {
    final docDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docDir.path, 'Mjolnir'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File(p.join(dir.path, 'dropbox_config.json'));
  }

  Future<void> loadConfig() async {
    try {
      final file = await _getConfigFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final json = jsonDecode(content) as Map<String, dynamic>;
          _config = DropboxConfig.fromJson(json);
        }
      }
    } catch (e) {
      debugPrint('Failed to load Dropbox config: $e');
    }
  }

  Future<void> saveConfig(DropboxConfig newConfig) async {
    _config = newConfig;
    try {
      final file = await _getConfigFile();
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_config.toJson()),
        flush: true,
      );
    } catch (e) {
      debugPrint('Failed to save Dropbox config: $e');
    }
  }

  /// Exchanges an OAuth2 authorization code for an access token and refresh token.
  Future<void> exchangeAuthorizationCode({
    required String appKey,
    required String appSecret,
    required String authCode,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('https://api.dropboxapi.com/oauth2/token'),
      );
      req.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/x-www-form-urlencoded',
      );
      final body = {
        'code': authCode.trim(),
        'grant_type': 'authorization_code',
        'client_id': appKey.trim(),
        if (appSecret.trim().isNotEmpty) 'client_secret': appSecret.trim(),
      }.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');

      req.write(body);
      final resp = await req.close();
      final respBody = await resp.transform(utf8.decoder).join();

      if (resp.statusCode != 200) {
        throw Exception('Dropbox OAuth error (${resp.statusCode}): $respBody');
      }

      final data = jsonDecode(respBody) as Map<String, dynamic>;
      _config.appKey = appKey.trim();
      _config.appSecret = appSecret.trim();
      _config.accessToken = data['access_token'] as String? ?? _config.accessToken;
      if (data['refresh_token'] != null) {
        _config.refreshToken = data['refresh_token'] as String;
      }
      await saveConfig(_config);
    } finally {
      client.close();
    }
  }

  /// Refreshes the short-lived access token if a refresh token and app key are configured.
  Future<String> _getValidAccessToken({bool forceRefresh = false}) async {
    if (!forceRefresh && _config.accessToken.trim().isNotEmpty) {
      return _config.accessToken.trim();
    }

    final refreshToken = _config.refreshToken?.trim() ?? '';
    final appKey = _config.appKey?.trim() ?? '';
    final appSecret = _config.appSecret?.trim() ?? '';

    if (refreshToken.isEmpty || appKey.isEmpty) {
      if (_config.accessToken.trim().isNotEmpty) {
        return _config.accessToken.trim();
      }
      throw Exception('Dropbox is not configured with an Access Token or Refresh Token.');
    }

    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('https://api.dropboxapi.com/oauth2/token'),
      );
      req.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/x-www-form-urlencoded',
      );
      final body = {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': appKey,
        if (appSecret.isNotEmpty) 'client_secret': appSecret,
      }.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');

      req.write(body);
      final resp = await req.close();
      final respBody = await resp.transform(utf8.decoder).join();

      if (resp.statusCode != 200) {
        throw Exception('Failed to refresh Dropbox token (${resp.statusCode}): $respBody');
      }

      final data = jsonDecode(respBody) as Map<String, dynamic>;
      final newAccessToken = data['access_token'] as String? ?? '';
      if (newAccessToken.isEmpty) {
        throw Exception('Dropbox token refresh returned empty access_token.');
      }

      _config.accessToken = newAccessToken;
      await saveConfig(_config);
      return newAccessToken;
    } finally {
      client.close();
    }
  }

  /// Ensures the configured subfolder exists on Dropbox.
  /// Root app folder (All files / Apps / Mjolnir) always exists.
  Future<void> ensureDirectoryExists() async {
    final folder = normalizedFolderPath;
    if (folder.isEmpty || folder == '/') {
      return;
    }
    var token = await _getValidAccessToken();

    Future<HttpClientResponse> sendRequest(String bearer) async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(
          Uri.parse('https://api.dropboxapi.com/2/files/create_folder_v2'),
        );
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.add(utf8.encode(jsonEncode({
          'path': folder,
          'autorename': false,
        })));
        return await req.close();
      } catch (_) {
        client.close();
        rethrow;
      }
    }

    var resp = await sendRequest(token);
    if (resp.statusCode == 401 && (_config.refreshToken?.isNotEmpty ?? false)) {
      token = await _getValidAccessToken(forceRefresh: true);
      resp = await sendRequest(token);
    }

    final respBody = await resp.transform(utf8.decoder).join();
    // 200 = created; 409 with path/conflict/folder = already exists
    if (resp.statusCode == 200) return;
    if (resp.statusCode == 409 && respBody.contains('conflict')) {
      return;
    }
    if (resp.statusCode == 401) {
      throw Exception(
        'Dropbox Access Token expired or unauthorized (401). '
        'Developer Console tokens expire after 4 hours. '
        'Generate a fresh token in the Dropbox Developer Console or configure an OAuth2 refresh token for permanent sync.',
      );
    }
    throw Exception('Failed to create Dropbox directory $folder (${resp.statusCode}): $respBody');
  }

  /// Lists all `.json` files in the Dropbox folder, sorted by `server_modified` descending (newest first).
  Future<List<DropboxFileMetadata>> listJsonFiles() async {
    await ensureDirectoryExists();
    var token = await _getValidAccessToken();
    final folder = normalizedFolderPath;

    Future<HttpClientResponse> sendRequest(String bearer) async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(
          Uri.parse('https://api.dropboxapi.com/2/files/list_folder'),
        );
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.add(utf8.encode(jsonEncode({
          'path': folder, // Empty string "" is the root of the app folder in Dropbox API v2
          'recursive': false,
          'include_deleted': false,
        })));
        return await req.close();
      } catch (_) {
        client.close();
        rethrow;
      }
    }

    var resp = await sendRequest(token);
    if (resp.statusCode == 401 && (_config.refreshToken?.isNotEmpty ?? false)) {
      token = await _getValidAccessToken(forceRefresh: true);
      resp = await sendRequest(token);
    }

    final respBody = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      if (resp.statusCode == 401) {
        throw Exception(
          'Dropbox Access Token expired or unauthorized (401). '
          'Developer Console tokens expire after 4 hours. '
          'Generate a fresh token in the Dropbox Developer Console or configure an OAuth2 refresh token for permanent sync.',
        );
      }
      throw Exception('Failed to list Dropbox folder $displayFolderPath (${resp.statusCode}): $respBody');
    }

    final data = jsonDecode(respBody) as Map<String, dynamic>;
    final entries = data['entries'] as List<dynamic>? ?? [];
    final files = <DropboxFileMetadata>[];

    for (final entry in entries) {
      if (entry is Map<String, dynamic> && entry['.tag'] == 'file') {
        final name = entry['name'] as String? ?? '';
        if (name.toLowerCase().endsWith('.json')) {
          final pathDisplay = entry['path_display'] as String? ?? (folder.isEmpty ? '/$name' : '$folder/$name');
          final modStr = entry['server_modified'] as String?;
          final modified = modStr != null
              ? DateTime.tryParse(modStr)?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
              : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
          files.add(
            DropboxFileMetadata(
              name: name,
              pathDisplay: pathDisplay,
              serverModified: modified,
            ),
          );
        }
      }
    }

    files.sort((a, b) => b.serverModified.compareTo(a.serverModified));
    return files;
  }

  /// Downloads a JSON file from Dropbox by its path.
  Future<String> downloadFileContent(String dropboxFilePath) async {
    var token = await _getValidAccessToken();
    final cleanPath = dropboxFilePath.startsWith('/') ? dropboxFilePath : '/$dropboxFilePath';

    Future<HttpClientResponse> sendRequest(String bearer) async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(
          Uri.parse('https://content.dropboxapi.com/2/files/download'),
        );
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
        req.headers.set('Dropbox-API-Arg', jsonEncode({'path': cleanPath}));
        return await req.close();
      } catch (_) {
        client.close();
        rethrow;
      }
    }

    var resp = await sendRequest(token);
    if (resp.statusCode == 401 && (_config.refreshToken?.isNotEmpty ?? false)) {
      token = await _getValidAccessToken(forceRefresh: true);
      resp = await sendRequest(token);
    }

    final respBody = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      if (resp.statusCode == 401) {
        throw Exception(
          'Dropbox Access Token expired or unauthorized (401). '
          'Developer Console tokens expire after 4 hours. '
          'Generate a fresh token in the Dropbox Developer Console or configure an OAuth2 refresh token for permanent sync.',
        );
      }
      throw Exception('Failed to download $cleanPath from Dropbox (${resp.statusCode}): $respBody');
    }

    return respBody;
  }

  /// Downloads the newest valid `SyncVaultFile` from Dropbox, or returns null if none exist.
  Future<({SyncVaultFile vault, String rawJson, String filePath, DateTime modifiedAt})?> fetchNewestVaultFromDropbox() async {
    if (!_config.isConfigured) return null;

    final files = await listJsonFiles();
    if (files.isEmpty) return null;

    ({SyncVaultFile vault, String rawJson, String filePath, DateTime modifiedAt})? newest;

    for (final fileMeta in files) {
      try {
        final rawJson = await downloadFileContent(fileMeta.pathDisplay);
        if (rawJson.trim().isEmpty) continue;
        final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
        final vault = SyncVaultFile.fromJson(decoded);
        // Use the later of the vault's internal updatedAt and Dropbox's serverModified
        final effectiveTime = vault.updatedAt.isAfter(fileMeta.serverModified)
            ? vault.updatedAt
            : fileMeta.serverModified;

        if (newest == null || effectiveTime.isAfter(newest.modifiedAt)) {
          newest = (
            vault: vault,
            rawJson: rawJson,
            filePath: fileMeta.pathDisplay,
            modifiedAt: effectiveTime,
          );
        }
      } catch (e) {
        debugPrint('Skipping invalid vault JSON in Dropbox (${fileMeta.pathDisplay}): $e');
      }
    }

    return newest;
  }

  /// Uploads a JSON vault string to Dropbox (e.g. `/servers.json` in `All files / Apps / Mjolnir`).
  Future<String> uploadVaultJson(
    String jsonString, {
    String fileName = 'servers.json',
  }) async {
    await ensureDirectoryExists();
    var token = await _getValidAccessToken();
    final folder = normalizedFolderPath;
    final cleanFileName = fileName.trim().replaceAll(RegExp(r'^/+'), '');
    final targetPath = folder.isEmpty ? '/$cleanFileName' : '$folder/$cleanFileName';
    final bytes = utf8.encode(jsonString);

    Future<HttpClientResponse> sendRequest(String bearer) async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(
          Uri.parse('https://content.dropboxapi.com/2/files/upload'),
        );
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
        req.headers.set(
          'Dropbox-API-Arg',
          jsonEncode({
            'path': targetPath,
            'mode': 'overwrite',
            'autorename': false,
            'mute': false,
          }),
        );
        req.add(bytes);
        return await req.close();
      } catch (_) {
        client.close();
        rethrow;
      }
    }

    var resp = await sendRequest(token);
    if (resp.statusCode == 401 && (_config.refreshToken?.isNotEmpty ?? false)) {
      token = await _getValidAccessToken(forceRefresh: true);
      resp = await sendRequest(token);
    }

    final respBody = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      if (resp.statusCode == 401) {
        throw Exception(
          'Dropbox Access Token expired or unauthorized (401). '
          'Developer Console tokens expire after 4 hours. '
          'Generate a fresh token in the Dropbox Developer Console or configure an OAuth2 refresh token for permanent sync.',
        );
      }
      throw Exception('Failed to upload $targetPath to Dropbox (${resp.statusCode}): $respBody');
    }

    return targetPath;
  }
}
