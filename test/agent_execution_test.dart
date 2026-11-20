import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/agent_controller.dart';
import 'package:pocket_ssh/core/agent_policy.dart';
import 'package:pocket_ssh/core/agent_protocol.dart';
import 'package:pocket_ssh/core/agent_remote.dart';
import 'package:pocket_ssh/core/agent_transport.dart';
import 'package:pocket_ssh/core/ssh_connection.dart';

class _Connection extends SshConnection {
  _Connection(this.start);
  final Future<SSHSession> Function() start;
  @override
  Future<SSHSession> executeDiagnostic(AgentToolRequest request) => start();
}

class _Session implements SSHSession {
  final output = StreamController<Uint8List>();
  final errors = StreamController<Uint8List>();
  final completed = Completer<void>();
  bool closed = false;
  SSHSignal? signal;
  @override
  final int? exitCode;
  _Session({this.exitCode = 0});
  @override
  Stream<Uint8List> get stdout => output.stream;
  @override
  Stream<Uint8List> get stderr => errors.stream;
  @override
  Future<void> get done => completed.future;
  @override
  void kill(SSHSignal signal) => this.signal = signal;
  @override
  void close() {
    if (closed) return;
    closed = true;
    unawaited(output.close());
    unawaited(errors.close());
    completed.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const request = AgentToolRequest('diagnose', 'disks');
  test('executor preserves stdout, stderr and a nonzero exit code', () async {
    final session = _Session(exitCode: 3);
    session.output.add(Uint8List.fromList(utf8.encode('inactive')));
    session.errors.add(Uint8List.fromList(utf8.encode('permission denied')));
    session.close();
    final remote = AgentRemote(_Connection(() async => session));
    final result =
        jsonDecode(await remote.execute(request, AgentCancellation())) as Map;
    expect(result['stdout'], 'inactive');
    expect(result['stderr'], 'permission denied');
    expect(result['exit_code'], 3);
    expect(result['timed_out'], isFalse);
  });

  test(
    'executor truncates output, signals and closes its own channel',
    () async {
      final session = _Session(exitCode: null);
      session.output.add(Uint8List(30 * 1024)..fillRange(0, 30 * 1024, 65));
      final remote = AgentRemote(_Connection(() async => session));
      final result =
          jsonDecode(await remote.execute(request, AgentCancellation())) as Map;
      expect((result['stdout'] as String).length, 24 * 1024);
      expect(result['truncated'], isTrue);
      expect(result['exit_code'], isNull);
      expect(session.signal, SSHSignal.TERM);
      expect(session.closed, isTrue);
    },
  );

  test(
    'tool timeout retains partial output and does not claim termination',
    () async {
      final session = _Session(exitCode: null);
      session.output.add(Uint8List.fromList(utf8.encode('partial')));
      final remote = AgentRemote(
        _Connection(() async => session),
        toolTimeout: const Duration(milliseconds: 20),
      );
      final result =
          jsonDecode(await remote.execute(request, AgentCancellation())) as Map;
      expect(result['timed_out'], isTrue);
      expect(result['stdout'], 'partial');
      expect(result['note'], contains('not confirmed'));
      expect(session.signal, SSHSignal.TERM);
      expect(session.closed, isTrue);
    },
  );

  test(
    'a session arriving after cancellation is terminated and closed',
    () async {
      final pending = Completer<SSHSession>();
      final cancellation = AgentCancellation();
      final future = AgentRemote(
        _Connection(() => pending.future),
      ).execute(request, cancellation);
      final assertion = expectLater(future, throwsA(isA<AgentCancelled>()));
      cancellation.cancel();
      await assertion;
      final session = _Session();
      pending.complete(session);
      await Future<void>.delayed(Duration.zero);
      expect(session.signal, SSHSignal.TERM);
      expect(session.closed, isTrue);
    },
  );

  test(
    'transport streams tool calls and sends only selected task tools',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final captured = Completer<Map>();
      final subscription = server.listen((request) async {
        captured.complete(
          jsonDecode(await utf8.decoder.bind(request).join()) as Map,
        );
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {
                  'content': '继续检查',
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'one',
                      'function': {'name': 'directory_usage', 'arguments': '{"path":'},
                    },
                  ],
                },
              },
            ],
          })}\n\n',
        );
        await request.response.flush();
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'arguments': '"/var/log"}'},
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          })}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      });
      addTearDown(subscription.cancel);
      final policy = AgentPolicy(kind: AgentTaskKind.disk, target: '/var');
      final transport = AgentTransport(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/chat/completions'),
        model: 'fixture',
        apiKey: null,
        tools: policy.tools,
      );
      final text = StringBuffer();
      final reply = await transport.request(
        [
          {'role': 'user', 'content': '检查'},
        ],
        AgentCancellation(),
        text.write,
      );
      expect(text.toString(), '继续检查');
      expect(AgentToolRequest.parse(reply.calls.single).value, '/var/log');
      final body = await captured.future;
      expect((body['tools'] as List).map((t) => t['function']['name']), [
        'diagnose',
        'directory_usage',
      ]);
    },
  );
}
