import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';

import 'agent_controller.dart';
import 'agent_protocol.dart';
import 'ssh_connection.dart';

class AgentRemote {
  const AgentRemote(
    this.connection, {
    this.toolTimeout,
    this.maxOutputBytes = 256 * 1024,
  });
  final SshConnection connection;
  final Duration? toolTimeout;
  final int maxOutputBytes;

  void _terminate(SSHSession session) {
    try {
      session.kill(SSHSignal.TERM);
    } catch (_) {}
    session.channel.destroy();
  }

  Future<String> execute(
    AgentToolRequest request,
    AgentCancellation cancellation,
  ) async {
    cancellation.check();
    final local = AgentCancellation();
    final unregisterParent = cancellation.onCancel(local.cancel);
    var timedOut = false;
    final timer = Timer(
      toolTimeout ?? Duration(seconds: request.timeoutSeconds),
      () {
        timedOut = true;
        local.cancel();
      },
    );
    final watch = Stopwatch()..start();
    final stdout = <int>[], stderr = <int>[];
    final subscriptions = <StreamSubscription<List<int>>>[];
    var bytes = 0;
    var truncated = false;
    String? streamError, executionError;
    String stage = 'opening_exec_channel';
    int? exitCode;
    SSHSession? active;
    void Function()? unregister;
    try {
      final pending = connection.executeAgentCommand(request);
      unawaited(
        pending.then<void>((session) {
          if (local.cancelled) _terminate(session);
        }, onError: (Object _, StackTrace __) {}),
      );
      final session = await local.wait(pending);
      active = session;
      stage = 'running_command';
      unregister = local.onCancel(() => _terminate(session));
      final done = <Future<void>>[];
      void listen(Stream<List<int>> stream, List<int> output) {
        final completer = Completer<void>();
        done.add(completer.future);
        subscriptions.add(
          stream.listen(
            (chunk) {
              final remaining = maxOutputBytes - bytes;
              if (chunk.length > remaining) {
                if (remaining > 0) output.addAll(chunk.take(remaining));
                bytes = maxOutputBytes;
                truncated = true;
                _terminate(session);
              } else {
                output.addAll(chunk);
                bytes += chunk.length;
              }
            },
            onDone: () {
              if (!completer.isCompleted) completer.complete();
            },
            onError: (Object error) {
              streamError = error.toString();
              if (!completer.isCompleted) completer.complete();
            },
            cancelOnError: true,
          ),
        );
      }

      listen(session.stdout, stdout);
      listen(session.stderr, stderr);
      unawaited(
        session.stdin.close().catchError((Object error) {
          streamError = error.toString();
        }),
      );
      await local.wait(Future.wait(done));
      await local.wait(session.done);
      exitCode = session.exitCode;
      stage = 'finished';
    } on AgentCancelled {
      cancellation.check();
      if (!timedOut) rethrow;
    } catch (error) {
      executionError = error.toString();
    } finally {
      timer.cancel();
      if (active != null) active.channel.destroy();
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
      'working_directory': request.workingDirectory,
      'stage': stage,
      'exit_code': exitCode,
      'stdout': utf8.decode(stdout, allowMalformed: true),
      'stderr': utf8.decode(stderr, allowMalformed: true),
      'elapsed_ms': watch.elapsedMilliseconds,
      'truncated': truncated,
      'timed_out': timedOut,
      if (streamError != null) 'stream_error': streamError,
      if (executionError != null) 'error': executionError,
      if (timedOut ||
          truncated ||
          executionError != null ||
          streamError != null)
        'note':
            'Output may be incomplete. Remote process termination is not confirmed; verify state before retrying a change.',
    });
  }
}
