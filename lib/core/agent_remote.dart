import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';

import 'agent_controller.dart';
import 'agent_protocol.dart';
import 'ssh_connection.dart';

class AgentRemote {
  const AgentRemote(this.connection);
  final SshConnection connection;

  Future<String> execute(
    AgentToolRequest request,
    AgentCancellation cancellation,
  ) async {
    cancellation.check();
    final local = AgentCancellation();
    final unregister = cancellation.onCancel(local.cancel);
    final timer = Timer(const Duration(seconds: 25), local.cancel);
    try {
      if (request.name == 'diagnose') {
        return await _diagnose(request.value, local);
      }
      if (request.name != 'list_directory' && request.name != 'read_file') {
        throw const FormatException('不支持的工具');
      }
      return await _readSftp(request, local);
    } finally {
      timer.cancel();
      unregister();
      local.cancel();
    }
  }

  Future<String> _diagnose(String check, AgentCancellation cancellation) async {
    final pending = connection.executeDiagnostic(check);
    unawaited(
      pending.then<void>((session) {
        if (cancellation.cancelled) session.close();
      }, onError: (Object _, StackTrace __) {}),
    );
    final session = await cancellation.wait(pending);
    final unregister = cancellation.onCancel(session.close);
    final subscriptions = <StreamSubscription<List<int>>>[];
    final done = <Future<void>>[];
    final stdout = <int>[], stderr = <int>[];
    var bytes = 0;
    var truncated = false;
    try {
      void listen(Stream<List<int>> stream, List<int> output) {
        final completer = Completer<void>();
        done.add(completer.future);
        subscriptions.add(
          stream.listen(
            (chunk) {
              if (bytes + chunk.length > 24 * 1024) {
                final remaining = 24 * 1024 - bytes;
                if (remaining > 0) output.addAll(chunk.take(remaining));
                bytes = 24 * 1024;
                truncated = true;
                session.close();
              } else {
                output.addAll(chunk);
                bytes += chunk.length;
              }
            },
            onDone: () {
              if (!completer.isCompleted) completer.complete();
            },
            onError: (Object _) {
              if (!completer.isCompleted) completer.complete();
            },
            cancelOnError: true,
          ),
        );
      }

      listen(session.stdout, stdout);
      listen(session.stderr, stderr);
      await cancellation.wait(Future.wait(done));
      await cancellation.wait(session.done);
      return jsonEncode({
        'check': check,
        'exit_code': session.exitCode,
        'stdout': utf8.decode(stdout, allowMalformed: true),
        'stderr': utf8.decode(stderr, allowMalformed: true),
        'truncated': truncated,
      });
    } finally {
      session.close();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      unregister();
    }
  }

  Future<String> _readSftp(
    AgentToolRequest request,
    AgentCancellation cancellation,
  ) async {
    final pending = connection.sftp();
    unawaited(
      pending.then<void>((client) async {
        if (cancellation.cancelled) await client.close();
      }, onError: (Object _, StackTrace __) {}),
    );
    final client = await cancellation.wait(pending);
    final unregister = cancellation.onCancel(
      () => unawaited(client.close().catchError((_) {})),
    );
    SftpFile? file;
    try {
      if (request.name == 'list_directory') {
        final entries = <Map<String, Object?>>[];
        var bytes = 0;
        var truncated = false;
        await for (final batch in client.readdir(request.value)) {
          cancellation.check();
          for (final entry in batch) {
            if (entry.filename == '.' || entry.filename == '..') continue;
            final value = <String, Object?>{
              'name': entry.filename,
              'type': entry.attr.isDirectory
                  ? 'directory'
                  : entry.attr.isSymbolicLink
                  ? 'link'
                  : 'file',
              'size': entry.attr.size,
            };
            bytes += jsonEncode(value).length;
            if (entries.length >= 200 || bytes > 24000) {
              truncated = true;
              break;
            }
            entries.add(value);
          }
          if (truncated) break;
        }
        return jsonEncode({
          'path': request.value,
          'entries': entries,
          'truncated': truncated,
        });
      }
      file = await cancellation.wait(
        client.open(request.value, mode: SftpFileOpenMode.read),
      );
      final bytes = await cancellation.wait(file!.readBytes(length: 32768));
      if (bytes.contains(0)) throw const FormatException('文件似乎是二进制数据');
      final text = utf8.decode(bytes, allowMalformed: true);
      return jsonEncode({
        'path': request.value,
        'content': text,
        'truncated': bytes.length == 32768,
      });
    } finally {
      try {
        await file?.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
      try {
        await client.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
      unregister();
    }
  }
}
