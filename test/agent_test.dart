import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/agent_context.dart';
import 'package:pocket_ssh/core/agent_controller.dart';
import 'package:pocket_ssh/core/agent_policy.dart';
import 'package:pocket_ssh/core/agent_protocol.dart';

AgentToolCall call([String id = 'one', String command = 'printf ok']) =>
    AgentToolCall(
      id: id,
      name: 'execute_command',
      arguments: jsonEncode({
        'command': command,
        'purpose': '完成任务',
        'working_directory': '/tmp',
        'timeout_seconds': 120,
      }),
    );
const dangerous = AgentPolicy(mode: AgentMode.dangerous);
const review = AgentPolicy();

void main() {
  test('plain chat never starts diagnostics or executes commands', () async {
    final agent = AgentController(
      connectionIsCurrent: () => false,
      executeTool: (_, _) async => fail('No command requested'),
      requestModel: (messages, _, _) async {
        expect(messages.length, 2);
        return const AgentReply('你好', [], inputTokens: 130);
      },
    );
    await agent.send('你好', policy: review);
    expect(agent.status, '任务完成');
    expect(agent.contextTokens, 130);
    expect(agent.usageEstimated, isFalse);
    agent.dispose();
  });

  test(
    'dangerous mode executes general scripts and continues without approval',
    () async {
      final commands = <String>[];
      var turns = 0;
      final agent = AgentController(
        connectionIsCurrent: () => true,
        approve: (_, _) async => fail('Dangerous mode must not prompt'),
        executeTool: (r, _) async {
          commands.add(r.command);
          return '{"exit_code":0,"stdout":"ok"}';
        },
        requestModel: (messages, _, _) async {
          if (turns++ == 0) {
            return AgentReply('准备创建文件', [
              call('one', 'printf hello > file.txt'),
            ]);
          }
          expect(messages.last['role'], 'tool');
          return const AgentReply('已完成', []);
        },
      );
      await agent.send('创建文件', policy: dangerous);
      expect(commands, ['printf hello > file.txt']);
      expect(agent.status, '任务完成');
      agent.dispose();
    },
  );

  test('review waits for explicit approval before execution', () async {
    final waiting = Completer<void>(), approval = Completer<bool>();
    var executed = 0, models = 0;
    final agent = AgentController(
      connectionIsCurrent: () => true,
      approve: (_, _) {
        waiting.complete();
        return approval.future;
      },
      executeTool: (_, _) async {
        executed++;
        return 'ok';
      },
      requestModel: (_, _, _) async =>
          models++ == 0 ? AgentReply('', [call()]) : const AgentReply('完成', []),
    );
    final task = agent.send('执行任务', policy: review);
    await waiting.future;
    expect(executed, 0);
    approval.complete(true);
    await task;
    expect(executed, 1);
    agent.dispose();
  });

  test(
    'denial stops execution and retains paired interrupted history',
    () async {
      var modelCalls = 0;
      final agent = AgentController(
        connectionIsCurrent: () => true,
        approve: (_, _) async => false,
        executeTool: (_, _) async => fail('Rejected'),
        requestModel: (messages, _, _) async {
          if (modelCalls++ == 0) return AgentReply('', [call()]);
          final tools = messages.where((m) => m['role'] == 'tool');
          expect(tools.length, 1);
          expect(tools.single['content'], contains('interrupted'));
          return const AgentReply('已停止', []);
        },
      );
      await agent.send('执行', policy: review);
      expect(agent.error, contains('拒绝'));
      await agent.send('刚才发生了什么', policy: review);
      agent.dispose();
    },
  );

  test('stop awaiting approval ignores a late approval', () async {
    final waiting = Completer<void>(), approval = Completer<bool>();
    final agent = AgentController(
      connectionIsCurrent: () => true,
      approve: (_, _) {
        waiting.complete();
        return approval.future;
      },
      executeTool: (_, _) async => fail('Stopped'),
      requestModel: (_, _, _) async => AgentReply('', [call()]),
    );
    final task = agent.send('执行', policy: review);
    await waiting.future;
    agent.stop();
    await task;
    approval.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(agent.status, '已停止');
    agent.dispose();
  });

  test('connection replacement invalidates a reviewed command', () async {
    var current = true;
    final agent = AgentController(
      connectionIsCurrent: () => current,
      approve: (_, _) async {
        current = false;
        return true;
      },
      executeTool: (_, _) async => fail('Connection changed'),
      requestModel: (_, _, _) async => AgentReply('', [call()]),
    );
    await agent.send('执行', policy: review);
    expect(agent.error, contains('授权失效'));
    agent.dispose();
  });

  test(
    'errors retain actual cause and are returned without automatic replay',
    () async {
      var turns = 0, executions = 0;
      final agent = AgentController(
        connectionIsCurrent: () => true,
        executeTool: (_, _) async {
          executions++;
          throw StateError('channel open denied');
        },
        requestModel: (messages, _, _) async {
          if (turns++ == 0) return AgentReply('', [call()]);
          expect(messages.last['content'], contains('channel open denied'));
          return const AgentReply('连接拒绝了执行通道', []);
        },
      );
      await agent.send('操作', policy: dangerous);
      expect(executions, 1);
      agent.dispose();
    },
  );

  test(
    'a model failure after execution keeps results for resume without replay',
    () async {
      var turns = 0, executions = 0;
      final agent = AgentController(
        connectionIsCurrent: () => true,
        executeTool: (_, _) async {
          executions++;
          return '{"exit_code":0,"stdout":"file written"}';
        },
        requestModel: (messages, _, _) async {
          turns++;
          if (turns == 1) {
            return AgentReply('', [call('write', 'printf done > result.txt')]);
          }
          if (turns == 2) throw StateError('model connection interrupted');
          final outputs = messages.where((m) => m['role'] == 'tool');
          expect(outputs.length, 1);
          expect(outputs.single['content'], contains('file written'));
          return const AgentReply('文件已写入，无需重做', []);
        },
      );
      await agent.send('写文件', policy: dangerous);
      expect(agent.error, contains('model connection interrupted'));
      await agent.send('继续', policy: dangerous);
      expect(executions, 1);
      expect(agent.error, isNull);
      agent.dispose();
    },
  );

  test(
    'automatic compression retains goals and complete tool exchanges',
    () async {
      var turns = 0, summaries = 0;
      final requests = <List<Map<String, Object?>>>[];
      final agent = AgentController(
        connectionIsCurrent: () => true,
        executeTool: (_, _) async => 'X' * 16000,
        requestSummary: (messages, _, _) async {
          summaries++;
          return const AgentReply('用户目标：修复。已执行 one，输出过长。下一步核实。', []);
        },
        requestModel: (messages, _, _) async {
          requests.add(messages);
          return turns++ == 0
              ? AgentReply('', [call()])
              : const AgentReply('完成', []);
        },
      );
      await agent.send(
        '修复',
        policy: dangerous,
        budget: AgentBudget(contextTokens: 8192, maxOutputTokens: 1024),
      );
      expect(summaries, 1);
      expect(agent.compressionCount, 1);
      expect(agent.error, isNull);
      expect(jsonEncode(requests.last), contains('修复'));
      final ids = <Object?>{};
      for (final message in requests.last) {
        for (final tool in message['tool_calls'] as List? ?? []) {
          ids.add(tool['id']);
        }
        if (message['role'] == 'tool') {
          expect(ids, contains(message['tool_call_id']));
        }
      }
      agent.dispose();
    },
  );

  test(
    'truncated text remains usable and is never reported as complete',
    () async {
      final agent = AgentController(
        connectionIsCurrent: () => true,
        executeTool: (_, _) async => fail('No tools'),
        requestModel: (_, _, _) async =>
            const AgentReply('已保留的正文', [], truncated: true),
      );
      await agent.send('解释', policy: review);
      expect(agent.status, '回复达到输出上限');
      expect(agent.events.last.text, '已保留的正文');
      agent.dispose();
    },
  );

  test('context splitter never retains orphaned tool results', () {
    final messages = <Map<String, Object?>>[
      {'role': 'system', 'content': 'system'},
      {'role': 'user', 'content': 'goal'},
      AgentReply('', [call()]).toJson(),
      {'role': 'tool', 'tool_call_id': 'one', 'content': 'a' * 3000},
      {'role': 'assistant', 'content': 'done'},
    ];
    final split = splitForCompaction(messages, 100);
    expect(split.retained.any((m) => m['role'] == 'tool'), isFalse);
    expect(split.removed.where((m) => m['role'] == 'tool').length, 1);
  });

  test(
    'invalid command schemas are rejected but general shell syntax is accepted',
    () {
      expect(
        AgentToolRequest.parse(
          call('one', 'echo hello | tee /tmp/file'),
        ).command,
        contains('|'),
      );
      for (final args in [
        {'command': ''},
        {'command': 'id', 'purpose': 'why', 'timeout_seconds': 0},
        {'command': 'id', 'purpose': 'why', 'working_directory': 'relative'},
      ]) {
        expect(
          () => AgentToolRequest.parse(
            AgentToolCall(
              id: 'one',
              name: 'execute_command',
              arguments: jsonEncode(args),
            ),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('large SSE protocol overhead does not cut off normal text', () {
    final parser = AgentStreamParser();
    for (var i = 0; i < 2000; i++) {
      parser.add(
        jsonEncode({
          'padding': 'x' * 300,
          'choices': [
            {
              'delta': {'content': 'a'},
            },
          ],
        }),
      );
    }
    parser.add(
      '{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":2000}}',
    );
    expect(parser.complete().text.length, 2000);
    expect(parser.complete().inputTokens, 100);
  });

  test('incomplete tool call never becomes executable', () {
    final parser = AgentStreamParser();
    parser.add(
      jsonEncode({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'one',
                  'function': {
                    'name': 'execute_command',
                    'arguments': '{"command":',
                  },
                },
              ],
            },
            'finish_reason': 'length',
          },
        ],
      }),
    );
    expect(parser.complete, throwsFormatException);
  });
}
