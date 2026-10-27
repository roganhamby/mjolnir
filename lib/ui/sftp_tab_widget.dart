import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/server_config.dart';
import '../models/task_item.dart';
import '../services/ssh_service.dart';
import 'task_manager_tab_widget.dart';

enum _DragSource { local, remote }

class _TransferCancelledException implements Exception {
  const _TransferCancelledException();
}

enum _TransferType { upload, downloadToLocal, downloadSaveAs, downloadOpenExternal }

class _TransferJob {
  final int id;
  final _TransferType type;
  final String name;
  final String sourcePath;
  final String? targetDir;
  final bool isDirectory;
  final int? size;
  bool isCancelled = false;

  _TransferJob({
    required this.id,
    required this.type,
    required this.name,
    required this.sourcePath,
    this.targetDir,
    this.isDirectory = false,
    this.size,
  });

  String get description {
    switch (type) {
      case _TransferType.upload:
        return 'Upload "$name" → $targetDir';
      case _TransferType.downloadToLocal:
        return 'Download "$name" → $targetDir';
      case _TransferType.downloadSaveAs:
        return 'Download "$name" (Save As)';
      case _TransferType.downloadOpenExternal:
        return 'Open "$name" in External Text Editor';
    }
  }
}

class _SftpDragPayload {
  final _DragSource source;
  final String path;
  final String name;
  final bool isDirectory;
  final int? size;

  const _SftpDragPayload({
    required this.source,
    required this.path,
    required this.name,
    required this.isDirectory,
    this.size,
  });
}

class _LocalFileEntry {
  final FileSystemEntity entity;
  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime modified;

  const _LocalFileEntry({
    required this.entity,
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modified,
  });
}

class SftpTabWidget extends StatefulWidget {
  final ServerConfig server;
  final SshService sshService;
  final TaskItem? assignedTask;
  final VoidCallback? onCompleteAssignedTask;
  final VoidCallback? onUnassignTask;
  final ValueChanged<TaskItem>? onAssignedTaskChanged;
  final ValueChanged<String>? onDefaultRemotePathChanged;

  const SftpTabWidget({
    super.key,
    required this.server,
    required this.sshService,
    this.assignedTask,
    this.onCompleteAssignedTask,
    this.onUnassignTask,
    this.onAssignedTaskChanged,
    this.onDefaultRemotePathChanged,
  });

  @override
  State<SftpTabWidget> createState() => _SftpTabWidgetState();
}

class _SftpTabWidgetState extends State<SftpTabWidget> {
  // Remote SFTP state
  SftpSession? _sftpSession;
  bool _isRemoteLoading = true;
  String? _remoteErrorMessage;
  String _remoteHomePath = '/';
  String _currentRemotePath = '~/';
  List<SftpName> _remoteItems = [];
  bool _isExternalDraggingOverRemote = false;

  // Local file browser state
  bool _showLocalPane = true;
  double _splitRatio = 0.48;
  bool _isLocalLoading = true;
  String? _localErrorMessage;
  String _currentLocalPath = '';
  List<_LocalFileEntry> _localItems = [];
  bool _isExternalDraggingOverLocal = false;

  // Shared transfer queue & progress state
  int _nextTransferId = 0;
  _TransferJob? _activeTransfer;
  final List<_TransferJob> _transferQueue = [];
  double? _transferProgress;
  String? _transferStatus;

  @override
  void initState() {
    super.initState();
    _currentRemotePath = widget.server.defaultRemotePath.trim().isNotEmpty
        ? widget.server.defaultRemotePath.trim()
        : '~/';
    _initLocalBrowser();
    _initSftp();
  }

  Future<void> _initLocalBrowser() async {
    setState(() {
      _isLocalLoading = true;
      _localErrorMessage = null;
    });

    final candidates = <String>[];
    final envHome = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (envHome != null && envHome.isNotEmpty) {
      // If running inside a macOS sandbox container path, also check the user's real home/Downloads
      final containerMarker = '/Library/Containers/';
      if (envHome.contains(containerMarker)) {
        final realUserHome = envHome.substring(0, envHome.indexOf(containerMarker));
        candidates.add(p.join(realUserHome, 'Downloads'));
        candidates.add(realUserHome);
      }
      candidates.add(p.join(envHome, 'Downloads'));
      candidates.add(envHome);
    }

    try {
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir != null) candidates.add(downloadsDir.path);
    } catch (_) {}

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      candidates.add(docsDir.path);
    } catch (_) {}

    candidates.add(Directory.current.path);

    for (final candidate in candidates) {
      try {
        final dir = Directory(candidate);
        if (await dir.exists()) {
          // Verify read permission before selecting as default
          await dir.list(followLinks: false).take(1).toList();
          await _loadLocalDirectory(candidate);
          return;
        }
      } catch (_) {
        // Try next candidate
      }
    }

    if (mounted) {
      setState(() {
        _currentLocalPath = candidates.isNotEmpty ? candidates.first : '/';
        _isLocalLoading = false;
        _localErrorMessage =
            'Select a local folder to grant read/write access for browsing and drag-and-drop.';
      });
    }
  }

  Future<void> _loadLocalDirectory(String path) async {
    setState(() {
      _isLocalLoading = true;
      _localErrorMessage = null;
    });

    try {
      final dir = Directory(path);
      final rawEntities = await dir.list(followLinks: false).toList();
      final entries = <_LocalFileEntry>[];

      for (final entity in rawEntities) {
        final name = p.basename(entity.path);
        if (name.isEmpty || name == '.' || name == '..') continue;
        try {
          final stat = await entity.stat();
          final isDir = stat.type == FileSystemEntityType.directory;
          entries.add(
            _LocalFileEntry(
              entity: entity,
              name: name,
              path: entity.path,
              isDirectory: isDir,
              size: isDir ? 0 : stat.size,
              modified: stat.modified,
            ),
          );
        } catch (_) {
          // Skip unreadable broken symlinks or restricted system entries
        }
      }

      entries.sort((a, b) {
        final aIsDir = a.isDirectory ? 0 : 1;
        final bIsDir = b.isDirectory ? 0 : 1;
        if (aIsDir != bIsDir) return aIsDir.compareTo(bIsDir);
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      if (mounted) {
        setState(() {
          _currentLocalPath = path;
          _localItems = entries;
          _isLocalLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _currentLocalPath = path;
          _isLocalLoading = false;
          _localErrorMessage = 'Cannot access "$path":\n$e';
        });
      }
    }
  }

  Future<void> _pickLocalDirectory() async {
    final selectedDir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select Local Folder for SFTP Drag & Drop',
      initialDirectory: _currentLocalPath.isNotEmpty ? _currentLocalPath : null,
    );
    if (selectedDir != null && selectedDir.isNotEmpty) {
      await _loadLocalDirectory(selectedDir);
    }
  }

  Future<void> _navigateLocalUp() async {
    if (_currentLocalPath.isEmpty) return;
    final parent = p.dirname(_currentLocalPath);
    if (parent == _currentLocalPath) return;
    await _loadLocalDirectory(parent);
  }

  Future<void> _createLocalFolder() async {
    if (_currentLocalPath.isEmpty) return;
    final folderName = await _promptFolderName('Make Local Directory');
    if (folderName == null || folderName.isEmpty) return;

    try {
      final newDir = Directory(p.join(_currentLocalPath, folderName));
      await newDir.create(recursive: true);
      await _loadLocalDirectory(_currentLocalPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Created local directory "$folderName"')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create local directory: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteLocalEntry(_LocalFileEntry entry) async {
    final isDir = entry.isDirectory;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isDir ? 'Remove Local Directory' : 'Delete Local File'),
        content: Text(
          isDir
              ? 'Are you sure you want to remove local directory "${entry.name}" and its contents?'
              : 'Are you sure you want to delete local file "${entry.name}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(isDir ? 'Remove Directory' : 'Delete File'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await entry.entity.delete(recursive: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isDir
                  ? 'Removed local directory "${entry.name}"'
                  : 'Deleted local file "${entry.name}"',
            ),
          ),
        );
      }
      await _loadLocalDirectory(_currentLocalPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isDir
                  ? 'Failed to remove local directory: $e'
                  : 'Failed to delete local file: $e',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _renameLocalEntry(_LocalFileEntry entry) async {
    final controller = TextEditingController(text: entry.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(entry.isDirectory ? 'Rename Local Directory' : 'Rename Local File'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'New Name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (val) => Navigator.of(ctx).pop(val.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    if (newName == null || newName.isEmpty || newName == entry.name) return;

    try {
      final newPath = p.join(p.dirname(entry.path), newName);
      await entry.entity.rename(newPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Renamed "${entry.name}" to "$newName"')),
        );
      }
      await _loadLocalDirectory(_currentLocalPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to rename local item: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _promptAndRemoveLocalDirectory({required bool isDirectory}) async {
    final candidates = _localItems.where((e) => e.isDirectory == isDirectory).toList();
    if (candidates.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isDirectory
                  ? 'No directories found in the current local folder.'
                  : 'No files found in the current local folder.',
            ),
          ),
        );
      }
      return;
    }

    final selected = await showDialog<_LocalFileEntry>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isDirectory ? 'Remove Local Directory' : 'Delete Local File'),
        content: SizedBox(
          width: 380,
          height: 280,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: candidates.length,
            itemBuilder: (context, index) {
              final item = candidates[index];
              return ListTile(
                dense: true,
                leading: Icon(
                  isDirectory ? Icons.folder : Icons.insert_drive_file,
                  color: isDirectory ? Colors.amber : Colors.blueGrey,
                ),
                title: Text(item.name, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                onTap: () => Navigator.of(ctx).pop(item),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (selected != null) {
      await _deleteLocalEntry(selected);
    }
  }

  Future<void> _initSftp() async {
    setState(() {
      _isRemoteLoading = true;
      _remoteErrorMessage = null;
    });

    try {
      final session = await widget.sshService.startSftpSession(widget.server);
      _sftpSession = session;
      try {
        final realHome = await session.sftp.absolute('.');
        if (realHome.trim().isNotEmpty) {
          _remoteHomePath = realHome.trim();
        }
      } catch (_) {
        _remoteHomePath = widget.server.username == 'root'
            ? '/root'
            : '/home/${widget.server.username}';
      }
      final configuredPath = widget.server.defaultRemotePath.trim().isNotEmpty
          ? widget.server.defaultRemotePath.trim()
          : '~/';
      await _loadRemoteDirectory(configuredPath);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRemoteLoading = false;
          _remoteErrorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _loadRemoteDirectory(String path) async {
    if (_sftpSession == null) return;
    final resolvedPath = SshService.resolveRemotePath(
      path,
      homePath: _remoteHomePath,
    );
    setState(() {
      _isRemoteLoading = true;
      _remoteErrorMessage = null;
    });

    try {
      final rawItems = await _sftpSession!.sftp.listdir(resolvedPath);
      final items = rawItems
          .where((item) => item.filename != '.' && item.filename != '..')
          .toList();

      // Sort directories first, then alphabetical
      items.sort((a, b) {
        final aIsDir = a.attr.isDirectory ? 0 : 1;
        final bIsDir = b.attr.isDirectory ? 0 : 1;
        if (aIsDir != bIsDir) return aIsDir.compareTo(bIsDir);
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });

      if (mounted) {
        setState(() {
          _currentRemotePath = resolvedPath;
          _remoteItems = items;
          _isRemoteLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _currentRemotePath = resolvedPath;
          _isRemoteLoading = false;
          _remoteErrorMessage = 'Failed to list directory "$resolvedPath": $e';
        });
      }
    }
  }

  Future<void> _navigateRemoteUp() async {
    if (_currentRemotePath == '/' || _currentRemotePath.isEmpty) return;
    final parent = p.posix.dirname(_currentRemotePath);
    await _loadRemoteDirectory(parent.isEmpty ? '/' : parent);
  }

  Future<void> _showRemotePathDialog() async {
    final navController = TextEditingController(text: _currentRemotePath);
    final defaultController = TextEditingController(
      text: widget.server.defaultRemotePath.trim().isNotEmpty
          ? widget.server.defaultRemotePath.trim()
          : '~/',
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Remote SFTP Directory'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: navController,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Go to Remote Path',
                    hintText: '~/ or /path/to/dir',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.home_outlined, size: 18),
                      tooltip: 'Set to ~/ ($_remoteHomePath)',
                      onPressed: () => setDialogState(() => navController.text = '~/'),
                    ),
                  ),
                  onSubmitted: (val) {
                    Navigator.of(ctx).pop();
                    if (val.trim().isNotEmpty) {
                      _loadRemoteDirectory(val.trim());
                    }
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: defaultController,
                  decoration: InputDecoration(
                    labelText: 'Default Remote Path for ${widget.server.name}',
                    hintText: '~/',
                    helperText: 'Defaults to ~/ (home). Specify an alternate default path to override.',
                    border: const OutlineInputBorder(),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.my_location, size: 18),
                          tooltip: 'Use current directory ($_currentRemotePath)',
                          onPressed: () =>
                              setDialogState(() => defaultController.text = _currentRemotePath),
                        ),
                        IconButton(
                          icon: const Icon(Icons.home_outlined, size: 18),
                          tooltip: 'Reset default to ~/',
                          onPressed: () => setDialogState(() => defaultController.text = '~/'),
                        ),
                      ],
                    ),
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
              onPressed: () {
                final newDefaultRaw = defaultController.text.trim();
                final effectiveDefault = newDefaultRaw.isEmpty ? '~/' : newDefaultRaw;
                if (effectiveDefault != widget.server.defaultRemotePath) {
                  widget.server.defaultRemotePath = effectiveDefault;
                  widget.server.customRemotePathSet =
                      effectiveDefault != '~/' && effectiveDefault != '~';
                  widget.onDefaultRemotePathChanged?.call(effectiveDefault);
                }
                final targetNav = navController.text.trim();
                Navigator.of(ctx).pop();
                if (targetNav.isNotEmpty) {
                  _loadRemoteDirectory(targetNav);
                }
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _promptFolderName(String title) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Directory Name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (val) => Navigator.of(ctx).pop(val.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _createRemoteFolder() async {
    if (_sftpSession == null) return;
    final folderName = await _promptFolderName('Make Remote Directory');
    if (folderName == null || folderName.isEmpty) return;

    final remoteDir = p.posix.join(_currentRemotePath, folderName);
    try {
      await _sftpSession!.sftp.mkdir(remoteDir);
      await _loadRemoteDirectory(_currentRemotePath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Created remote directory "$folderName"')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create remote directory: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _enqueueUpload(String localPath, {String? targetRemoteDir}) {
    if (_sftpSession == null) return;
    final destDir = targetRemoteDir ?? _currentRemotePath;
    final name = p.basename(localPath);
    final job = _TransferJob(
      id: ++_nextTransferId,
      type: _TransferType.upload,
      name: name,
      sourcePath: localPath,
      targetDir: destDir,
    );
    setState(() {
      _transferQueue.add(job);
    });
    _processTransferQueue();
  }

  Future<void> _enqueueDownloadToLocal({
    required String remotePath,
    required String name,
    required bool isDirectory,
    int? size,
    String? targetLocalDir,
  }) async {
    if (_sftpSession == null) return;
    var destDir = targetLocalDir ?? _currentLocalPath;
    if (destDir.isEmpty) {
      await _pickLocalDirectory();
      if (_currentLocalPath.isEmpty) return;
      destDir = _currentLocalPath;
    }
    final job = _TransferJob(
      id: ++_nextTransferId,
      type: _TransferType.downloadToLocal,
      name: name,
      sourcePath: remotePath,
      targetDir: destDir,
      isDirectory: isDirectory,
      size: size,
    );
    if (mounted) {
      setState(() {
        _transferQueue.add(job);
      });
    }
    _processTransferQueue();
  }

  void _enqueueDownloadSaveAs(SftpName item) {
    if (_sftpSession == null) return;
    final remoteSrc = p.posix.join(_currentRemotePath, item.filename);
    final job = _TransferJob(
      id: ++_nextTransferId,
      type: _TransferType.downloadSaveAs,
      name: item.filename,
      sourcePath: remoteSrc,
      isDirectory: false,
      size: item.attr.size,
    );
    setState(() {
      _transferQueue.add(job);
    });
    _processTransferQueue();
  }

  void _enqueueDownloadAndOpenExternal(SftpName item) {
    if (_sftpSession == null || item.attr.isDirectory) return;
    final remoteSrc = p.posix.join(_currentRemotePath, item.filename);
    final job = _TransferJob(
      id: ++_nextTransferId,
      type: _TransferType.downloadOpenExternal,
      name: item.filename,
      sourcePath: remoteSrc,
      targetDir: _currentLocalPath.isNotEmpty ? _currentLocalPath : null,
      isDirectory: false,
      size: item.attr.size,
    );
    setState(() {
      _transferQueue.add(job);
    });
    _processTransferQueue();
  }

  void _cancelActiveTransfer() {
    if (_activeTransfer == null) return;
    setState(() {
      _activeTransfer!.isCancelled = true;
      _transferStatus = 'Cancelling ${_activeTransfer!.name}...';
    });
  }

  void _cancelQueuedTransfer(_TransferJob job) {
    setState(() {
      job.isCancelled = true;
      _transferQueue.removeWhere((item) => item.id == job.id);
    });
  }

  void _cancelAllTransfers() {
    setState(() {
      for (final job in _transferQueue) {
        job.isCancelled = true;
      }
      _transferQueue.clear();
      if (_activeTransfer != null) {
        _activeTransfer!.isCancelled = true;
        _transferStatus = 'Cancelling ${_activeTransfer!.name}...';
      }
    });
  }

  Future<void> _processTransferQueue() async {
    if (_activeTransfer != null) return;

    while (_transferQueue.isNotEmpty && mounted) {
      final job = _transferQueue.removeAt(0);
      if (job.isCancelled) continue;

      setState(() {
        _activeTransfer = job;
        _transferStatus = job.description;
        _transferProgress = null;
      });

      await _runTransferJob(job);
    }

    if (mounted) {
      setState(() {
        _activeTransfer = null;
        _transferStatus = null;
        _transferProgress = null;
      });
    }
  }

  Future<void> _runTransferJob(_TransferJob job) async {
    switch (job.type) {
      case _TransferType.upload:
        try {
          await _uploadLocalPathToRemote(
            job,
            job.sourcePath,
            targetRemoteDir: job.targetDir!,
          );
          await _loadRemoteDirectory(_currentRemotePath);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Uploaded "${job.name}" to ${job.targetDir}')),
            );
          }
        } on _TransferCancelledException {
          await _loadRemoteDirectory(_currentRemotePath);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Cancelled upload of "${job.name}"')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Upload failed for ${job.name}: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
        break;

      case _TransferType.downloadToLocal:
        try {
          await _downloadRemotePathToLocal(
            job: job,
            remotePath: job.sourcePath,
            name: job.name,
            isDirectory: job.isDirectory,
            size: job.size,
            targetLocalDir: job.targetDir!,
          );
          await _loadLocalDirectory(_currentLocalPath);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Downloaded "${job.name}" to ${job.targetDir}')),
            );
          }
        } on _TransferCancelledException {
          await _loadLocalDirectory(_currentLocalPath);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Cancelled download of "${job.name}"')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Download failed for ${job.name}: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
        break;

      case _TransferType.downloadSaveAs:
        try {
          await _downloadRemoteFileWithSaveAs(job);
        } on _TransferCancelledException {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Cancelled download of "${job.name}"')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Download failed for ${job.name}: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
        break;

      case _TransferType.downloadOpenExternal:
        try {
          final localFilePath = await _downloadRemoteFileForExternalEditor(job);
          if (_currentLocalPath.isNotEmpty &&
              p.equals(p.dirname(localFilePath), _currentLocalPath)) {
            await _loadLocalDirectory(_currentLocalPath);
          }
          await _openLocalFileInExternalEditor(localFilePath);
        } on _TransferCancelledException {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Cancelled opening "${job.name}"')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to open ${job.name}: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
        break;
    }
  }

  /// Uploads a local file or directory (recursively) into [targetRemoteDir].
  Future<void> _uploadLocalPathToRemote(
    _TransferJob job,
    String localPath, {
    required String targetRemoteDir,
  }) async {
    if (_sftpSession == null) return;
    if (job.isCancelled) throw const _TransferCancelledException();

    final type = await FileSystemEntity.type(localPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;

    final name = p.basename(localPath);
    final remoteDest = p.posix.join(targetRemoteDir, name);

    if (type == FileSystemEntityType.directory) {
      if (mounted) {
        setState(() {
          _transferStatus = 'Creating remote folder $name...';
          _transferProgress = null;
        });
      }
      try {
        await _sftpSession!.sftp.mkdir(remoteDest);
      } catch (_) {
        // Directory may already exist
      }

      final children = await Directory(localPath).list(followLinks: false).toList();
      for (final child in children) {
        if (job.isCancelled) throw const _TransferCancelledException();
        final childName = p.basename(child.path);
        if (childName == '.' || childName == '..') continue;
        await _uploadLocalPathToRemote(
          job,
          child.path,
          targetRemoteDir: remoteDest,
        );
      }
      return;
    }

    final localFile = File(localPath);
    if (!await localFile.exists()) return;

    if (mounted) {
      setState(() {
        _transferStatus = 'Uploading $name to $targetRemoteDir...';
        _transferProgress = 0.0;
      });
    }

    final remoteFile = await _sftpSession!.sftp.open(
      remoteDest,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );

    try {
      final totalBytes = await localFile.length();
      await SshService.uploadStreamWithOffsets(
        source: localFile.openRead(),
        isCancelled: () => job.isCancelled,
        writeChunk: (bytes, offset) => remoteFile.writeBytes(
          bytes,
          offset: offset,
        ),
        onProgress: (uploadedBytes) {
          if (mounted && totalBytes > 0) {
            setState(() {
              _transferProgress = (uploadedBytes / totalBytes).clamp(0.0, 1.0);
            });
          }
        },
      );
    } finally {
      await remoteFile.close();
    }

    if (job.isCancelled) {
      try {
        await _sftpSession!.sftp.remove(remoteDest);
      } catch (_) {}
      throw const _TransferCancelledException();
    }
  }

  /// Downloads a remote file or directory (recursively) directly into [targetLocalDir].
  Future<void> _downloadRemotePathToLocal({
    required _TransferJob job,
    required String remotePath,
    required String name,
    required bool isDirectory,
    int? size,
    required String targetLocalDir,
  }) async {
    if (_sftpSession == null) return;
    if (job.isCancelled) throw const _TransferCancelledException();

    final localDestPath = p.join(targetLocalDir, name);

    if (isDirectory) {
      if (mounted) {
        setState(() {
          _transferStatus = 'Downloading folder $name...';
          _transferProgress = null;
        });
      }

      final localDir = Directory(localDestPath);
      if (!await localDir.exists()) {
        await localDir.create(recursive: true);
      }

      final children = await _sftpSession!.sftp.listdir(remotePath);
      for (final child in children) {
        if (job.isCancelled) throw const _TransferCancelledException();
        if (child.filename == '.' || child.filename == '..') continue;
        final childRemotePath = p.posix.join(remotePath, child.filename);
        await _downloadRemotePathToLocal(
          job: job,
          remotePath: childRemotePath,
          name: child.filename,
          isDirectory: child.attr.isDirectory,
          size: child.attr.size,
          targetLocalDir: localDestPath,
        );
      }
      return;
    }

    final totalBytes = size ?? 0;
    if (mounted) {
      setState(() {
        _transferStatus = 'Downloading $name to $targetLocalDir...';
        _transferProgress = totalBytes > 0 ? 0.0 : null;
      });
    }

    final remoteFile = await _sftpSession!.sftp.open(remotePath);
    final localFile = File(localDestPath);
    RandomAccessFile? raf;

    try {
      raf = await localFile.open(mode: FileMode.write);
      var downloadedBytes = 0;
      await for (final chunk in remoteFile.read()) {
        if (job.isCancelled) break;
        await raf.writeFrom(chunk);
        downloadedBytes += chunk.length;
        if (mounted && totalBytes > 0) {
          setState(() {
            _transferProgress = (downloadedBytes / totalBytes).clamp(0.0, 1.0);
          });
        }
      }

      await raf.flush();
      await raf.close();
      raf = null;
    } finally {
      await raf?.close();
      await remoteFile.close();
    }

    if (job.isCancelled) {
      try {
        if (await localFile.exists()) {
          await localFile.delete();
        }
      } catch (_) {}
      throw const _TransferCancelledException();
    }
  }

  void _handleExternalDroppedFilesToRemote(
    List<String> paths, {
    String? targetRemoteDir,
  }) {
    for (final path in paths) {
      _enqueueUpload(
        path,
        targetRemoteDir: targetRemoteDir,
      );
    }
  }

  Future<void> _handleExternalDroppedFilesToLocal(List<String> paths) async {
    if (_currentLocalPath.isEmpty) return;
    for (final srcPath in paths) {
      try {
        final name = p.basename(srcPath);
        final destPath = p.join(_currentLocalPath, name);
        if (p.equals(srcPath, destPath)) continue;
        final type = await FileSystemEntity.type(srcPath, followLinks: false);
        if (type == FileSystemEntityType.file) {
          await File(srcPath).copy(destPath);
        } else if (type == FileSystemEntityType.directory) {
          await _copyDirectoryRecursive(Directory(srcPath), Directory(destPath));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to copy into local folder: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
    await _loadLocalDirectory(_currentLocalPath);
  }

  Future<void> _copyDirectoryRecursive(Directory source, Directory destination) async {
    if (!await destination.exists()) {
      await destination.create(recursive: true);
    }
    await for (final entity in source.list(followLinks: false)) {
      final newPath = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectoryRecursive(entity, Directory(newPath));
      } else if (entity is File) {
        await entity.copy(newPath);
      }
    }
  }

  Future<void> _uploadFileViaPicker() async {
    if (_sftpSession == null) return;
    final result = await FilePicker.pickFiles();
    if (result.isEmpty || result.first.path == null) return;

    _enqueueUpload(result.first.path!);
  }

  Future<void> _removeRemoteDirectoryRecursive(String dirPath) async {
    if (_sftpSession == null) return;
    final children = await _sftpSession!.sftp.listdir(dirPath);
    for (final child in children) {
      if (child.filename == '.' || child.filename == '..') continue;
      final childPath = p.posix.join(dirPath, child.filename);
      if (child.attr.isDirectory) {
        await _removeRemoteDirectoryRecursive(childPath);
      } else {
        await _sftpSession!.sftp.remove(childPath);
      }
    }
    await _sftpSession!.sftp.rmdir(dirPath);
  }

  Future<void> _deleteRemoteFile(SftpName item) async {
    if (_sftpSession == null) return;
    final remoteTarget = p.posix.join(_currentRemotePath, item.filename);
    final isDir = item.attr.isDirectory;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isDir ? 'Remove Remote Directory' : 'Delete Remote File'),
        content: Text(
          isDir
              ? 'Are you sure you want to remove remote directory "${item.filename}" and its contents from the server?'
              : 'Are you sure you want to delete remote file "${item.filename}" from the server?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(isDir ? 'Remove Directory' : 'Delete File'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      if (isDir) {
        await _removeRemoteDirectoryRecursive(remoteTarget);
      } else {
        await _sftpSession!.sftp.remove(remoteTarget);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isDir
                  ? 'Removed remote directory "${item.filename}"'
                  : 'Deleted remote file "${item.filename}"',
            ),
          ),
        );
      }
      await _loadRemoteDirectory(_currentRemotePath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isDir
                  ? 'Failed to remove remote directory: $e'
                  : 'Failed to delete remote file: $e',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _renameRemoteEntry(SftpName item) async {
    if (_sftpSession == null) return;
    final controller = TextEditingController(text: item.filename);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item.attr.isDirectory ? 'Rename Remote Directory' : 'Rename Remote File'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'New Name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (val) => Navigator.of(ctx).pop(val.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    if (newName == null || newName.isEmpty || newName == item.filename) return;

    try {
      final oldPath = p.posix.join(_currentRemotePath, item.filename);
      final newPath = p.posix.join(_currentRemotePath, newName);
      await _sftpSession!.sftp.rename(oldPath, newPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Renamed "${item.filename}" to "$newName"')),
        );
      }
      await _loadRemoteDirectory(_currentRemotePath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to rename remote item: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _promptAndRemoveRemoteItem({required bool isDirectory}) async {
    if (_sftpSession == null) return;
    final candidates = _remoteItems.where((e) => e.attr.isDirectory == isDirectory).toList();
    if (candidates.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isDirectory
                  ? 'No directories found in the current remote folder.'
                  : 'No files found in the current remote folder.',
            ),
          ),
        );
      }
      return;
    }

    final selected = await showDialog<SftpName>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isDirectory ? 'Remove Remote Directory' : 'Delete Remote File'),
        content: SizedBox(
          width: 380,
          height: 280,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: candidates.length,
            itemBuilder: (context, index) {
              final item = candidates[index];
              return ListTile(
                dense: true,
                leading: Icon(
                  isDirectory ? Icons.folder : Icons.insert_drive_file,
                  color: isDirectory ? Colors.amber : Colors.blueGrey,
                ),
                title: Text(item.filename, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                onTap: () => Navigator.of(ctx).pop(item),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (selected != null) {
      await _deleteRemoteFile(selected);
    }
  }

  Future<void> _downloadRemoteFileWithSaveAs(_TransferJob job) async {
    if (_sftpSession == null) return;
    if (job.isCancelled) throw const _TransferCancelledException();

    final remoteSrc = job.sourcePath;
    final totalBytes = job.size ?? 0;
    if (mounted) {
      setState(() {
        _transferStatus = 'Downloading ${job.name}...';
        _transferProgress = totalBytes > 0 ? 0.0 : null;
      });
    }

    final remoteFile = await _sftpSession!.sftp.open(remoteSrc);
    final builder = BytesBuilder();

    try {
      final stream = remoteFile.read();
      var downloadedBytes = 0;

      await for (final chunk in stream) {
        if (job.isCancelled) break;
        builder.add(chunk);
        downloadedBytes += chunk.length;
        if (mounted && totalBytes > 0) {
          setState(() {
            _transferProgress = (downloadedBytes / totalBytes).clamp(0.0, 1.0);
          });
        }
      }
    } finally {
      await remoteFile.close();
    }

    if (job.isCancelled) {
      throw const _TransferCancelledException();
    }

    final bytes = builder.takeBytes();
    final savedUri = await FilePicker.saveFile(
      dialogTitle: 'Save File To...',
      fileName: job.name,
      bytes: bytes,
    );

    if (savedUri != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Downloaded ${job.name} successfully.')),
      );
      if (_currentLocalPath.isNotEmpty) {
        await _loadLocalDirectory(_currentLocalPath);
      }
    }
  }

  static const MethodChannel _fileOpenerChannel =
      MethodChannel('com.mjolnir.app/file_opener');

  /// Downloads a remote file one-way to a local path (preferring [job.targetDir]
  /// if writable, falling back to a temporary directory) so it can be opened
  /// in an external text editor where any saves stay strictly local.
  Future<String> _downloadRemoteFileForExternalEditor(_TransferJob job) async {
    if (_sftpSession == null) {
      throw StateError('No active SFTP session');
    }
    if (job.isCancelled) throw const _TransferCancelledException();

    File? localFile;
    RandomAccessFile? raf;

    if (job.targetDir != null && job.targetDir!.isNotEmpty) {
      try {
        final candidate = File(p.join(job.targetDir!, job.name));
        raf = await candidate.open(mode: FileMode.write);
        localFile = candidate;
      } catch (_) {
        raf = null;
        localFile = null;
      }
    }

    if (localFile == null || raf == null) {
      final tempDir = await getTemporaryDirectory();
      final previewDir = Directory(p.join(tempDir.path, 'mjolnir_sftp'));
      if (!await previewDir.exists()) {
        await previewDir.create(recursive: true);
      }
      localFile = File(p.join(previewDir.path, job.name));
      raf = await localFile.open(mode: FileMode.write);
    }

    final totalBytes = job.size ?? 0;
    if (mounted) {
      setState(() {
        _transferStatus = 'Downloading ${job.name} to open in editor...';
        _transferProgress = totalBytes > 0 ? 0.0 : null;
      });
    }

    final remoteFile = await _sftpSession!.sftp.open(job.sourcePath);
    try {
      var downloadedBytes = 0;
      await for (final chunk in remoteFile.read()) {
        if (job.isCancelled) break;
        await raf.writeFrom(chunk);
        downloadedBytes += chunk.length;
        if (mounted && totalBytes > 0) {
          setState(() {
            _transferProgress = (downloadedBytes / totalBytes).clamp(0.0, 1.0);
          });
        }
      }
      await raf.flush();
      await raf.close();
      raf = null;
    } finally {
      await raf?.close();
      await remoteFile.close();
    }

    if (job.isCancelled) {
      try {
        if (await localFile.exists()) {
          await localFile.delete();
        }
      } catch (_) {}
      throw const _TransferCancelledException();
    }

    return localFile.path;
  }

  /// Opens [localFilePath] in the system's external text editor.
  /// Any modifications saved in the editor remain local and are not uploaded back.
  Future<void> _openLocalFileInExternalEditor(String localFilePath) async {
    try {
      if (Platform.isMacOS) {
        try {
          await _fileOpenerChannel.invokeMethod<bool>(
            'openInTextEditor',
            {'path': localFilePath},
          );
        } on MissingPluginException {
          final result = await Process.run('open', ['-t', localFilePath]);
          if (result.exitCode != 0) {
            throw Exception(result.stderr.toString().trim());
          }
        }
      } else if (Platform.isWindows) {
        await Process.start(
          'notepad.exe',
          [localFilePath],
          mode: ProcessStartMode.detached,
        );
      } else if (Platform.isLinux) {
        await Process.start(
          'xdg-open',
          [localFilePath],
          mode: ProcessStartMode.detached,
        );
      } else {
        throw UnsupportedError('External text editor launch is only supported on desktop platforms.');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Opened in external text editor (local copy: $localFilePath)'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to open in external editor: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showLocalPaneContextMenu(BuildContext context, Offset globalPos) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPos & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        if (_currentLocalPath.isNotEmpty) ...[
          const PopupMenuItem(
            value: 'mkdir',
            child: Row(
              children: [
                Icon(Icons.create_new_folder_outlined, size: 16),
                SizedBox(width: 8),
                Text('Make Directory...'),
              ],
            ),
          ),
          const PopupMenuItem(
            value: 'rmdir',
            child: Row(
              children: [
                Icon(Icons.folder_delete_outlined, size: 16, color: Colors.redAccent),
                SizedBox(width: 8),
                Text('Remove Directory...', style: TextStyle(color: Colors.redAccent)),
              ],
            ),
          ),
          const PopupMenuItem(
            value: 'delete_file',
            child: Row(
              children: [
                Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                SizedBox(width: 8),
                Text('Delete File...', style: TextStyle(color: Colors.redAccent)),
              ],
            ),
          ),
          const PopupMenuDivider(),
        ],
        const PopupMenuItem(
          value: 'choose_folder',
          child: Row(
            children: [
              Icon(Icons.folder_open, size: 16),
              SizedBox(width: 8),
              Text('Choose Local Folder...'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'refresh',
          child: Row(
            children: [
              Icon(Icons.refresh, size: 16),
              SizedBox(width: 8),
              Text('Refresh'),
            ],
          ),
        ),
      ],
    ).then((choice) {
      if (choice == 'mkdir') _createLocalFolder();
      if (choice == 'rmdir') _promptAndRemoveLocalDirectory(isDirectory: true);
      if (choice == 'delete_file') _promptAndRemoveLocalDirectory(isDirectory: false);
      if (choice == 'choose_folder') _pickLocalDirectory();
      if (choice == 'refresh') {
        if (_currentLocalPath.isNotEmpty) {
          _loadLocalDirectory(_currentLocalPath);
        } else {
          _initLocalBrowser();
        }
      }
    });
  }

  void _showRemotePaneContextMenu(BuildContext context, Offset globalPos) {
    if (_sftpSession == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPos & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'mkdir',
          child: Row(
            children: [
              Icon(Icons.create_new_folder_outlined, size: 16),
              SizedBox(width: 8),
              Text('Make Directory...'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'rmdir',
          child: Row(
            children: [
              Icon(Icons.folder_delete_outlined, size: 16, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('Remove Directory...', style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'delete_file',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('Delete File...', style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'upload_file',
          child: Row(
            children: [
              Icon(Icons.upload_file, size: 16),
              SizedBox(width: 8),
              Text('Upload File...'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'refresh',
          child: Row(
            children: [
              Icon(Icons.refresh, size: 16),
              SizedBox(width: 8),
              Text('Refresh'),
            ],
          ),
        ),
      ],
    ).then((choice) {
      if (choice == 'mkdir') _createRemoteFolder();
      if (choice == 'rmdir') _promptAndRemoveRemoteItem(isDirectory: true);
      if (choice == 'delete_file') _promptAndRemoveRemoteItem(isDirectory: false);
      if (choice == 'upload_file') _uploadFileViaPicker();
      if (choice == 'refresh') _loadRemoteDirectory(_currentRemotePath);
    });
  }

  void _showLocalContextMenu(BuildContext context, Offset globalPos, _LocalFileEntry entry) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPos & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        if (entry.isDirectory)
          const PopupMenuItem(
            value: 'open_dir',
            child: Row(
              children: [
                Icon(Icons.folder_open, size: 16),
                SizedBox(width: 8),
                Text('Open Directory'),
              ],
            ),
          )
        else
          const PopupMenuItem(
            value: 'open_editor',
            child: Row(
              children: [
                Icon(Icons.open_in_new, size: 16),
                SizedBox(width: 8),
                Text('Open in External Text Editor'),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'upload',
          child: Row(
            children: [
              const Icon(Icons.upload, size: 16),
              const SizedBox(width: 8),
              Text(entry.isDirectory ? 'Upload Directory to Remote' : 'Upload File to Remote'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'mkdir',
          child: Row(
            children: [
              Icon(Icons.create_new_folder_outlined, size: 16),
              SizedBox(width: 8),
              Text('Make Directory...'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'rename',
          child: Row(
            children: [
              const Icon(Icons.drive_file_rename_outline, size: 16),
              const SizedBox(width: 8),
              Text(entry.isDirectory ? 'Rename Directory...' : 'Rename File...'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(
                entry.isDirectory ? Icons.folder_delete_outlined : Icons.delete_outline,
                size: 16,
                color: Colors.redAccent,
              ),
              const SizedBox(width: 8),
              Text(
                entry.isDirectory ? 'Remove Directory' : 'Delete File',
                style: const TextStyle(color: Colors.redAccent),
              ),
            ],
          ),
        ),
      ],
    ).then((choice) {
      if (choice == 'open_dir') _loadLocalDirectory(entry.path);
      if (choice == 'open_editor') _openLocalFileInExternalEditor(entry.path);
      if (choice == 'upload') _enqueueUpload(entry.path);
      if (choice == 'mkdir') _createLocalFolder();
      if (choice == 'rename') _renameLocalEntry(entry);
      if (choice == 'delete') _deleteLocalEntry(entry);
    });
  }

  void _showRemoteContextMenu(BuildContext context, Offset globalPos, SftpName item) {
    final isDir = item.attr.isDirectory;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final remotePath = p.posix.join(_currentRemotePath, item.filename);

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPos & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        if (isDir)
          const PopupMenuItem(
            value: 'open_dir',
            child: Row(
              children: [
                Icon(Icons.folder_open, size: 16),
                SizedBox(width: 8),
                Text('Open Directory'),
              ],
            ),
          )
        else
          const PopupMenuItem(
            value: 'open_editor',
            child: Row(
              children: [
                Icon(Icons.open_in_new, size: 16),
                SizedBox(width: 8),
                Text('Open in External Text Editor'),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'download_local_pane',
          child: Row(
            children: [
              const Icon(Icons.west, size: 16),
              const SizedBox(width: 8),
              Text(isDir ? 'Download Directory to Local Pane' : 'Download File to Local Pane'),
            ],
          ),
        ),
        if (!isDir)
          const PopupMenuItem(
            value: 'save_as',
            child: Row(
              children: [
                Icon(Icons.download, size: 16),
                SizedBox(width: 8),
                Text('Save File As...'),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'mkdir',
          child: Row(
            children: [
              Icon(Icons.create_new_folder_outlined, size: 16),
              SizedBox(width: 8),
              Text('Make Directory...'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'rename',
          child: Row(
            children: [
              const Icon(Icons.drive_file_rename_outline, size: 16),
              const SizedBox(width: 8),
              Text(isDir ? 'Rename Directory...' : 'Rename File...'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(
                isDir ? Icons.folder_delete_outlined : Icons.delete_outline,
                size: 16,
                color: Colors.redAccent,
              ),
              const SizedBox(width: 8),
              Text(
                isDir ? 'Remove Directory' : 'Delete File',
                style: const TextStyle(color: Colors.redAccent),
              ),
            ],
          ),
        ),
      ],
    ).then((choice) {
      if (choice == 'open_dir') _loadRemoteDirectory(remotePath);
      if (choice == 'open_editor') _enqueueDownloadAndOpenExternal(item);
      if (choice == 'download_local_pane') {
        _enqueueDownloadToLocal(
          remotePath: remotePath,
          name: item.filename,
          isDirectory: isDir,
          size: item.attr.size,
        );
      }
      if (choice == 'save_as') _enqueueDownloadSaveAs(item);
      if (choice == 'mkdir') _createRemoteFolder();
      if (choice == 'rename') _renameRemoteEntry(item);
      if (choice == 'delete') _deleteRemoteFile(item);
    });
  }

  @override
  void dispose() {
    _activeTransfer?.isCancelled = true;
    for (final job in _transferQueue) {
      job.isCancelled = true;
    }
    _transferQueue.clear();
    _sftpSession?.close();
    super.dispose();
  }

  Widget _buildLocalPane(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        // Local Pane Header / Path Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          color: colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              Icon(Icons.computer, size: 16, color: colorScheme.primary),
              const SizedBox(width: 6),
              const Text(
                'Local',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.arrow_upward, size: 18),
                tooltip: 'Parent local directory',
                visualDensity: VisualDensity.compact,
                onPressed: _currentLocalPath.isNotEmpty &&
                        p.dirname(_currentLocalPath) != _currentLocalPath
                    ? _navigateLocalUp
                    : null,
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh local directory',
                visualDensity: VisualDensity.compact,
                onPressed: _currentLocalPath.isNotEmpty
                    ? () => _loadLocalDirectory(_currentLocalPath)
                    : _initLocalBrowser,
              ),
              Expanded(
                child: InkWell(
                  onTap: _pickLocalDirectory,
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _currentLocalPath.isEmpty ? 'Select folder...' : _currentLocalPath,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.folder_open, size: 18),
                tooltip: 'Choose Local Folder...',
                visualDensity: VisualDensity.compact,
                onPressed: _pickLocalDirectory,
              ),
              IconButton(
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                tooltip: 'Make Local Directory',
                visualDensity: VisualDensity.compact,
                onPressed: _currentLocalPath.isNotEmpty ? _createLocalFolder : null,
              ),
            ],
          ),
        ),

        // Local File List + DragTarget for Remote -> Local drops
        Expanded(
          child: DropTarget(
            onDragEntered: (_) => setState(() => _isExternalDraggingOverLocal = true),
            onDragExited: (_) => setState(() => _isExternalDraggingOverLocal = false),
            onDragDone: (detail) {
              setState(() => _isExternalDraggingOverLocal = false);
              final paths = detail.files
                  .map((f) => f.path)
                  .where((p) => p.isNotEmpty)
                  .toList();
              if (paths.isNotEmpty) {
                _handleExternalDroppedFilesToLocal(paths);
              }
            },
            child: DragTarget<_SftpDragPayload>(
              onWillAcceptWithDetails: (details) =>
                  details.data.source == _DragSource.remote,
              onAcceptWithDetails: (details) {
                final payload = details.data;
                _enqueueDownloadToLocal(
                  remotePath: payload.path,
                  name: payload.name,
                  isDirectory: payload.isDirectory,
                  size: payload.size,
                );
              },
              builder: (context, candidateData, rejectedData) {
                final isHighlighted =
                    candidateData.isNotEmpty || _isExternalDraggingOverLocal;

                return GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onSecondaryTapUp: (details) =>
                      _showLocalPaneContextMenu(context, details.globalPosition),
                  onLongPressStart: (details) =>
                      _showLocalPaneContextMenu(context, details.globalPosition),
                  child: Container(
                    decoration: BoxDecoration(
                      border: isHighlighted
                          ? Border.all(color: Colors.lightBlueAccent, width: 2.5)
                          : null,
                      color: isHighlighted
                          ? Colors.lightBlueAccent.withAlpha(20)
                          : Colors.transparent,
                    ),
                    child: Stack(
                      children: [
                        if (_isLocalLoading)
                          const Center(child: CircularProgressIndicator())
                        else if (_localErrorMessage != null)
                          Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.folder_special, color: Colors.amber, size: 40),
                                  const SizedBox(height: 8),
                                  Text(
                                    _localErrorMessage!,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  const SizedBox(height: 12),
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.folder_open, size: 16),
                                    label: const Text('Select Local Folder...'),
                                    onPressed: _pickLocalDirectory,
                                  ),
                                ],
                              ),
                            ),
                          )
                        else if (_localItems.isEmpty)
                          Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'Local directory is empty.\nDrag remote files here to download.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.grey),
                                ),
                                if (_currentLocalPath.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  OutlinedButton.icon(
                                    icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                                    label: const Text('Make Directory'),
                                    onPressed: _createLocalFolder,
                                  ),
                                ],
                              ],
                            ),
                          )
                      else
                        ListView.builder(
                          itemCount: _localItems.length,
                          itemBuilder: (context, index) {
                            final entry = _localItems[index];
                            final payload = _SftpDragPayload(
                              source: _DragSource.local,
                              path: entry.path,
                              name: entry.name,
                              isDirectory: entry.isDirectory,
                              size: entry.size,
                            );

                            return _DraggableTransferRow(
                              payload: payload,
                              acceptsDropFrom: entry.isDirectory ? _DragSource.remote : null,
                              onAcceptDrop: entry.isDirectory
                                  ? (incoming) {
                                      _enqueueDownloadToLocal(
                                        remotePath: incoming.path,
                                        name: incoming.name,
                                        isDirectory: incoming.isDirectory,
                                        size: incoming.size,
                                        targetLocalDir: entry.path,
                                      );
                                    }
                                  : null,
                              child: HoverableFileRow(
                                name: entry.name,
                                subtitle: entry.isDirectory
                                    ? 'Folder'
                                    : '${_formatBytes(entry.size)} • ${_formatDate(entry.modified)}',
                                isDir: entry.isDirectory,
                                primaryActionIcon: Icons.east,
                                primaryActionTooltip: entry.isDirectory
                                    ? 'Upload folder to remote'
                                    : 'Upload to remote',
                                onTap: entry.isDirectory
                                    ? () => _loadLocalDirectory(entry.path)
                                    : null,
                                onPrimaryAction: () => _enqueueUpload(entry.path),
                                onDelete: () => _deleteLocalEntry(entry),
                                onSecondaryTapUp: (details) =>
                                    _showLocalContextMenu(context, details.globalPosition, entry),
                              ),
                            );
                          },
                        ),
                        if (isHighlighted)
                          IgnorePointer(
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                decoration: BoxDecoration(
                                  color: Colors.black.withAlpha(200),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: Colors.lightBlueAccent),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.file_download,
                                        color: Colors.lightBlueAccent, size: 24),
                                    const SizedBox(width: 10),
                                    Text(
                                      'Drop to download into ${p.basename(_currentLocalPath).isEmpty ? _currentLocalPath : p.basename(_currentLocalPath)}',
                                      style: const TextStyle(
                                        color: Colors.lightBlueAccent,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRemotePane(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        // Remote Pane Header / Path Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          color: colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  _showLocalPane ? Icons.vertical_split : Icons.view_sidebar_outlined,
                  size: 18,
                ),
                tooltip: _showLocalPane ? 'Hide Local File Pane' : 'Show Local File Pane',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _showLocalPane = !_showLocalPane),
              ),
              Icon(Icons.dns, size: 16, color: colorScheme.primary),
              const SizedBox(width: 6),
              const Text(
                'Remote',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.arrow_upward, size: 18),
                tooltip: 'Parent remote directory',
                visualDensity: VisualDensity.compact,
                onPressed: _currentRemotePath != '/' ? _navigateRemoteUp : null,
              ),
              IconButton(
                icon: const Icon(Icons.home_outlined, size: 18),
                tooltip: 'Go to Home (~/)',
                visualDensity: VisualDensity.compact,
                onPressed: _sftpSession != null ? () => _loadRemoteDirectory('~/') : null,
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh remote directory',
                visualDensity: VisualDensity.compact,
                onPressed: () => _loadRemoteDirectory(_currentRemotePath),
              ),
              Expanded(
                child: InkWell(
                  onTap: _sftpSession != null ? _showRemotePathDialog : null,
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _currentRemotePath,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.edit_location_alt_outlined, size: 18),
                tooltip: 'Go to Remote Path / Set Default Directory...',
                visualDensity: VisualDensity.compact,
                onPressed: _sftpSession != null ? _showRemotePathDialog : null,
              ),
              IconButton(
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                tooltip: 'Make Remote Directory',
                visualDensity: VisualDensity.compact,
                onPressed: _sftpSession != null ? _createRemoteFolder : null,
              ),
              IconButton(
                icon: const Icon(Icons.upload_file, size: 18),
                tooltip: 'Upload File...',
                visualDensity: VisualDensity.compact,
                onPressed: _uploadFileViaPicker,
              ),
            ],
          ),
        ),

        // Remote File List + DragTarget for Local -> Remote drops + External OS drops
        Expanded(
          child: DropTarget(
            onDragEntered: (_) => setState(() => _isExternalDraggingOverRemote = true),
            onDragExited: (_) => setState(() => _isExternalDraggingOverRemote = false),
            onDragDone: (detail) {
              setState(() => _isExternalDraggingOverRemote = false);
              final paths = detail.files
                  .map((f) => f.path)
                  .where((p) => p.isNotEmpty)
                  .toList();
              if (paths.isNotEmpty) {
                _handleExternalDroppedFilesToRemote(paths);
              }
            },
            child: DragTarget<_SftpDragPayload>(
              onWillAcceptWithDetails: (details) =>
                  details.data.source == _DragSource.local,
              onAcceptWithDetails: (details) {
                _enqueueUpload(details.data.path);
              },
              builder: (context, candidateData, rejectedData) {
                final isHighlighted =
                    candidateData.isNotEmpty || _isExternalDraggingOverRemote;

                return GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onSecondaryTapUp: (details) =>
                      _showRemotePaneContextMenu(context, details.globalPosition),
                  onLongPressStart: (details) =>
                      _showRemotePaneContextMenu(context, details.globalPosition),
                  child: Container(
                    decoration: BoxDecoration(
                      border: isHighlighted
                          ? Border.all(color: Colors.amberAccent, width: 2.5)
                          : null,
                      color: isHighlighted
                          ? Colors.amberAccent.withAlpha(20)
                          : Colors.transparent,
                    ),
                    child: Stack(
                      children: [
                        if (_isRemoteLoading)
                          const Center(child: CircularProgressIndicator())
                        else if (_remoteErrorMessage != null)
                          Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.error_outline, color: Colors.red, size: 40),
                                const SizedBox(height: 8),
                                Text(_remoteErrorMessage!, textAlign: TextAlign.center),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 8,
                                  alignment: WrapAlignment.center,
                                  children: [
                                    ElevatedButton(
                                      onPressed: _initSftp,
                                      child: const Text('Retry Connection'),
                                    ),
                                    if (_sftpSession != null)
                                      OutlinedButton.icon(
                                        icon: const Icon(Icons.home_outlined, size: 16),
                                        label: const Text('Go to Home (~/)'),
                                        onPressed: () => _loadRemoteDirectory('~/'),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          )
                        else if (_remoteItems.isEmpty)
                          Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'Remote directory is empty.\nDrag local files here to upload.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.grey),
                                ),
                                if (_sftpSession != null) ...[
                                  const SizedBox(height: 12),
                                  OutlinedButton.icon(
                                    icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                                    label: const Text('Make Directory'),
                                    onPressed: _createRemoteFolder,
                                  ),
                                ],
                              ],
                            ),
                          )
                        else
                          ListView.builder(
                            itemCount: _remoteItems.length,
                            itemBuilder: (context, index) {
                              final item = _remoteItems[index];
                              final isDir = item.attr.isDirectory;
                              final remoteItemPath =
                                  p.posix.join(_currentRemotePath, item.filename);

                              final payload = _SftpDragPayload(
                                source: _DragSource.remote,
                                path: remoteItemPath,
                                name: item.filename,
                                isDirectory: isDir,
                                size: item.attr.size,
                              );

                              return _DraggableTransferRow(
                                payload: payload,
                                acceptsDropFrom: isDir ? _DragSource.local : null,
                                onAcceptDrop: isDir
                                    ? (incoming) {
                                        _enqueueUpload(
                                          incoming.path,
                                          targetRemoteDir: remoteItemPath,
                                        );
                                      }
                                    : null,
                                child: HoverableFileRow(
                                  name: item.filename,
                                  subtitle: isDir
                                      ? 'Folder'
                                      : '${_formatBytes(item.attr.size ?? 0)} • ${item.attr.modifyTime ?? ''}',
                                  isDir: isDir,
                                  primaryActionIcon: _showLocalPane ? Icons.west : Icons.download,
                                  primaryActionTooltip: _showLocalPane
                                      ? (isDir
                                          ? 'Download folder to local pane'
                                          : 'Download to local pane')
                                      : 'Save file as...',
                                  onTap: isDir
                                      ? () => _loadRemoteDirectory(remoteItemPath)
                                      : null,
                                  onPrimaryAction: () {
                                    if (_showLocalPane && _currentLocalPath.isNotEmpty) {
                                      _enqueueDownloadToLocal(
                                        remotePath: remoteItemPath,
                                        name: item.filename,
                                        isDirectory: isDir,
                                        size: item.attr.size,
                                      );
                                    } else if (!isDir) {
                                      _enqueueDownloadSaveAs(item);
                                    }
                                  },
                                  onDelete: () => _deleteRemoteFile(item),
                                  onSecondaryTapUp: (details) =>
                                      _showRemoteContextMenu(context, details.globalPosition, item),
                                ),
                              );
                            },
                          ),
                        if (isHighlighted)
                          IgnorePointer(
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                decoration: BoxDecoration(
                                  color: Colors.black.withAlpha(200),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: Colors.amberAccent),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.file_upload,
                                        color: Colors.amberAccent, size: 24),
                                    const SizedBox(width: 10),
                                    Text(
                                      'Drop to upload into $_currentRemotePath',
                                      style: const TextStyle(
                                        color: Colors.amberAccent,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} MB';
  }

  static String _formatDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Widget _buildTransferBanner(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: Colors.blue.withAlpha(45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_activeTransfer != null || _transferStatus != null)
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _transferStatus ?? _activeTransfer?.description ?? 'Transferring...',
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_transferQueue.isNotEmpty) ...[
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blueAccent.withAlpha(60),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '+${_transferQueue.length} queued',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
                if (_transferProgress != null) ...[
                  SizedBox(
                    width: 120,
                    child: LinearProgressIndicator(value: _transferProgress),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${((_transferProgress ?? 0) * 100).toInt()}%',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
                const SizedBox(width: 8),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  ),
                  icon: const Icon(Icons.close, size: 15),
                  label: const Text('Cancel', style: TextStyle(fontSize: 12)),
                  onPressed: _activeTransfer != null && !_activeTransfer!.isCancelled
                      ? _cancelActiveTransfer
                      : null,
                ),
                if (_transferQueue.isNotEmpty)
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    ),
                    onPressed: _cancelAllTransfers,
                    child: const Text('Cancel All', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          if (_transferQueue.isNotEmpty) ...[
            const SizedBox(height: 4),
            ..._transferQueue.take(3).map(
                  (queuedJob) => Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        const Icon(Icons.schedule, size: 13, color: Colors.white70),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Queued: ${queuedJob.description}',
                            style: const TextStyle(fontSize: 11, color: Colors.white70),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 14, color: Colors.redAccent),
                          tooltip: 'Remove from queue',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          onPressed: () => _cancelQueuedTransfer(queuedJob),
                        ),
                      ],
                    ),
                  ),
                ),
            if (_transferQueue.length > 3)
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 21),
                child: Text(
                  '...and ${_transferQueue.length - 3} more in queue',
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Optional Assigned Task Banner
        if (widget.assignedTask != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: AssignedTabTaskBanner(
              task: widget.assignedTask!,
              onCompleteTask: () => widget.onCompleteAssignedTask?.call(),
              onUnassignTask: () => widget.onUnassignTask?.call(),
              onTaskChanged: (updatedTask) => widget.onAssignedTaskChanged?.call(updatedTask),
            ),
          ),

        // Transfer Progress & Queue Indicator
        if (_activeTransfer != null || _transferStatus != null || _transferQueue.isNotEmpty)
          _buildTransferBanner(context),

        // Main Dual-Pane or Single-Pane Area
        Expanded(
          child: !_showLocalPane
              ? _buildRemotePane(context)
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final totalWidth = constraints.maxWidth;
                    const dividerWidth = 8.0;
                    final availableWidth = (totalWidth - dividerWidth).clamp(0.0, double.infinity);
                    final leftWidth = availableWidth * _splitRatio;
                    final rightWidth = availableWidth - leftWidth;

                    return Row(
                      children: [
                        SizedBox(
                          width: leftWidth,
                          child: _buildLocalPane(context),
                        ),
                        MouseRegion(
                          cursor: SystemMouseCursors.resizeColumn,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragUpdate: (details) {
                              if (availableWidth <= 0) return;
                              setState(() {
                                _splitRatio = ((_splitRatio * availableWidth + details.delta.dx) /
                                        availableWidth)
                                    .clamp(0.2, 0.8);
                              });
                            },
                            child: Container(
                              width: dividerWidth,
                              color: Theme.of(context).dividerColor.withAlpha(40),
                              child: Center(
                                child: Container(
                                  width: 2,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: Colors.grey.withAlpha(120),
                                    borderRadius: BorderRadius.circular(1),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: rightWidth,
                          child: _buildRemotePane(context),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _DraggableTransferRow extends StatelessWidget {
  final _SftpDragPayload payload;
  final _DragSource? acceptsDropFrom;
  final ValueChanged<_SftpDragPayload>? onAcceptDrop;
  final Widget child;

  const _DraggableTransferRow({
    required this.payload,
    required this.child,
    this.acceptsDropFrom,
    this.onAcceptDrop,
  });

  @override
  Widget build(BuildContext context) {
    Widget rowContent = child;

    if (acceptsDropFrom != null && onAcceptDrop != null) {
      rowContent = DragTarget<_SftpDragPayload>(
        onWillAcceptWithDetails: (details) => details.data.source == acceptsDropFrom,
        onAcceptWithDetails: (details) => onAcceptDrop!(details.data),
        builder: (context, candidateData, rejectedData) {
          final isFolderDropHovered = candidateData.isNotEmpty;
          return Container(
            decoration: isFolderDropHovered
                ? BoxDecoration(
                    color: Colors.amberAccent.withAlpha(35),
                    border: Border.all(color: Colors.amberAccent, width: 1.5),
                  )
                : null,
            child: child,
          );
        },
      );
    }

    return Draggable<_SftpDragPayload>(
      data: payload,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey.shade900.withAlpha(235),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                payload.isDirectory ? Icons.folder : Icons.insert_drive_file,
                color: payload.isDirectory ? Colors.amber : Colors.lightBlueAccent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                payload.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                payload.source == _DragSource.local ? Icons.east : Icons.west,
                color: Colors.amberAccent,
                size: 16,
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.4,
        child: rowContent,
      ),
      child: rowContent,
    );
  }
}

class HoverableFileRow extends StatefulWidget {
  final String name;
  final String subtitle;
  final bool isDir;
  final IconData primaryActionIcon;
  final String primaryActionTooltip;
  final VoidCallback? onTap;
  final VoidCallback? onPrimaryAction;
  final VoidCallback onDelete;
  final Function(TapUpDetails details) onSecondaryTapUp;

  const HoverableFileRow({
    super.key,
    required this.name,
    required this.subtitle,
    required this.isDir,
    required this.primaryActionIcon,
    required this.primaryActionTooltip,
    this.onTap,
    this.onPrimaryAction,
    required this.onDelete,
    required this.onSecondaryTapUp,
  });

  @override
  State<HoverableFileRow> createState() => _HoverableFileRowState();
}

class _HoverableFileRowState extends State<HoverableFileRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isTouchPlatform = Platform.isAndroid || Platform.isIOS;
    final showActions = _isHovered || isTouchPlatform;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onSecondaryTapUp: widget.onSecondaryTapUp,
        onLongPressStart: (details) => widget.onSecondaryTapUp(
          TapUpDetails(
            kind: PointerDeviceKind.touch,
            globalPosition: details.globalPosition,
            localPosition: details.localPosition,
          ),
        ),
        child: Container(
          color: _isHovered ? Colors.white.withAlpha(15) : Colors.transparent,
          child: ListTile(
            dense: true,
            leading: Icon(
              widget.isDir ? Icons.folder : Icons.insert_drive_file,
              color: widget.isDir ? Colors.amber : Colors.blueGrey,
            ),
            title: Text(
              widget.name,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              widget.subtitle,
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
            trailing: showActions
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.onPrimaryAction != null)
                        IconButton(
                          icon: Icon(widget.primaryActionIcon, size: 18),
                          tooltip: widget.primaryActionTooltip,
                          onPressed: widget.onPrimaryAction,
                        ),
                      IconButton(
                        icon: Icon(
                          widget.isDir ? Icons.folder_delete_outlined : Icons.delete_outline,
                          size: 18,
                          color: Colors.redAccent,
                        ),
                        tooltip: widget.isDir ? 'Remove Directory' : 'Delete File',
                        onPressed: widget.onDelete,
                      ),
                    ],
                  )
                : null,
            onTap: widget.onTap,
          ),
        ),
      ),
    );
  }
}
