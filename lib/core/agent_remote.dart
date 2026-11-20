import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';

import 'agent_controller.dart';
import 'agent_protocol.dart';
import 'ssh_connection.dart';

class AgentRemote {
  const AgentRemote(
    this.connection, {
    this.toolTimeout = const Duration(seconds: 25),
  });
  final SshConnection connection;
  final Duration toolTimeout;

  Future<String> execute(
    AgentToolRequest request,
    AgentCancellation cancellation,
  ) async {
    cancellation.check();
    final local = AgentCancellation();
    final unregisterParent = cancellation.onCancel(local.cancel);
    var timedOut = false;
    final timer = Timer(toolTimeout, () {
      timedOut = true;
      local.cancel();
    });
    final watch = Stopwatch()..start();
    final stdout = <int>[], stderr = <int>[];
    final subscriptions = <StreamSubscription<List<int>>>[];
    var bytes = 0;
    var truncated = false;
    var streamError = false;
    int? exitCode;
    void Function()? close;
    void Function()? unregister;
    try {
      final pending = connection.executeDiagnostic(request);
      unawaited(
        pending.then<void>((session) {
          if (local.cancelled) {
            try {
              session.kill(SSHSignal.TERM);
            } catch (_) {}
            session.close();
          }
        }, onError: (Object _, StackTrace __) {}),
      );
      final session = await local.wait(pending);
      close = session.close;
      void terminate() {
        try {
          session.kill(SSHSignal.TERM);
        } catch (_) {}
        session.close();
      }

      unregister = local.onCancel(terminate);
      final done = <Future<void>>[];
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
                terminate();
              } else {
                output.addAll(chunk);
                bytes += chunk.length;
              }
            },
            onDone: () {
              if (!completer.isCompleted) completer.complete();
            },
            onError: (Object _) {
              streamError = true;
              if (!completer.isCompleted) completer.complete();
            },
            cancelOnError: true,
          ),
        );
      }

      listen(session.stdout, stdout);
      listen(session.stderr, stderr);
      await local.wait(Future.wait(done));
      await local.wait(session.done);
      exitCode = session.exitCode;
    } on AgentCancelled {
      cancellation.check();
      if (!timedOut) rethrow;
    } finally {
      timer.cancel();
      close?.call();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      unregister?.call();
      unregisterParent();
      local.cancel();
      watch.stop();
    }
    cancellation.check();
    return jsonEncode({
      'command': request.command,
      'exit_code': exitCode,
      'stdout': utf8.decode(stdout, allowMalformed: true),
      'stderr': utf8.decode(stderr, allowMalformed: true),
      'elapsed_ms': watch.elapsedMilliseconds,
      'truncated': truncated,
      'timed_out': timedOut,
      'stream_error': streamError,
      if (timedOut || truncated || streamError)
        'note':
            'Output may be incomplete. The execution channel was closed; remote process termination is not confirmed.',
    });
  }
}
