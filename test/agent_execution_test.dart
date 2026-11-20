import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/agent_controller.dart';
import 'package:pocket_ssh/core/agent_protocol.dart';
import 'package:pocket_ssh/core/agent_remote.dart';
import 'package:pocket_ssh/core/agent_transport.dart';
import 'package:pocket_ssh/core/ai_endpoint.dart';
import 'package:pocket_ssh/core/ssh_connection.dart';

class _Connection extends SshConnection {
  _Connection(this.start);
  final Future<SSHSession> Function() start;
  @override
  Future<SSHSession> executeAgentCommand(AgentToolRequest request) => start();
}

class _Channel implements SSHChannel {
  _Channel(this.onDestroy);
  final void Function() onDestroy;
  @override
  void destroy() => onDestroy();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session implements SSHSession {
  final output = StreamController<Uint8List>(),
      errors = StreamController<Uint8List>(),
      input = StreamController<Uint8List>();
  final completed = Completer<void>();
  bool closed = false;
  SSHSignal? signal;
  @override
  final int? exitCode;
  _Session({this.exitCode = 0}) {
    input.stream.drain<void>();
  }
  @override
  SSHChannel get channel => _Channel(close);
  @override
  StreamSink<Uint8List> get stdin => input.sink;
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
  const command = AgentToolRequest(command: 'printf ok', purpose: '验证');
  test('remote captures stdout stderr and actual nonzero exit code', () async {
    final session = _Session(exitCode: 3);
    session.output.add(Uint8List.fromList(utf8.encode('inactive')));
    session.errors.add(Uint8List.fromList(utf8.encode('permission denied')));
    session.close();
    final result =
        jsonDecode(
              await AgentRemote(
                _Connection(() async => session),
              ).execute(command, AgentCancellation()),
            )
            as Map;
    expect(result['stdout'], 'inactive');
    expect(result['stderr'], 'permission denied');
    expect(result['exit_code'], 3);
  });
  test(
    'large remote output is bounded and incomplete execution is explicit',
    () async {
      final session = _Session(exitCode: null);
      session.output.add(Uint8List(300 * 1024)..fillRange(0, 300 * 1024, 65));
      final result =
          jsonDecode(
                await AgentRemote(
                  _Connection(() async => session),
                ).execute(command, AgentCancellation()),
              )
              as Map;
      expect((result['stdout'] as String).length, 256 * 1024);
      expect(result['truncated'], isTrue);
      expect(session.signal, SSHSignal.TERM);
      expect(session.closed, isTrue);
    },
  );
  test('opening channel failure preserves actual reason and stage', () async {
    final result =
        jsonDecode(
              await AgentRemote(
                _Connection(
                  () async => throw StateError('administratively prohibited'),
                ),
              ).execute(command, AgentCancellation()),
            )
            as Map;
    expect(result['error'], contains('administratively prohibited'));
    expect(result['stage'], 'opening_exec_channel');
    expect(result['exit_code'], isNull);
  });
  test(
    'timeout retains partial output and terminates only its own channel',
    () async {
      final session = _Session(exitCode: null);
      session.output.add(Uint8List.fromList(utf8.encode('partial')));
      final result =
          jsonDecode(
                await AgentRemote(
                  _Connection(() async => session),
                  toolTimeout: const Duration(milliseconds: 20),
                ).execute(command, AgentCancellation()),
              )
              as Map;
      expect(result['timed_out'], isTrue);
      expect(result['stdout'], 'partial');
      expect(session.signal, SSHSignal.TERM);
    },
  );
  test('late session is destroyed after cancellation', () async {
    final pending = Completer<SSHSession>();
    final cancel = AgentCancellation();
    final future = AgentRemote(
      _Connection(() => pending.future),
    ).execute(command, cancel);
    final assertion = expectLater(future, throwsA(isA<AgentCancelled>()));
    cancel.cancel();
    await assertion;
    final session = _Session();
    pending.complete(session);
    await Future<void>.delayed(Duration.zero);
    expect(session.closed, isTrue);
  });

  for (final api in AiApi.values) {
    test(
      '${api.name} HTTP stream uses selected wire protocol and tokens',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final received = Completer<Map>();
        final sub = server.listen((request) async {
          received.complete(
            jsonDecode(await utf8.decoder.bind(request).join()) as Map,
          );
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          void send(Map value) =>
              request.response.write('data: ${jsonEncode(value)}\n\n');
          if (api == AiApi.chat) {
            send({
              'choices': [
                {
                  'delta': {
                    'content': '执行',
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'one',
                        'function': {
                          'name': 'execute_command',
                          'arguments': '{"command":"printf ok",',
                        },
                      },
                    ],
                  },
                },
              ],
            });
            await request.response.flush();
            send({
              'choices': [
                {
                  'delta': {
                    'tool_calls': [
                      {
                        'index': 0,
                        'function': {'arguments': '"purpose":"验证"}'},
                      },
                    ],
                  },
                  'finish_reason': 'tool_calls',
                },
              ],
            });
            send({
              'choices': [],
              'usage': {'prompt_tokens': 123, 'completion_tokens': 30},
            });
            request.response.write('data: [DONE]\n\n');
          } else {
            send({'type': 'response.output_text.delta', 'delta': '执行'});
            await request.response.flush();
            send({
              'type': 'response.completed',
              'response': {
                'status': 'completed',
                'output': [
                  {
                    'type': 'reasoning',
                    'id': 'r1',
                    'summary': [],
                    'encrypted_content': 'encrypted-fixture',
                  },
                  {
                    'type': 'function_call',
                    'id': 'fc1',
                    'call_id': 'one',
                    'name': 'execute_command',
                    'arguments': '{"command":"printf ok","purpose":"验证"}',
                    'status': 'completed',
                  },
                ],
                'usage': {'input_tokens': 123, 'output_tokens': 30},
              },
            });
          }
          await request.response.close();
        });
        addTearDown(sub.cancel);
        final transport = AgentTransport(
          endpoint: aiEndpoint('http://127.0.0.1:${server.port}', api)!,
          model: 'fixture',
          apiKey: null,
          api: api,
          maxOutputTokens: 4096,
        );
        final text = StringBuffer();
        final reply = await transport.request(
          [
            {'role': 'user', 'content': '操作'},
          ],
          AgentCancellation(),
          text.write,
        );
        expect(text.toString(), '执行');
        expect(reply.inputTokens, 123);
        expect(AgentToolRequest.parse(reply.calls.single).command, 'printf ok');
        final body = await received.future;
        if (api == AiApi.chat) {
          expect(body['messages'], isNotNull);
          expect(body['max_completion_tokens'], 4096);
          expect(body.containsKey('input'), isFalse);
        } else {
          expect(body['input'], isNotNull);
          expect(body['max_output_tokens'], 4096);
          expect(body['store'], isFalse);
          final next = AgentTransport.responsesInput([
            reply.toJson(),
            {'role': 'tool', 'tool_call_id': 'one', 'content': 'ok'},
          ]);
          expect(next.first['encrypted_content'], 'encrypted-fixture');
          expect(next.last['type'], 'function_call_output');
          expect(next.last['call_id'], 'one');
        }
      },
    );
  }

  test('Responses truncated tool output never executes', () {
    final parser = ResponsesStreamParser();
    parser.add(
      jsonEncode({
        'type': 'response.incomplete',
        'response': {
          'status': 'incomplete',
          'output': [
            {
              'type': 'function_call',
              'call_id': 'one',
              'name': 'execute_command',
              'arguments': '{}',
            },
          ],
        },
      }),
    );
    expect(parser.complete, throwsFormatException);
  });
  test('Responses incomplete plain text is retained with truncation status', () {
    final parser = ResponsesStreamParser();
    parser.add('{"type":"response.output_text.delta","delta":"partial"}');
    parser.add(
      '{"type":"response.incomplete","response":{"status":"incomplete","output":[]}}',
    );
    expect(parser.complete().text, 'partial');
    expect(parser.complete().truncated, isTrue);
  });
}
