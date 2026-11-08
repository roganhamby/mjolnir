import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

final class _WinSize extends Struct {
  @Uint16()
  external int ws_row;

  @Uint16()
  external int ws_col;

  @Uint16()
  external int ws_xpixel;

  @Uint16()
  external int ws_ypixel;
}

final class _PollFd extends Struct {
  @Int32()
  external int fd;

  @Int16()
  external int events;

  @Int16()
  external int revents;
}

typedef _PollNative = Int32 Function(
  Pointer<_PollFd> fds,
  Uint64 nfds,
  Int32 timeout,
);
typedef _PollDart = int Function(
  Pointer<_PollFd> fds,
  int nfds,
  int timeout,
);

typedef _PosixOpenptNative = Int32 Function(Int32 flags);
typedef _PosixOpenptDart = int Function(int flags);

typedef _IntFdNative = Int32 Function(Int32 fd);
typedef _IntFdDart = int Function(int fd);

typedef _PtsnameNative = Pointer<Uint8> Function(Int32 fd);
typedef _PtsnameDart = Pointer<Uint8> Function(int fd);

typedef _IoctlNative = Int32 Function(
  Int32 fd,
  UnsignedLong request,
  VarArgs<(Pointer<_WinSize>,)>,
);
typedef _IoctlDart = int Function(
  int fd,
  int request,
  Pointer<_WinSize> argp,
);

typedef _ReadNative = IntPtr Function(
  Int32 fd,
  Pointer<Uint8> buf,
  IntPtr count,
);
typedef _ReadDart = int Function(
  int fd,
  Pointer<Uint8> buf,
  int count,
);

typedef _WriteNative = IntPtr Function(
  Int32 fd,
  Pointer<Uint8> buf,
  IntPtr count,
);
typedef _WriteDart = int Function(
  int fd,
  Pointer<Uint8> buf,
  int count,
);

typedef _CloseNative = Int32 Function(Int32 fd);
typedef _CloseDart = int Function(int fd);

typedef _KillNative = Int32 Function(Int32 pid, Int32 sig);
typedef _KillDart = int Function(int pid, int sig);

typedef _WaitPidNative = Int32 Function(
  Int32 pid,
  Pointer<Int32> status,
  Int32 options,
);
typedef _WaitPidDart = int Function(
  int pid,
  Pointer<Int32> status,
  int options,
);

typedef _MallocNative = Pointer<Void> Function(IntPtr size);
typedef _MallocDart = Pointer<Void> Function(int size);

typedef _CallocNative = Pointer<Void> Function(IntPtr nmemb, IntPtr size);
typedef _CallocDart = Pointer<Void> Function(int nmemb, int size);

typedef _FreeNative = Void Function(Pointer<Void> ptr);
typedef _FreeDart = void Function(Pointer<Void> ptr);

typedef _ErrnoLocationNative = Pointer<Int32> Function();
typedef _ErrnoLocationDart = Pointer<Int32> Function();

Pointer<Int32> Function() _lookupErrnoLocation(DynamicLibrary lib) {
  if (Platform.isMacOS || Platform.isIOS) {
    return lib.lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
      '__error',
    );
  }
  return lib.lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
    '__errno_location',
  );
}

bool _isRetryableErrno(int err) {
  const eintr = 4;
  final eagain = (Platform.isMacOS || Platform.isIOS) ? 35 : 11;
  return err == eintr || err == eagain;
}

typedef _SpawnAttrInitNative = Int32 Function(Pointer<Void> attr);
typedef _SpawnAttrInitDart = int Function(Pointer<Void> attr);

typedef _SpawnAttrSetFlagsNative = Int32 Function(
  Pointer<Void> attr,
  Int16 flags,
);
typedef _SpawnAttrSetFlagsDart = int Function(
  Pointer<Void> attr,
  int flags,
);

typedef _PosixSpawnpNative = Int32 Function(
  Pointer<Int32> pid,
  Pointer<Uint8> file,
  Pointer<Void> fileActions,
  Pointer<Void> attrp,
  Pointer<Pointer<Uint8>> argv,
  Pointer<Pointer<Uint8>> envp,
);
typedef _PosixSpawnpDart = int Function(
  Pointer<Int32> pid,
  Pointer<Uint8> file,
  Pointer<Void> fileActions,
  Pointer<Void> attrp,
  Pointer<Pointer<Uint8>> argv,
  Pointer<Pointer<Uint8>> envp,
);

DynamicLibrary _openLibc() {
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.process();
  }
  return DynamicLibrary.open('libc.so.6');
}

String _cStringToDart(Pointer<Uint8> ptr) {
  if (ptr == nullptr) return '';
  final bytes = <int>[];
  var i = 0;
  while (true) {
    final b = (ptr + i).value;
    if (b == 0) break;
    bytes.add(b);
    i++;
  }
  return utf8.decode(bytes, allowMalformed: true);
}

Pointer<Uint8> _dartToCString(String s, _MallocDart malloc) {
  final bytes = utf8.encode(s);
  final ptr = malloc(bytes.length + 1).cast<Uint8>();
  for (var i = 0; i < bytes.length; i++) {
    (ptr + i).value = bytes[i];
  }
  (ptr + bytes.length).value = 0;
  return ptr;
}

class _PtyReaderArgs {
  final int masterFd;
  final int childPid;
  final SendPort sendPort;

  const _PtyReaderArgs({
    required this.masterFd,
    required this.childPid,
    required this.sendPort,
  });
}

void _ptyReaderIsolateEntry(_PtyReaderArgs args) {
  final lib = _openLibc();
  final pollFn = lib.lookupFunction<_PollNative, _PollDart>('poll');
  final readFd = lib.lookupFunction<_ReadNative, _ReadDart>('read');
  final waitpid = lib.lookupFunction<_WaitPidNative, _WaitPidDart>('waitpid');
  final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final calloc = lib.lookupFunction<_CallocNative, _CallocDart>('calloc');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
  final errnoLocation = _lookupErrnoLocation(lib);

  const bufSize = 4096;
  const pollIn = 0x0001;
  const pollErr = 0x0008;
  const pollHup = 0x0010;
  const pollNval = 0x0020;

  final buf = malloc(bufSize).cast<Uint8>();
  final pfd = calloc(1, sizeOf<_PollFd>()).cast<_PollFd>();
  pfd.ref.fd = args.masterFd;
  pfd.ref.events = pollIn;

  try {
    while (true) {
      pfd.ref.revents = 0;
      final pollRc = pollFn(pfd, 1, 100);
      if (pollRc == 0) {
        continue;
      }
      if (pollRc < 0) {
        if (_isRetryableErrno(errnoLocation().value)) {
          continue;
        }
        break;
      }
      final revents = pfd.ref.revents;
      if ((revents & pollNval) != 0) {
        break;
      }
      if ((revents & pollIn) != 0) {
        final n = readFd(args.masterFd, buf, bufSize);
        if (n > 0) {
          final chunk = Uint8List.fromList(buf.asTypedList(n));
          args.sendPort.send(chunk);
        } else if (n < 0 && _isRetryableErrno(errnoLocation().value)) {
          continue;
        } else {
          break;
        }
      } else if ((revents & (pollHup | pollErr)) != 0) {
        break;
      }
    }
  } finally {
    free(pfd.cast());
    free(buf.cast());
  }

  final statusPtr = calloc(1, 4).cast<Int32>();
  int exitCode = 0;
  try {
    // WNOHANG = 1 on both Linux and macOS
    final rc = waitpid(args.childPid, statusPtr, 1);
    if (rc > 0) {
      final rawStatus = statusPtr.value;
      exitCode = (rawStatus >> 8) & 0xff;
    }
  } finally {
    free(statusPtr.cast());
  }

  args.sendPort.send(exitCode);
}

abstract class LocalShellSession {
  String get shellPath;
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  int? get exitCode;
  bool get isClosed;

  void write(Uint8List data);
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]);
  void close();
}

class _PosixPtyShellSession implements LocalShellSession {
  @override
  final String shellPath;
  final int _masterFd;
  final int _childPid;
  final ReceivePort _receivePort;
  Isolate? _readerIsolate;

  final List<Uint8List> _pendingStdout = [];
  late final StreamController<Uint8List> _stdoutController =
      StreamController<Uint8List>.broadcast(
    onListen: () {
      if (_pendingStdout.isNotEmpty) {
        final pending = List<Uint8List>.of(_pendingStdout);
        _pendingStdout.clear();
        for (final chunk in pending) {
          if (!_stdoutController.isClosed) {
            _stdoutController.add(chunk);
          }
        }
      }
    },
  );
  final StreamController<Uint8List> _stderrController =
      StreamController<Uint8List>.broadcast();

  int? _exitCode;
  bool _isClosed = false;

  late final DynamicLibrary _libc = _openLibc();
  late final _WriteDart _writeFd =
      _libc.lookupFunction<_WriteNative, _WriteDart>('write');
  late final _IoctlDart _ioctl =
      _libc.lookupFunction<_IoctlNative, _IoctlDart>('ioctl');
  late final _CloseDart _closeFd =
      _libc.lookupFunction<_CloseNative, _CloseDart>('close');
  late final _KillDart _kill =
      _libc.lookupFunction<_KillNative, _KillDart>('kill');
  late final _MallocDart _malloc =
      _libc.lookupFunction<_MallocNative, _MallocDart>('malloc');
  late final _FreeDart _free =
      _libc.lookupFunction<_FreeNative, _FreeDart>('free');
  late final _ErrnoLocationDart _errnoLocation = _lookupErrnoLocation(_libc);

  _PosixPtyShellSession({
    required this.shellPath,
    required int masterFd,
    required int childPid,
    required ReceivePort receivePort,
    required Isolate readerIsolate,
  })  : _masterFd = masterFd,
        _childPid = childPid,
        _receivePort = receivePort,
        _readerIsolate = readerIsolate {
    _receivePort.listen((message) {
      if (message is Uint8List) {
        if (!_stdoutController.isClosed) {
          if (_stdoutController.hasListener) {
            _stdoutController.add(message);
          } else {
            _pendingStdout.add(message);
          }
        }
      } else if (message is int) {
        _exitCode = message;
        close();
      }
    });
  }

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  int? get exitCode => _exitCode;

  @override
  bool get isClosed => _isClosed;

  @override
  void write(Uint8List data) {
    if (_isClosed || data.isEmpty) return;
    final ptr = _malloc(data.length).cast<Uint8>();
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      var offset = 0;
      while (offset < data.length) {
        final written = _writeFd(
          _masterFd,
          ptr + offset,
          data.length - offset,
        );
        if (written < 0) {
          if (_isRetryableErrno(_errnoLocation().value)) {
            continue;
          }
          break;
        }
        if (written == 0) break;
        offset += written;
      }
    } finally {
      _free(ptr.cast());
    }
  }

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {
    if (_isClosed || width <= 0 || height <= 0) return;
    final winPtr = _malloc(sizeOf<_WinSize>()).cast<_WinSize>();
    try {
      winPtr.ref.ws_row = height;
      winPtr.ref.ws_col = width;
      winPtr.ref.ws_xpixel = pixelWidth > 0 ? pixelWidth : 0;
      winPtr.ref.ws_ypixel = pixelHeight > 0 ? pixelHeight : 0;
      final tiocswinsz = Platform.isMacOS ? 0x80087467 : 0x5414;
      _ioctl(_masterFd, tiocswinsz, winPtr);
    } finally {
      _free(winPtr.cast());
    }
  }

  @override
  void close() {
    if (_isClosed) return;
    _isClosed = true;
    _exitCode ??= 0;
    try {
      // Send SIGHUP (1) and SIGKILL (9) to the session's process group and leader
      _kill(-_childPid, 1);
      _kill(_childPid, 1);
      _kill(-_childPid, 9);
      _kill(_childPid, 9);
    } catch (_) {}
    try {
      _closeFd(_masterFd);
    } catch (_) {}
    _receivePort.close();
    _readerIsolate?.kill(priority: Isolate.immediate);
    _readerIsolate = null;
    if (!_stdoutController.isClosed) {
      _stdoutController.close();
    }
    if (!_stderrController.isClosed) {
      _stderrController.close();
    }
  }
}

class _ProcessFallbackShellSession implements LocalShellSession {
  @override
  final String shellPath;
  final Process _process;
  final StreamController<Uint8List> _stdoutController =
      StreamController<Uint8List>.broadcast();
  final StreamController<Uint8List> _stderrController =
      StreamController<Uint8List>.broadcast();

  int? _exitCode;
  bool _isClosed = false;

  _ProcessFallbackShellSession({
    required this.shellPath,
    required Process process,
  }) : _process = process {
    _process.stdout.listen(
      (data) {
        if (!_stdoutController.isClosed) {
          _stdoutController.add(Uint8List.fromList(data));
        }
      },
      onDone: () {
        if (!_stdoutController.isClosed) {
          _stdoutController.close();
        }
      },
    );
    _process.stderr.listen(
      (data) {
        if (!_stderrController.isClosed) {
          _stderrController.add(Uint8List.fromList(data));
        }
      },
      onDone: () {
        if (!_stderrController.isClosed) {
          _stderrController.close();
        }
      },
    );
    _process.exitCode.then((code) {
      _exitCode = code;
      close();
    });
  }

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  int? get exitCode => _exitCode;

  @override
  bool get isClosed => _isClosed;

  @override
  void write(Uint8List data) {
    if (_isClosed) return;
    _process.stdin.add(data);
  }

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {}

  @override
  void close() {
    if (_isClosed) return;
    _isClosed = true;
    _exitCode ??= 0;
    try {
      _process.kill();
    } catch (_) {}
    if (!_stdoutController.isClosed) {
      _stdoutController.close();
    }
    if (!_stderrController.isClosed) {
      _stderrController.close();
    }
  }
}

class LocalShellService {
  const LocalShellService();

  static String resolveMachineName() {
    try {
      final host = Platform.localHostname.trim();
      if (host.isNotEmpty) {
        return host;
      }
    } catch (_) {}
    final envHost = Platform.environment['HOSTNAME'] ??
        Platform.environment['COMPUTERNAME'];
    if (envHost != null && envHost.trim().isNotEmpty) {
      return envHost.trim();
    }
    return 'localhost';
  }

  String get machineName => resolveMachineName();

  static String resolveDefaultShell() {
    if (Platform.isWindows) {
      return Platform.environment['COMSPEC'] ?? 'powershell.exe';
    }
    final envShell = Platform.environment['SHELL'];
    if (envShell != null && envShell.trim().isNotEmpty) {
      if (File(envShell).existsSync()) {
        return envShell;
      }
    }
    if (Platform.isMacOS && File('/bin/zsh').existsSync()) {
      return '/bin/zsh';
    }
    if (File('/bin/bash').existsSync()) {
      return '/bin/bash';
    }
    return '/bin/sh';
  }

  Future<LocalShellSession> startLocalShellSession({
    int terminalWidth = 80,
    int terminalHeight = 24,
    int terminalPixelWidth = 0,
    int terminalPixelHeight = 0,
  }) async {
    final shell = resolveDefaultShell();

    if (Platform.isLinux || Platform.isMacOS) {
      return _startPosixPtySession(
        shell: shell,
        width: terminalWidth > 0 ? terminalWidth : 80,
        height: terminalHeight > 0 ? terminalHeight : 24,
        pixelWidth: terminalPixelWidth > 0 ? terminalPixelWidth : 0,
        pixelHeight: terminalPixelHeight > 0 ? terminalPixelHeight : 0,
      );
    }

    final homeDir = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'];
    final process = await Process.start(
      shell,
      const [],
      workingDirectory:
          (homeDir != null && Directory(homeDir).existsSync()) ? homeDir : null,
      environment: {
        ...Platform.environment,
        'TERM': 'xterm-256color',
        'COLORTERM': 'truecolor',
      },
    );
    return _ProcessFallbackShellSession(
      shellPath: shell,
      process: process,
    );
  }

  Future<LocalShellSession> _startPosixPtySession({
    required String shell,
    required int width,
    required int height,
    required int pixelWidth,
    required int pixelHeight,
  }) async {
    final lib = _openLibc();
    final posixOpenpt =
        lib.lookupFunction<_PosixOpenptNative, _PosixOpenptDart>('posix_openpt');
    final grantpt = lib.lookupFunction<_IntFdNative, _IntFdDart>('grantpt');
    final unlockpt = lib.lookupFunction<_IntFdNative, _IntFdDart>('unlockpt');
    final ptsname = lib.lookupFunction<_PtsnameNative, _PtsnameDart>('ptsname');
    final ioctl = lib.lookupFunction<_IoctlNative, _IoctlDart>('ioctl');
    final closeFd = lib.lookupFunction<_CloseNative, _CloseDart>('close');
    final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
    final calloc = lib.lookupFunction<_CallocNative, _CallocDart>('calloc');
    final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
    final attrInit =
        lib.lookupFunction<_SpawnAttrInitNative, _SpawnAttrInitDart>(
            'posix_spawnattr_init');
    final attrDestroy =
        lib.lookupFunction<_SpawnAttrInitNative, _SpawnAttrInitDart>(
            'posix_spawnattr_destroy');
    final attrSetFlags =
        lib.lookupFunction<_SpawnAttrSetFlagsNative, _SpawnAttrSetFlagsDart>(
            'posix_spawnattr_setflags');
    final posixSpawnp =
        lib.lookupFunction<_PosixSpawnpNative, _PosixSpawnpDart>('posix_spawnp');

    // O_RDWR (2) | O_NOCTTY (0x20000 on macOS, 0x100 on Linux)
    final openFlags = Platform.isMacOS ? (2 | 0x20000) : (2 | 0x100);
    final masterFd = posixOpenpt(openFlags);
    if (masterFd < 0) {
      throw Exception('Failed to allocate pseudo-terminal (posix_openpt).');
    }

    if (grantpt(masterFd) != 0 || unlockpt(masterFd) != 0) {
      closeFd(masterFd);
      throw Exception('Failed to initialize pseudo-terminal (grantpt/unlockpt).');
    }

    final slavePath = _cStringToDart(ptsname(masterFd));
    if (slavePath.isEmpty) {
      closeFd(masterFd);
      throw Exception('Failed to resolve slave PTY path (ptsname).');
    }

    // Configure initial window dimensions
    final winPtr = malloc(sizeOf<_WinSize>()).cast<_WinSize>();
    try {
      winPtr.ref.ws_row = height;
      winPtr.ref.ws_col = width;
      winPtr.ref.ws_xpixel = pixelWidth;
      winPtr.ref.ws_ypixel = pixelHeight;
      final tiocswinsz = Platform.isMacOS ? 0x80087467 : 0x5414;
      ioctl(masterFd, tiocswinsz, winPtr);
    } finally {
      free(winPtr.cast());
    }

    final attr = calloc(1, 512);
    attrInit(attr);
    // POSIX_SPAWN_SETSID: 0x0400 on macOS, 0x80 on Linux
    final setsidFlag = Platform.isMacOS ? 0x0400 : 0x80;
    attrSetFlags(attr, setsidFlag);

    final pidPtr = calloc(1, 4).cast<Int32>();
    final shPath = _dartToCString('/bin/sh', malloc);
    final arg0 = _dartToCString('/bin/sh', malloc);
    final arg1 = _dartToCString('-c', malloc);
    final arg2 = _dartToCString(
      'cd "\$HOME" 2>/dev/null; exec <"\$0" >"\$0" 2>&1; exec "\$1" -l',
      malloc,
    );
    final arg3 = _dartToCString(slavePath, malloc);
    final arg4 = _dartToCString(shell, malloc);

    final argv = calloc(6, sizeOf<Pointer<Uint8>>()).cast<Pointer<Uint8>>();
    argv[0] = arg0;
    argv[1] = arg1;
    argv[2] = arg2;
    argv[3] = arg3;
    argv[4] = arg4;
    argv[5] = nullptr;

    final envMap = <String, String>{
      ...Platform.environment,
      'TERM': 'xterm-256color',
      'COLORTERM': 'truecolor',
      'SHELL': shell,
    };
    final envEntries = envMap.entries.toList();
    final envp = calloc(
      envEntries.length + 1,
      sizeOf<Pointer<Uint8>>(),
    ).cast<Pointer<Uint8>>();
    final envPtrs = <Pointer<Uint8>>[];
    for (var i = 0; i < envEntries.length; i++) {
      final entryPtr = _dartToCString(
        '${envEntries[i].key}=${envEntries[i].value}',
        malloc,
      );
      envPtrs.add(entryPtr);
      envp[i] = entryPtr;
    }
    envp[envEntries.length] = nullptr;

    int rc;
    int childPid;
    try {
      rc = posixSpawnp(pidPtr, shPath, nullptr, attr, argv, envp);
      childPid = pidPtr.value;
    } finally {
      attrDestroy(attr);
      free(attr);
      free(pidPtr.cast());
      free(shPath.cast());
      free(arg0.cast());
      free(arg1.cast());
      free(arg2.cast());
      free(arg3.cast());
      free(arg4.cast());
      free(argv.cast());
      for (final ptr in envPtrs) {
        free(ptr.cast());
      }
      free(envp.cast());
    }

    if (rc != 0 || childPid <= 0) {
      closeFd(masterFd);
      throw Exception('Failed to spawn local shell "$shell" (errno $rc).');
    }

    final receivePort = ReceivePort();
    final readerIsolate = await Isolate.spawn<_PtyReaderArgs>(
      _ptyReaderIsolateEntry,
      _PtyReaderArgs(
        masterFd: masterFd,
        childPid: childPid,
        sendPort: receivePort.sendPort,
      ),
    );

    return _PosixPtyShellSession(
      shellPath: shell,
      masterFd: masterFd,
      childPid: childPid,
      receivePort: receivePort,
      readerIsolate: readerIsolate,
    );
  }
}
