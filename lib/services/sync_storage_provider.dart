import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/sync_vault_file.dart';

abstract class SyncStorageProvider {
  Future<String> getProviderName();
  Future<SyncVaultFile> loadVault();
  Future<void> saveVault(SyncVaultFile vault);
  Future<bool> vaultExists();
}

/// Local File System Provider (Reads/Writes to a customizable JSON file path)
class LocalFileSyncProvider implements SyncStorageProvider {
  String? _customFilePath;

  LocalFileSyncProvider({String? customFilePath}) : _customFilePath = customFilePath;

  void setCustomPath(String? path) {
    _customFilePath = path;
  }

  Future<File> _getFile() async {
    if (_customFilePath != null && _customFilePath!.isNotEmpty) {
      return File(_customFilePath!);
    }
    final docDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docDir.path, 'Mjolnir'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File(p.join(dir.path, 'servers.json'));
  }

  @override
  Future<String> getProviderName() async => 'Local File (${(await _getFile()).path})';

  @override
  Future<bool> vaultExists() async {
    final file = await _getFile();
    return await file.exists();
  }

  @override
  Future<SyncVaultFile> loadVault() async {
    final file = await _getFile();
    if (!await file.exists()) {
      final initialVault = SyncVaultFile.createEmpty();
      await saveVault(initialVault);
      return initialVault;
    }

    final contents = await file.readAsString();
    if (contents.trim().isEmpty) {
      final initialVault = SyncVaultFile.createEmpty();
      await saveVault(initialVault);
      return initialVault;
    }

    try {
      final json = jsonDecode(contents) as Map<String, dynamic>;
      return SyncVaultFile.fromJson(json);
    } catch (e) {
      debugPrint('Error parsing vault file: $e');
      rethrow;
    }
  }

  @override
  Future<void> saveVault(SyncVaultFile vault) async {
    final file = await _getFile();
    await file.writeAsString(vault.toFormattedJson(), flush: true);
  }
}
