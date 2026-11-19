import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';

class SshTarget {
  const SshTarget(this.host, this.port, this.username);

  final String host;
  final int port;
  final String username;

  String get endpoint => '${host.contains(':') ? '[$host]' : host}:$port';
  String get label => '$username@$endpoint';
}

String? normalizeHost(String input) {
  var host = input.trim();
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  final address = InternetAddress.tryParse(host);
  if (address != null) return address.address;
  if (!RegExp(r'^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$').hasMatch(host)) return null;
  return host.toLowerCase();
}

class SshConnection {
  SSHClient? _client;
  SSHSession? _shell;
  bool _closed = false;
  bool get isClosed => _closed;

  Future<SSHSession?> open({
    required SshTarget target,
    required Future<bool> Function(String type, String fingerprint) verify,
    required int columns,
    required int rows,
    String? password,
    Uint8List? privateKey,
    String? passphrase,
    Future<SSHSocket> Function()? dial,
    bool interactive = true,
  }) async {
    List<SSHKeyPair>? identities;
    if (privateKey != null) {
      try {
        identities = SSHKeyPair.fromPem(utf8.decode(privateKey), passphrase);
        if (identities.isEmpty) throw const FormatException();
      } catch (_) {
        throw const FormatException('无法读取私钥，请检查文件格式和私钥口令。');
      } finally {
        privateKey.fillRange(0, privateKey.length, 0);
      }
    }

    final socket =
        await (dial?.call() ??
            SSHSocket.connect(
              target.host,
              target.port,
              timeout: const Duration(seconds: 12),
            ));
    if (_closed) {
      socket.destroy();
      throw StateError('Connection closed');
    }
    final client = _client = SSHClient(
      socket,
      username: target.username,
      identities: identities,
      onPasswordRequest: password == null
          ? null
          : () => _closed ? null : password,
      onVerifyHostKey: (type, fingerprint) async =>
          !_closed && await verify(type, utf8.decode(fingerprint)) && !_closed,
      handshakeTimeout: const Duration(minutes: 2),
      authTimeout: const Duration(seconds: 25),
    );
    try {
      await client.authenticated;
      if (!interactive) return null;
      final session = await client
          .shell(
            pty: SSHPtyConfig(width: columns, height: rows),
          )
          .timeout(const Duration(seconds: 15));
      if (_closed) {
        session.close();
        throw StateError('Connection closed');
      }
      return _shell = session;
    } catch (_) {
      close();
      rethrow;
    }
  }

  Future<SftpClient> sftp() => _client!.sftp();

  Future<SSHForwardChannel> forward(String host, int port) =>
      _client!.forwardLocal(host, port);

  void close() {
    if (_closed) return;
    _closed = true;
    _shell?.close();
    if (_client != null) unawaited(_client!.close());
    _shell = null;
    _client = null;
  }
}

String connectionError(Object error) => switch (error) {
  FormatException(:final message) => message,
  TimeoutException() => '连接超时，请检查网络、端口和服务器状态。',
  SocketException() || SSHSocketError() => '网络连接失败，请检查服务器地址、端口和网络。',
  SSHAuthError() => '认证失败，请检查用户名、密码或私钥。',
  SSHHostkeyError() => '服务器指纹校验未通过。',
  SSHHandshakeError() => 'SSH 握手失败或超时，请检查服务端配置。',
  SSHChannelOpenError() || SSHChannelRequestError() => '服务器无法开启交互终端。',
  PlatformException() => '无法读取或保存服务器信任记录。',
  _ => 'SSH 会话已中断，请检查服务器后重试。',
};
