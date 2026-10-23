import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:path/path.dart' as p;
import '../models/server_config.dart';
import '../models/task_item.dart';
import '../services/ssh_service.dart';
import 'task_manager_tab_widget.dart';

class SftpTabWidget extends StatefulWidget {
  final ServerConfig server;
  final SshService sshService;
  final TaskItem? assignedTask;
  final VoidCallback? onCompleteAssignedTask;
  final VoidCallback? onUnassignTask;

  const SftpTabWidget({
    super.key,
    required this.server,
    required this.sshService,
    this.assignedTask,
    this.onCompleteAssignedTask,
    this.onUnassignTask,
  });

  @override
  State<SftpTabWidget> createState() => _SftpTabWidgetState();
}

class _SftpTabWidgetState extends State<SftpTabWidget> {
  SftpSession? _sftpSession;
  bool _isLoading = true;
  String? _errorMessage;
  String _currentRemotePath = '/';
  List<SftpName> _items = [];
  double? _transferProgress;
  String? _transferStatus;
  bool _isDraggingOver = false;

  @override
  void initState() {
    super.initState();
    _currentRemotePath = widget.server.defaultRemotePath.isNotEmpty
        ? widget.server.defaultRemotePath
        : '/';
    _initSftp();
  }

  Future<void> _initSftp() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final session = await widget.sshService.startSftpSession(widget.server);
      _sftpSession = session;
      await _loadDirectory(_currentRemotePath);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _loadDirectory(String path) async {
    if (_sftpSession == null) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final items = await _sftpSession!.sftp.listdir(path);
      // Sort directories first, then alphabetical
      items.sort((a, b) {
        final aIsDir = a.attr.isDirectory ? 0 : 1;
        final bIsDir = b.attr.isDirectory ? 0 : 1;
        if (aIsDir != bIsDir) return aIsDir.compareTo(bIsDir);
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });

      if (mounted) {
        setState(() {
          _currentRemotePath = path;
          _items = items;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to list directory: $e';
        });
      }
    }
  }

  Future<void> _navigateUp() async {
    if (_currentRemotePath == '/' || _currentRemotePath.isEmpty) return;
    final parent = p.posix.dirname(_currentRemotePath);
    await _loadDirectory(parent.isEmpty ? '/' : parent);
  }

  Future<void> _uploadFilePath(String localPath) async {
    if (_sftpSession == null) return;
    final localFile = File(localPath);
    if (!await localFile.exists()) return;

    final filename = p.basename(localPath);
    final remoteDest = p.posix.join(_currentRemotePath, filename);

    setState(() {
      _transferStatus = 'Uploading $filename...';
      _transferProgress = 0.0;
    });

    try {
      final remoteFile = await _sftpSession!.sftp.open(
        remoteDest,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
      );

      final totalBytes = await localFile.length();
      var uploadedBytes = 0;
      final readStream = localFile.openRead();

      await for (final chunk in readStream) {
        await remoteFile.write(Stream.value(Uint8List.fromList(chunk)));
        uploadedBytes += chunk.length;
        if (mounted && totalBytes > 0) {
          setState(() {
            _transferProgress = uploadedBytes / totalBytes;
          });
        }
      }

      await remoteFile.close();
      await _loadDirectory(_currentRemotePath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed for $filename: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _transferStatus = null;
          _transferProgress = null;
        });
      }
    }
  }

  Future<void> _handleDroppedFiles(List<String> paths) async {
    for (final path in paths) {
      await _uploadFilePath(path);
    }
  }

  Future<void> _uploadFile() async {
    if (_sftpSession == null) return;
    final result = await FilePicker.pickFiles();
    if (result.isEmpty || result.first.path == null) return;

    await _uploadFilePath(result.first.path!);
  }

  Future<void> _deleteRemoteFile(SftpName item) async {
    if (_sftpSession == null) return;
    final remoteTarget = p.posix.join(_currentRemotePath, item.filename);
    final isDir = item.attr.isDirectory;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isDir ? 'Delete Folder' : 'Delete File'),
        content: Text('Are you sure you want to delete "${item.filename}" from the remote server?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      if (isDir) {
        await _sftpSession!.sftp.rmdir(remoteTarget);
      } else {
        await _sftpSession!.sftp.remove(remoteTarget);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "${item.filename}"')),
        );
      }
      await _loadDirectory(_currentRemotePath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _downloadFile(SftpName item) async {
    if (_sftpSession == null) return;
    final remoteSrc = p.posix.join(_currentRemotePath, item.filename);
    final totalBytes = item.attr.size ?? 0;
    setState(() {
      _transferStatus = 'Downloading ${item.filename}...';
      _transferProgress = totalBytes > 0 ? 0.0 : null;
    });

    try {
      final remoteFile = await _sftpSession!.sftp.open(remoteSrc);
      final stream = remoteFile.read();
      final builder = BytesBuilder(copy: false);
      var downloadedBytes = 0;

      await for (final chunk in stream) {
        builder.add(chunk);
        downloadedBytes += chunk.length;
        if (mounted && totalBytes > 0) {
          setState(() {
            _transferProgress = (downloadedBytes / totalBytes).clamp(0.0, 1.0);
          });
        }
      }
      await remoteFile.close();

      final bytes = builder.takeBytes();
      final savedUri = await FilePicker.saveFile(
        dialogTitle: 'Save File To...',
        fileName: item.filename,
        bytes: bytes,
      );

      if (savedUri != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Downloaded ${item.filename} successfully.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _transferStatus = null;
          _transferProgress = null;
        });
      }
    }
  }

  void _showContextMenu(BuildContext context, Offset globalPos, SftpName item) {
    final isDir = item.attr.isDirectory;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPos & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        if (!isDir)
          const PopupMenuItem(
            value: 'download',
            child: Row(
              children: [
                Icon(Icons.download, size: 16),
                SizedBox(width: 8),
                Text('Download...'),
              ],
            ),
          ),
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('Delete', style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    ).then((choice) {
      if (choice == 'download') _downloadFile(item);
      if (choice == 'delete') _deleteRemoteFile(item);
    });
  }

  @override
  void dispose() {
    _sftpSession?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Path navigation bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_upward, size: 20),
                tooltip: 'Go to parent directory',
                onPressed: _currentRemotePath != '/' ? _navigateUp : null,
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: 'Refresh',
                onPressed: () => _loadDirectory(_currentRemotePath),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _currentRemotePath,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (widget.assignedTask != null)
                Flexible(
                  child: AssignedTabTaskBanner(
                    task: widget.assignedTask!,
                    onCompleteTask: () => widget.onCompleteAssignedTask?.call(),
                    onUnassignTask: () => widget.onUnassignTask?.call(),
                  ),
                ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.upload, size: 16),
                label: const Text('Upload'),
                onPressed: _uploadFile,
              ),
            ],
          ),
        ),

        // Transfer Progress Indicator
        if (_transferStatus != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            color: Colors.blue.withAlpha(50),
            child: Row(
              children: [
                Expanded(child: Text(_transferStatus!, style: const TextStyle(fontSize: 12))),
                if (_transferProgress != null) ...[
                  SizedBox(
                    width: 100,
                    child: LinearProgressIndicator(value: _transferProgress),
                  ),
                  const SizedBox(width: 8),
                  Text('${((_transferProgress ?? 0) * 100).toInt()}%',
                      style: const TextStyle(fontSize: 12)),
                ],
              ],
            ),
          ),

        // File List / States with Drag-and-Drop DropTarget
        Expanded(
          child: DropTarget(
            onDragEntered: (_) => setState(() => _isDraggingOver = true),
            onDragExited: (_) => setState(() => _isDraggingOver = false),
            onDragDone: (detail) {
              setState(() => _isDraggingOver = false);
              final paths = detail.files
                  .map((f) => f.path)
                  .where((p) => p.isNotEmpty)
                  .toList();
              if (paths.isNotEmpty) {
                _handleDroppedFiles(paths);
              }
            },
            child: Container(
              decoration: BoxDecoration(
                border: _isDraggingOver
                    ? Border.all(color: Colors.amberAccent, width: 2.5)
                    : null,
                color: _isDraggingOver
                    ? Colors.amberAccent.withAlpha(20)
                    : Colors.transparent,
              ),
              child: Stack(
                children: [
                  _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _errorMessage != null
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.error_outline, color: Colors.red, size: 40),
                                  const SizedBox(height: 8),
                                  Text(_errorMessage!, textAlign: TextAlign.center),
                                  const SizedBox(height: 12),
                                  ElevatedButton(
                                    onPressed: _initSftp,
                                    child: const Text('Retry Connection'),
                                  ),
                                ],
                              ),
                            )
                          : _items.isEmpty
                              ? const Center(
                                  child: Text(
                                    'Directory is empty.\nDrag files here to upload.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Colors.grey),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: _items.length,
                                  itemBuilder: (context, index) {
                                    final item = _items[index];
                                    final isDir = item.attr.isDirectory;

                                    return HoverableFileRow(
                                      item: item,
                                      isDir: isDir,
                                      onTap: () {
                                        if (isDir) {
                                          final nextPath = p.posix.join(_currentRemotePath, item.filename);
                                          _loadDirectory(nextPath);
                                        } else {
                                          _downloadFile(item);
                                        }
                                      },
                                      onDownload: () => _downloadFile(item),
                                      onDelete: () => _deleteRemoteFile(item),
                                      onSecondaryTapUp: (details) => _showContextMenu(context, details.globalPosition, item),
                                    );
                                  },
                                ),
                  if (_isDraggingOver)
                    IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                          decoration: BoxDecoration(
                            color: Colors.black.withAlpha(200),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.amberAccent),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.file_upload, color: Colors.amberAccent, size: 28),
                              SizedBox(width: 12),
                              Text(
                                'Drop files to upload here',
                                style: TextStyle(
                                  color: Colors.amberAccent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
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
          ),
        ),
      ],
    );
  }
}

class HoverableFileRow extends StatefulWidget {
  final SftpName item;
  final bool isDir;
  final VoidCallback onTap;
  final VoidCallback onDownload;
  final VoidCallback onDelete;
  final Function(TapUpDetails details) onSecondaryTapUp;

  const HoverableFileRow({
    super.key,
    required this.item,
    required this.isDir,
    required this.onTap,
    required this.onDownload,
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
            title: Text(widget.item.filename),
            subtitle: Text(
              widget.isDir
                  ? 'Folder'
                  : '${(widget.item.attr.size ?? 0) ~/ 1024} KB • ${widget.item.attr.modifyTime}',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: showActions
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!widget.isDir)
                        IconButton(
                          icon: const Icon(Icons.download, size: 18),
                          tooltip: 'Download file',
                          onPressed: widget.onDownload,
                        ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                        tooltip: 'Delete',
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
