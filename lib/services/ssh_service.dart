import 'dart:async';
import 'package:dartssh2/dartssh2.dart';
import '../models/server_config.dart';

class SshSession {
  final ServerConfig server;
  final SSHClient client;
  final SSHSession session;

  SshSession({
    required this.server,
    required this.client,
    required this.session,
  });

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
  /// Establish an authenticated SSHClient instance based on server auth settings.
  Future<SSHClient> connect(ServerConfig server) async {
    final credentials = server.decryptedCredentials;
    final socket = await SSHSocket.connect(
      server.host,
      server.port,
      timeout: const Duration(seconds: 15),
    );

    List<SSHKeyPair>? identities;
    if (server.authType == AuthType.privateKey &&
        credentials?.privateKey != null &&
        credentials!.privateKey!.trim().isNotEmpty) {
      try {
        identities = SSHKeyPair.fromPem(
          credentials.privateKey!,
          credentials.passphrase,
        );
      } catch (e) {
        socket.close();
        throw Exception('Failed to parse private key: $e');
      }
    }

    final client = SSHClient(
      socket,
      username: server.username,
      identities: identities,
      onPasswordRequest: () {
        if (credentials?.password != null) {
          return credentials!.password!;
        }
        return '';
      },
    );

    // Wait until authenticated
    await client.authenticated;
    return client;
  }

  /// Starts an interactive terminal shell session.
  Future<SshSession> startShellSession(
    ServerConfig server, {
    int terminalWidth = 80,
    int terminalHeight = 24,
  }) async {
    final client = await connect(server);
    final session = await client.shell(
      pty: SSHPtyConfig(
        width: terminalWidth,
        height: terminalHeight,
      ),
    );

    return SshSession(
      server: server,
      client: client,
      session: session,
    );
  }

  /// Opens an SFTP client session.
  Future<SftpSession> startSftpSession(ServerConfig server) async {
    final client = await connect(server);
    final sftp = await client.sftp();
    return SftpSession(
      server: server,
      client: client,
      sftp: sftp,
    );
  }
}
