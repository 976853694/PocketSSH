import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/agent_controller.dart';
import 'package:pocket_ssh/core/agent_protocol.dart';

AgentToolCall diagnostic({
  String name = 'diagnose',
  String arguments = '{"check":"disks"}',
}) => AgentToolCall(id: 'call-1', name: name, arguments: arguments);

void main() {
  test(
    'stream fragments combine one tool call without executing partial arguments',
    () {
      final parser = AgentStreamParser();
      parser.add(
        jsonEncode({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call-1',
                    'function': {'name': 'diagnose', 'arguments': '{"check":'},
                  },
                ],
              },
            },
          ],
        }),
      );
      expect(() => parser.complete(), throwsFormatException);
      parser.add(
        jsonEncode({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': '"disks"}'},
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        }),
      );
      parser.add('[DONE]');
      final reply = parser.complete();
      expect(AgentToolRequest.parse(reply.calls.single).value, 'disks');
      expect((reply.toJson()['tool_calls'] as List).length, 1);
    },
  );

  test('truncated model tool requests never complete', () {
    final parser = AgentStreamParser();
    parser.add(
      jsonEncode({
        'choices': [
          {
            'delta': {'content': 'partial'},
            'finish_reason': 'length',
          },
        ],
      }),
    );
    expect(() => parser.complete(), throwsFormatException);
  });

  test(
    'tools reject arbitrary commands, unknown tools, extra arguments and traversal',
    () {
      for (final call in [
        diagnostic(name: 'execute_shell'),
        diagnostic(arguments: '{"check":"df -h; reboot"}'),
        diagnostic(arguments: '{"check":"disks","command":"id"}'),
        diagnostic(name: 'read_file', arguments: '{"path":"/etc/../secret"}'),
        diagnostic(name: 'read_file', arguments: '{"path":"relative"}'),
      ]) {
        expect(() => AgentToolRequest.parse(call), throwsFormatException);
      }
    },
  );

  test(
    'a tool needs reading approval and sharing approval before model continues',
    () async {
      final order = <String>[];
      var modelCalls = 0;
      late List<Map<String, Object?>> continuation;
      final agent = AgentController(
        connectionIsCurrent: () => true,
        requestModel: (messages, cancellation, onText) async {
          modelCalls++;
          if (modelCalls == 1) return AgentReply('检查磁盘', [diagnostic()]);
          continuation = List.of(messages);
          order.add('model');
          return const AgentReply('磁盘正常', []);
        },
        approve: (request, result, cancellation) async {
          order.add(result == null ? 'read' : 'share');
          return true;
        },
        executeTool: (request, cancellation) async {
          order.add('execute');
          return 'password=fixture\ndisks: 50%';
        },
      );
      await agent.send('检查磁盘');
      expect(order, ['read', 'execute', 'share', 'model']);
      final output = continuation.last['content'] as String;
      expect(output, contains('[已隐藏]'));
      expect(output, isNot(contains('fixture')));
      expect(agent.status, '任务完成');
      agent.dispose();
    },
  );

  test('declining reading does not execute and does not loop', () async {
    var executions = 0;
    var modelCalls = 0;
    final agent = AgentController(
      connectionIsCurrent: () => true,
      requestModel: (_, _, _) async {
        modelCalls++;
        return AgentReply('', [diagnostic()]);
      },
      approve: (_, _, _) async => false,
      executeTool: (_, _) async {
        executions++;
        return 'unused';
      },
    );
    await agent.send('检查磁盘');
    expect(executions, 0);
    expect(modelCalls, 1);
    expect(agent.error, contains('拒绝'));
    agent.dispose();
  });

  test(
    'declining sharing keeps the tool result off the model request',
    () async {
      var modelCalls = 0;
      var executions = 0;
      final agent = AgentController(
        connectionIsCurrent: () => true,
        requestModel: (_, _, _) async {
          modelCalls++;
          return AgentReply('', [diagnostic()]);
        },
        approve: (_, result, _) async => result == null,
        executeTool: (_, _) async {
          executions++;
          return 'private contents';
        },
      );
      await agent.send('检查磁盘');
      expect(executions, 1);
      expect(modelCalls, 1);
      expect(agent.error, contains('未发送'));
      agent.dispose();
    },
  );

  test('a reconnect invalidates approval before remote reads', () async {
    var current = true;
    var executions = 0;
    final agent = AgentController(
      connectionIsCurrent: () => current,
      requestModel: (_, _, _) async => AgentReply('', [diagnostic()]),
      approve: (_, _, _) async {
        current = false;
        return true;
      },
      executeTool: (_, _) async {
        executions++;
        return '';
      },
    );
    await agent.send('检查磁盘');
    expect(executions, 0);
    expect(agent.error, contains('会话'));
    agent.dispose();
  });

  test(
    'stop while awaiting approval cannot run after a late approve',
    () async {
      final approval = Completer<bool>();
      final requested = Completer<void>();
      var executions = 0;
      final agent = AgentController(
        connectionIsCurrent: () => true,
        requestModel: (_, _, _) async => AgentReply('', [diagnostic()]),
        approve: (_, _, _) {
          requested.complete();
          return approval.future;
        },
        executeTool: (_, _) async {
          executions++;
          return '';
        },
      );
      final task = agent.send('检查磁盘');
      await requested.future;
      agent.stop();
      await task;
      approval.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(executions, 0);
      expect(agent.running, isFalse);
      expect(agent.status, '已停止');
      agent.dispose();
    },
  );

  test(
    'follow-ups retain complete exchanges and clear starts a new conversation',
    () async {
      final requests = <List<Map<String, Object?>>>[];
      final agent = AgentController(
        connectionIsCurrent: () => true,
        requestModel: (messages, _, _) async {
          requests.add(List.of(messages));
          return const AgentReply('回答', []);
        },
        approve: (_, _, _) async => fail('No tool expected'),
        executeTool: (_, _) async => fail('No tool expected'),
      );
      await agent.send('第一个问题');
      await agent.send('继续分析');
      expect(requests.last.length, 4);
      agent.clear();
      await agent.send('新问题');
      expect(requests.last.length, 2);
      agent.dispose();
    },
  );

  test('step limits stop repeated tool calls', () async {
    var executions = 0;
    final agent = AgentController(
      connectionIsCurrent: () => true,
      requestModel: (_, _, _) async => AgentReply('', [diagnostic()]),
      approve: (_, _, _) async => true,
      executeTool: (_, _) async {
        executions++;
        return 'same';
      },
    );
    await agent.send('检查');
    expect(executions, 8);
    expect(agent.error, contains('上限'));
    agent.dispose();
  });
}
