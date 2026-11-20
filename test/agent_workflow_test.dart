import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/agent_controller.dart';
import 'package:pocket_ssh/core/agent_policy.dart';
import 'package:pocket_ssh/core/agent_transport.dart';
import 'package:pocket_ssh/core/ai_endpoint.dart';

void main() {
  for (final api in AiApi.values) {
    for (final mode in AgentMode.values) {
      test(
        '${api.name}/${mode.name} performs command and returns output through a full agent cycle',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'pocketssh-workflow-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          var turns = 0, approvals = 0, executions = 0;
          final arguments = jsonEncode({
            'command': 'printf done > result.txt; cat result.txt',
            'purpose': '创建并验证测试文件',
            'working_directory': directory.path,
            'timeout_seconds': 30,
          });
          final subscription = server.listen((request) async {
            final body =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            final first = turns++ == 0;
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            );
            void event(Map value) =>
                request.response.write('data: ${jsonEncode(value)}\n\n');
            if (!first) {
              final results = api == AiApi.chat
                  ? (body['messages'] as List).where((m) => m['role'] == 'tool')
                  : (body['input'] as List).where(
                      (m) => m['type'] == 'function_call_output',
                    );
              expect(results.length, 1);
              final result = jsonDecode(
                results.single[api == AiApi.chat ? 'content' : 'output']
                    as String,
              );
              expect(result['stdout'], 'done');
              expect(result['exit_code'], 0);
            }
            if (api == AiApi.chat) {
              event({
                'choices': [
                  {
                    'delta': first
                        ? {
                            'tool_calls': [
                              {
                                'index': 0,
                                'id': 'one',
                                'function': {
                                  'name': 'execute_command',
                                  'arguments': arguments,
                                },
                              },
                            ],
                          }
                        : {'content': '文件已创建并核实'},
                    'finish_reason': first ? 'tool_calls' : 'stop',
                  },
                ],
              });
              request.response.write('data: [DONE]\n\n');
            } else {
              event({
                'type': 'response.completed',
                'response': {
                  'status': 'completed',
                  'output': first
                      ? [
                          {
                            'type': 'function_call',
                            'id': 'fc_one',
                            'call_id': 'one',
                            'name': 'execute_command',
                            'arguments': arguments,
                            'status': 'completed',
                          },
                        ]
                      : [
                          {
                            'type': 'message',
                            'role': 'assistant',
                            'status': 'completed',
                            'content': [
                              {
                                'type': 'output_text',
                                'text': '文件已创建并核实',
                                'annotations': [],
                              },
                            ],
                          },
                        ],
                },
              });
            }
            await request.response.close();
          });
          addTearDown(subscription.cancel);
          final transport = AgentTransport(
            endpoint: aiEndpoint('http://127.0.0.1:${server.port}', api)!,
            model: 'fixture',
            apiKey: null,
            api: api,
          );
          final agent = AgentController(
            requestModel: transport.request,
            connectionIsCurrent: () => true,
            approve: (_, _) async {
              approvals++;
              return true;
            },
            executeTool: (request, _) async {
              executions++;
              final result = await Process.run('/bin/sh', [
                '-c',
                request.shellCommand,
              ]);
              return jsonEncode({
                'stdout': result.stdout,
                'stderr': result.stderr,
                'exit_code': result.exitCode,
              });
            },
          );
          addTearDown(agent.dispose);
          await agent.send('创建测试文件', policy: AgentPolicy(mode: mode));
          expect(agent.error, isNull);
          expect(agent.status, '任务完成');
          expect(executions, 1);
          expect(turns, 2);
          expect(approvals, mode == AgentMode.review ? 1 : 0);
          expect(
            await File('${directory.path}/result.txt').readAsString(),
            'done',
          );
        },
        skip: !Platform.isLinux,
      );
    }
  }
}
