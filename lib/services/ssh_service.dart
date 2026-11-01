import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' show Sha1;
import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;
import '../models/server_config.dart';
import 'known_hosts_service.dart';

typedef HostKeyPromptHandler = Future<bool> Function({
  required ServerConfig server,
  required String keyType,
  required String fingerprint,
  required bool isMismatch,
  String? previousFingerprint,
});

class SshSession {
  final ServerConfig server;
  final SSHClient client;
  final SSHSession session;

  SshSession({
    required this.server,
    required this.client,
    required this.session,
  });

  bool get isClosed => client.isClosed;
  int? get exitCode => session.exitCode;
  SSHSessionExitSignal? get exitSignal => session.exitSignal;

  void close() {
    try {
      session.close();
      client.close();
    } catch (_) {}
  }
}

class SftpSession {
  final ServerConfig server;
  final SSHClient client;
  final SftpClient sftp;

  SftpSession({
    required this.server,
    required this.client,
    required this.sftp,
  });

  void close() {
    try {
      sftp.close();
      client.close();
    } catch (_) {}
  }
}

class SshService {
  final KnownHostsService knownHostsService;
  HostKeyPromptHandler? hostKeyPromptHandler;

  SshService({
    KnownHostsService? knownHostsService,
    this.hostKeyPromptHandler,
  }) : knownHostsService = knownHostsService ?? KnownHostsService.instance;

  /// Algorithm set that prioritizes modern OpenSSH algorithms while appending
  /// legacy compatibility algorithms (such as `+ssh-rsa` / `SSHHostkeyType.rsaSha1`,
  /// SHA-1 Diffie-Hellman key exchanges, and CBC ciphers) as fallbacks for older
  /// servers and network appliances.
  static const SSHAlgorithms compatibleAlgorithms = SSHAlgorithms(
    kex: [
      SSHKexType.x25519Rfc,
      SSHKexType.x25519,
      SSHKexType.nistp521,
      SSHKexType.nistp384,
      SSHKexType.nistp256,
      SSHKexType.dhGexSha256,
      SSHKexType.dh14Sha256,
      // Legacy fallback key exchange algorithms
      SSHKexType.dhGexSha1,
      SSHKexType.dh14Sha1,
      SSHKexType.dh1Sha1,
    ],
    hostkey: [
      SSHHostkeyType.ed25519,
      SSHHostkeyType.rsaSha512,
      SSHHostkeyType.rsaSha256,
      SSHHostkeyType.ecdsa521,
      SSHHostkeyType.ecdsa384,
      SSHHostkeyType.ecdsa256,
      // Equivalent to OpenSSH `-oHostKeyAlgorithms=+ssh-rsa`
      SSHHostkeyType.rsaSha1,
    ],
    cipher: [
      SSHCipherType.aes256gcm,
      SSHCipherType.aes128gcm,
      SSHCipherType.chacha20poly1305,
      SSHCipherType.aes256ctr,
      SSHCipherType.aes192ctr,
      SSHCipherType.aes128ctr,
      // Legacy CBC fallback ciphers
      SSHCipherType.aes256cbc,
      SSHCipherType.aes192cbc,
      SSHCipherType.aes128cbc,
    ],
    mac: [
      SSHMacType.hmacSha256Etm,
      SSHMacType.hmacSha512Etm,
      SSHMacType.hmacSha256,
      SSHMacType.hmacSha512,
      SSHMacType.hmacSha1,
      // Legacy fallback MACs
      SSHMacType.hmacSha256_96,
      SSHMacType.hmacSha512_96,
      SSHMacType.hmacMd5,
    ],
  );

  /// Expands parsed [SSHKeyPair] identities so that RSA keys try modern
  /// `rsa-sha2-256` first and automatically fall back to legacy `ssh-rsa`
  /// (`PubkeyAcceptedAlgorithms=+ssh-rsa`) if the server only supports SHA-1
  /// RSA public key signatures.
  static List<SSHIdentity> expandIdentitiesWithLegacyRsa(List<SSHKeyPair> pairs) {
    final result = <SSHIdentity>[...pairs];
    for (final pair in pairs) {
      if (pair is OpenSSHRsaKeyPair) {
        result.add(
          _buildLegacyRsaSha1Identity(
            publicKey: pair.toPublicKey(),
            n: pair.n,
            d: pair.d,
            comment: pair.comment,
          ),
        );
      } else if (pair is RsaPrivateKey) {
        result.add(
          _buildLegacyRsaSha1Identity(
            publicKey: pair.toPublicKey(),
            n: pair.n,
            d: pair.d,
            comment: pair.comment,
          ),
        );
      }
    }
    return result;
  }

  static SSHIdentity _buildLegacyRsaSha1Identity({
    required SSHHostKey publicKey,
    required BigInt n,
    required BigInt d,
    String? comment,
  }) {
    return SSHIdentity.custom(
      type: 'ssh-rsa',
      publicKey: publicKey,
      comment: comment,
      shouldProbe: true,
      signer: (Uint8List data) async {
        final sigBytes = await rsaPkcs1v15Sha1Sign(n: n, d: d, message: data);
        return encodeSshSignature('ssh-rsa', sigBytes);
      },
    );
  }

  /// Signs [message] using RSASSA-PKCS1-v1_5 with SHA-1 (`ssh-rsa`, RFC 4253 §6.6).
  static Future<Uint8List> rsaPkcs1v15Sha1Sign({
    required BigInt n,
    required BigInt d,
    required Uint8List message,
  }) async {
    final hash = await Sha1().hash(message);
    // ASN.1 DER DigestInfo prefix for SHA-1 (OID 1.3.14.3.2.26)
    const sha1DigestInfoPrefix = <int>[
      0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e,
      0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14,
    ];
    final t = Uint8List(sha1DigestInfoPrefix.length + hash.bytes.length);
    t.setRange(0, sha1DigestInfoPrefix.length, sha1DigestInfoPrefix);
    t.setRange(sha1DigestInfoPrefix.length, t.length, hash.bytes);

    final k = (n.bitLength + 7) ~/ 8;
    if (k < t.length + 11) {
      throw StateError('RSA modulus too short for PKCS#1 v1.5 SHA-1 signature');
    }

    final em = Uint8List(k);
    em[0] = 0x00;
    em[1] = 0x01;
    final psLen = k - t.length - 3;
    for (var i = 0; i < psLen; i++) {
      em[2 + i] = 0xff;
    }
    em[2 + psLen] = 0x00;
    em.setRange(3 + psLen, k, t);

    var m = BigInt.zero;
    for (final b in em) {
      m = (m << 8) | BigInt.from(b);
    }

    var s = m.modPow(d, n);
    final out = Uint8List(k);
    for (var i = k - 1; i >= 0; i--) {
      out[i] = (s & BigInt.from(0xff)).toInt();
      s = s >> 8;
    }
    return out;
  }

  /// Encodes an SSH signature blob (`string algorithm_name || string signature_bytes`).
  static SSHRawSignature encodeSshSignature(String type, Uint8List signatureBytes) {
    final typeBytes = utf8.encode(type);
    final totalLen = 4 + typeBytes.length + 4 + signatureBytes.length;
    final out = Uint8List(totalLen);
    final view = ByteData.sublistView(out);
    var offset = 0;
    view.setUint32(offset, typeBytes.length);
    offset += 4;
    out.setRange(offset, offset + typeBytes.length, typeBytes);
    offset += typeBytes.length;
    view.setUint32(offset, signatureBytes.length);
    offset += 4;
    out.setRange(offset, offset + signatureBytes.length, signatureBytes);
    return SSHRawSignature(out);
  }

  /// Establish an authenticated SSHClient instance based on server auth settings.
  Future<SSHClient> connect(
    ServerConfig server, {
    HostKeyPromptHandler? onPromptHostKey,
  }) async {
    final credentials = server.decryptedCredentials;
    final socket = await SSHSocket.connect(
      server.host,
      server.port,
      timeout: const Duration(seconds: 15),
    );

    List<SSHIdentity>? identities;
    if (server.authType == AuthType.privateKey &&
        credentials?.privateKey != null &&
        credentials!.privateKey!.trim().isNotEmpty) {
      try {
        final keyPairs = SSHKeyPair.fromPem(
          credentials.privateKey!,
          credentials.passphrase,
        );
        identities = expandIdentitiesWithLegacyRsa(keyPairs);
      } catch (e) {
        socket.close();
        throw Exception('Failed to parse private key: $e');
      }
    }

    final password = credentials?.password;
    final hasPassword = password != null && password.isNotEmpty;

    Exception? hostKeyException;

    final client = SSHClient(
      socket,
      username: server.username,
      algorithms: compatibleAlgorithms,
      identities: identities,
      keepAliveInterval: const Duration(seconds: 25),
      onVerifyHostKey: (type, rawFingerprint) async {
        final fingerprint = utf8.decode(rawFingerprint, allowMalformed: true).trim();
        final host = server.host.trim();
        final port = server.port <= 0 ? 22 : server.port;

        // Check if server config explicitly pins an expected host key fingerprint
        final pinned = server.expectedHostKey?.trim();
        if (pinned != null && pinned.isNotEmpty) {
          if (pinned != fingerprint) {
            hostKeyException = HostKeyMismatchException(
              host: host,
              port: port,
              keyType: type,
              expectedFingerprint: pinned,
              receivedFingerprint: fingerprint,
            );
            return false;
          }
          return true;
        }

        // Verify against KnownHostsService
        final result = await knownHostsService.verifyHostKey(
          host: host,
          port: port,
          keyType: type,
          fingerprint: fingerprint,
        );

        if (result.isTrusted) {
          return true;
        }

        final isMismatch = result.isMismatch;
        final prevFp = result.previousFingerprint;

        final prompter = onPromptHostKey ?? hostKeyPromptHandler;
        if (prompter != null) {
          final accepted = await prompter(
            server: server,
            keyType: type,
            fingerprint: fingerprint,
            isMismatch: isMismatch,
            previousFingerprint: prevFp,
          );

          if (accepted) {
            await knownHostsService.trustHostKey(
              host: host,
              port: port,
              keyType: type,
              fingerprint: fingerprint,
            );
            return true;
          }
        }

        if (isMismatch) {
          hostKeyException = HostKeyMismatchException(
            host: host,
            port: port,
            keyType: type,
            expectedFingerprint: prevFp ?? 'UNKNOWN',
            receivedFingerprint: fingerprint,
          );
        } else {
          hostKeyException = HostKeyUnknownException(
            host: host,
            port: port,
            keyType: type,
            fingerprint: fingerprint,
          );
        }

        return false;
      },
      onPasswordRequest: () {
        if (password != null) {
          return password;
        }
        return '';
      },
      onUserInfoRequest: hasPassword
          ? (request) {
              if (request.prompts.isEmpty) {
                return <String>[];
              }
              return List<String>.filled(request.prompts.length, password);
            }
          : null,
    );

    try {
      // Wait until authenticated
      await client.authenticated;
    } catch (e) {
      if (hostKeyException != null) {
        throw hostKeyException!;
      }
      rethrow;
    }
    return client;
  }

  /// Starts an interactive terminal shell session.
  Future<SshSession> startShellSession(
    ServerConfig server, {
    int terminalWidth = 80,
    int terminalHeight = 24,
    int terminalPixelWidth = 0,
    int terminalPixelHeight = 0,
    int Function()? getTerminalWidth,
    int Function()? getTerminalHeight,
    int Function()? getTerminalPixelWidth,
    int Function()? getTerminalPixelHeight,
    HostKeyPromptHandler? onPromptHostKey,
  }) async {
    final client = await connect(server, onPromptHostKey: onPromptHostKey);
    final width = getTerminalWidth?.call() ?? terminalWidth;
    final height = getTerminalHeight?.call() ?? terminalHeight;
    final pixelWidth = getTerminalPixelWidth?.call() ?? terminalPixelWidth;
    final pixelHeight = getTerminalPixelHeight?.call() ?? terminalPixelHeight;
    final session = await client.shell(
      pty: SSHPtyConfig(
        width: width > 0 ? width : 80,
        height: height > 0 ? height : 24,
        pixelWidth: pixelWidth > 0 ? pixelWidth : 0,
        pixelHeight: pixelHeight > 0 ? pixelHeight : 0,
      ),
    );

    return SshSession(
      server: server,
      client: client,
      session: session,
    );
  }

  /// Opens an SFTP client session.
  Future<SftpSession> startSftpSession(
    ServerConfig server, {
    HostKeyPromptHandler? onPromptHostKey,
  }) async {
    final client = await connect(server, onPromptHostKey: onPromptHostKey);
    final sftp = await client.sftp();
    return SftpSession(
      server: server,
      client: client,
      sftp: sftp,
    );
  }

  /// Resolves an SFTP remote path against [homePath].
  ///
  /// SFTP protocol requests (`SSH_FXP_OPENDIR`, `SSH_FXP_OPEN`, etc.) do not
  /// expand shell tilde (`~` or `~/`). This resolves `~`, `~/`, `~/subdir`,
  /// empty/`.` paths, and relative paths against the resolved remote [homePath].
  static String resolveRemotePath(
    String rawPath, {
    required String homePath,
  }) {
    final normalizedHome = homePath.trim().isEmpty
        ? '/'
        : p.posix.normalize(homePath.trim());
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty || trimmed == '~' || trimmed == '~/' || trimmed == '.') {
      return normalizedHome;
    }
    if (trimmed.startsWith('~/')) {
      final sub = trimmed.substring(2);
      if (sub.isEmpty) return normalizedHome;
      return p.posix.normalize(p.posix.join(normalizedHome, sub));
    }
    if (!trimmed.startsWith('/')) {
      return p.posix.normalize(p.posix.join(normalizedHome, trimmed));
    }
    return p.posix.normalize(trimmed);
  }

  /// Streams chunks from [source] and invokes [writeChunk] with each chunk's
  /// cumulative byte offset so multi-chunk SFTP uploads never overwrite offset 0.
  static Future<int> uploadStreamWithOffsets({
    required Stream<List<int>> source,
    required Future<void> Function(Uint8List chunk, int offset) writeChunk,
    bool Function()? isCancelled,
    void Function(int uploadedBytes)? onProgress,
  }) async {
    var uploadedBytes = 0;
    await for (final chunk in source) {
      if (isCancelled?.call() ?? false) break;
      if (chunk.isEmpty) continue;
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      await writeChunk(bytes, uploadedBytes);
      if (isCancelled?.call() ?? false) break;
      uploadedBytes += bytes.length;
      onProgress?.call(uploadedBytes);
    }
    return uploadedBytes;
  }
}
