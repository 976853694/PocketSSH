import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm2/xterm.dart';
import 'app_store.dart';
import 'ssh_connection.dart';

class Sessions extends ChangeNotifier {
  final items = <WorkspaceSession>[];
  void add(WorkspaceSession session) {
    items.add(session);
    session.addListener(notifyListeners);
    notifyListeners();
  }

  void remove(WorkspaceSession session) {
    if (!items.remove(session)) return;
    session.removeListener(notifyListeners);
    session.stop();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final session in items) {
      session.removeListener(notifyListeners);
      session.stop();
    }
    super.dispose();
  }
}

class WorkspaceSession extends ChangeNotifier {
  WorkspaceSession(this.profile, int scrollback)
    : terminal = Terminal(maxLines: scrollback) {
    terminal.onOutput = (text) {
      if (connected) _shell?.write(utf8.encode(text));
    };
    terminal.onResize = (x, y, w, h) {
      if (connected && x > 0 && y > 0) _shell?.resizeTerminal(x, y, w, h);
    };
  }
  final HostProfile profile;
  final Terminal terminal;
  SshConnection connection = SshConnection();
  SshConnection _jump = SshConnection();
  bool opening = false;
  final forwards = <String>[];
  String? transferStatus;
  int transferBytes = 0;
  int? transferTotal;
  Future<void> Function()? retryTransfer;
  VoidCallback? cancelTransfer;
  final _subscriptions = <StreamSubscription<String>>[];
  final _forwards = <ServerSocket>[];
  final _forwardSockets = <Socket>{};
  SSHSession? _shell;
  String status = '正在连接';
  bool connected = false, finished = false;
  bool get forwarding => _forwards.isNotEmpty;

  void updateTransfer() => notifyListeners();

  Future<void> open(
    Credentials credentials,
    Future<bool> Function(SshTarget, String, String) verify, {
    HostProfile? jump,
    Credentials? jumpCredentials,
    Future<void> Function()? onAuthenticated,
    Future<void> Function()? onJumpAuthenticated,
    bool fileOnly = false,
  }) async {
    if (connected || opening) return;
    final reconnecting = finished;
    if (reconnecting) {
      connection = SshConnection();
      _jump = SshConnection();
      _subscriptions.clear();
      _drains.clear();
      finished = false;
    }
    opening = true;
    status = reconnecting ? '正在重新连接' : '正在连接';
    final currentConnection = connection;
    final currentJump = _jump;
    bool isCurrent() => !finished && identical(connection, currentConnection);
    notifyListeners();
    final target = SshTarget(profile.host, profile.port, profile.username);
    Future<SSHSession?> openOn(
      SshConnection conn,
      SshTarget t,
      Credentials c,
      bool key, {
      Future<SSHSocket> Function()? dial,
      bool shell = true,
      Future<void> Function()? onAuthenticated,
    }) => conn
        .open(
          target: t,
          verify: (type, fingerprint) => verify(t, type, fingerprint),
          columns: terminal.viewWidth,
          rows: terminal.viewHeight,
          password: key ? null : c.password,
          privateKey: key ? utf8.encode(c.key) : null,
          passphrase: c.passphrase.isEmpty ? null : c.passphrase,
          dial: dial,
          interactive: shell,
          onStage: (stage) {
            if (!isCurrent()) return;
            status = identical(conn, currentJump) ? '跳板机 · $stage' : stage;
            notifyListeners();
          },
        )
        .then((session) async {
          if (onAuthenticated != null && !conn.isClosed) {
            await onAuthenticated();
          }
          return session;
        });
    try {
      if (jump != null) {
        await openOn(
          _jump,
          SshTarget(jump.host, jump.port, jump.username),
          jumpCredentials!,
          jump.keyAuth,
          shell: false,
          onAuthenticated: onJumpAuthenticated,
        );
      }
      if (!isCurrent()) return;
      final shell = await openOn(
        connection,
        target,
        credentials,
        profile.keyAuth,
        dial: jump == null
            ? null
            : () => _jump
                  .forward(target.host, target.port)
                  .timeout(const Duration(seconds: 15)),
        onAuthenticated: onAuthenticated,
        shell: !fileOnly,
      );
      if (!isCurrent()) return;
      if (fileOnly) {
        opening = false;
        connected = true;
        status = '已连接';
        notifyListeners();
        unawaited(
          currentConnection.done.then<void>(
            (_) {
              if (isCurrent()) stop('SFTP 连接已断开');
            },
            onError: (Object error, StackTrace stack) {
              if (isCurrent()) stop(connectionError(error));
            },
          ),
        );
        return;
      }
      if (shell == null) throw StateError('未创建终端');
      _shell = shell;
      if (reconnecting) terminal.write('\r\n—— 新 SSH 会话 ——\r\n');
      opening = false;
      connected = true;
      status = '已连接';
      notifyListeners();
      _consume(shell.stdout);
      _consume(shell.stderr);
      if (profile.localForwardPort case final localPort?) {
        try {
          final port = await forwardLocal(
            profile.forwardTargetHost,
            profile.forwardTargetPort,
            localPort,
          );
          status = '已连接 · 127.0.0.1:$port 已转发';
        } catch (_) {
          status = '已连接 · 本地转发启动失败';
        }
      }
      notifyListeners();
      await shell.done;
      if (!isCurrent()) return;
      await Future.wait(
        _drains.map((drain) => drain.future).toList(),
      ).timeout(const Duration(seconds: 2));
      if (!isCurrent()) return;
      stop('会话结束${shell.exitCode == null ? '' : ' · ${shell.exitCode}'}');
    } catch (error) {
      if (!isCurrent()) return;
      opening = false;
      stop(connectionError(error));
    }
  }

  void _consume(Stream<Uint8List> stream) {
    final done = Completer<void>();
    _subscriptions.add(
      stream
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            terminal.write,
            onError: (Object error, StackTrace stack) {
              if (!done.isCompleted) done.complete();
              stop(connectionError(error));
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
            cancelOnError: true,
          ),
    );
    _drains.add(done);
  }

  final _drains = <Completer<void>>[];

  Future<int> forwardLocal(String host, int remotePort, int localPort) async {
    if (!connected) throw StateError('连接已关闭');
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      localPort,
    );
    if (!connected) {
      await server.close();
      throw StateError('连接已关闭');
    }
    _forwards.add(server);
    server.listen((socket) async {
      if (!connected || _forwardSockets.length >= 32) {
        socket.destroy();
        return;
      }
      _forwardSockets.add(socket);
      SSHForwardChannel? channel;
      StreamSubscription<List<int>>? outgoing;
      StreamSubscription<Uint8List>? incoming;
      final done = Completer<void>();
      void finish() {
        if (!done.isCompleted) done.complete();
      }

      try {
        channel = await connection
            .forward(host, remotePort)
            .timeout(const Duration(seconds: 15));
        if (!connected) return;
        outgoing = socket.listen(
          channel.sink.add,
          onDone: finish,
          onError: (Object _) => finish(),
        );
        incoming = channel.stream.listen(
          socket.add,
          onDone: finish,
          onError: (Object _) => finish(),
        );
        await done.future;
      } catch (_) {
      } finally {
        await outgoing?.cancel();
        await incoming?.cancel();
        channel?.destroy();
        socket.destroy();
        _forwardSockets.remove(socket);
      }
    });
    final address = '127.0.0.1:${server.port} → $host:$remotePort';
    forwards.add(address);
    notifyListeners();
    return server.port;
  }

  Future<void> stopForwards() async {
    for (final socket in _forwardSockets.toList()) {
      socket.destroy();
    }
    _forwardSockets.clear();
    for (final server in _forwards) {
      await server.close();
    }
    _forwards.clear();
    forwards.clear();
    notifyListeners();
  }

  void stop([String reason = '已断开']) {
    if (finished) return;
    connected = false;
    opening = false;
    finished = true;
    status = reason;
    for (final socket in _forwardSockets.toList()) {
      socket.destroy();
    }
    for (final server in _forwards) {
      unawaited(server.close());
    }
    _forwards.clear();
    forwards.clear();
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    for (final drain in _drains) {
      if (!drain.isCompleted) drain.complete();
    }
    connection.close();
    _jump.close();
    notifyListeners();
  }
}
