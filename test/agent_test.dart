import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/agent_controller.dart';
import 'package:pocket_ssh/core/agent_policy.dart';
import 'package:pocket_ssh/core/agent_protocol.dart';

AgentToolCall call(String name, Map<String, Object> args) =>
    AgentToolCall(id: 'call-1', name: name, arguments: jsonEncode(args));
AgentPolicy disk([String path = '/var']) =>
    AgentPolicy(kind: AgentTaskKind.disk, target: path);
AgentPolicy service([String name = 'nginx']) =>
    AgentPolicy(kind: AgentTaskKind.service, target: name);

void main() {
  test('stream fragments require a complete tool call', () {
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
                  'function': {'name': 'diagnose', 'arguments': '{"check":'},
                },
              ],
            },
          },
        ],
      }),
    );
    expect(parser.complete, throwsFormatException);
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
    expect(
      AgentToolRequest.parse(parser.complete().calls.single).value,
      'disks',
    );
  });

  test('truncated responses cannot execute tools', () {
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
    expect(parser.complete, throwsFormatException);
  });

  test(
    'invalid tools, arguments, service injection and traversal are rejected',
    () {
      for (final request in [
        call('execute_shell', {'command': 'id'}),
        call('diagnose', {'check': 'df -h; reboot'}),
        call('diagnose', {'check': 'disks', 'command': 'id'}),
        call('directory_usage', {'path': '/var/../etc'}),
        call('directory_usage', {'path': 'relative'}),
        call('service_status', {'service': 'nginx; id'}),
        call('service_logs', {'service': '--all'}),
        call('service_logs', {'service': 'nginx*'}),
      ]) {
        expect(() => AgentToolRequest.parse(request), throwsFormatException);
      }
    },
  );

  test('disk and service scopes reject sibling paths and other services', () {
    final policy = disk('/var/log/');
    policy.check(const AgentToolRequest('directory_usage', '/var/log/nginx'));
    expect(
      () =>
          policy.check(const AgentToolRequest('directory_usage', '/var/logs')),
      throwsStateError,
    );
    expect(
      () => policy.check(const AgentToolRequest('service_logs', 'nginx')),
      throwsStateError,
    );
    service().check(const AgentToolRequest('service_logs', 'nginx.service'));
    expect(
      () => service().check(const AgentToolRequest('service_logs', 'sshd')),
      throwsStateError,
    );
    expect(
      () => service().check(const AgentToolRequest('directory_usage', '/')),
      throwsStateError,
    );
    expect(disk().tools.map((t) => (t['function'] as Map)['name']), [
      'diagnose',
      'directory_usage',
    ]);
    expect(service().tools.map((t) => (t['function'] as Map)['name']), [
      'diagnose',
      'service_status',
      'service_logs',
    ]);
  });

  test(
    'directory names are quoted as literal shell arguments',
    () async {
      const path = "/tmp/a'b\$(printf injected); name";
      final command = const AgentToolRequest('directory_usage', path).command;
      final result = await Process.run('/bin/sh', [
        '-c',
        command.replaceFirst('du -P -x -k --max-depth=1', 'printf %s'),
      ]);
      expect(result.stdout, '--$path');
      expect(result.stdout, isNot(contains('abinjected')));
    },
    skip: !Platform.isLinux,
  );

  test(
    'directory checks reject symbolic link path components',
    () async {
      final root = await Directory.systemTemp.createTemp('pocketssh-agent-');
      addTearDown(() => root.delete(recursive: true));
      final outside = await Directory('${root.path}/outside').create();
      await Directory('${outside.path}/child').create();
      await Link('${root.path}/alias').create(outside.path);
      final command = AgentToolRequest(
        'directory_usage',
        '${root.path}/alias/child',
      ).command;
      final result = await Process.run('/bin/sh', ['-c', command]);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('Symbolic link'));
      expect(result.stdout, isEmpty);
    },
    skip: !Platform.isLinux,
  );

  test(
    'disk task runs initial commands and follows model tools automatically',
    () async {
      final executed = <String>[];
      var models = 0;
      final agent = AgentController(
        connectionIsCurrent: () => true,
        executeTool: (request, _) async {
          executed.add(request.command);
          return 'password=fixture\nused 90%';
        },
        requestModel: (messages, _, _) async {
          models++;
          expect(
            messages.where((m) => m['role'] == 'tool').length,
            models == 1 ? 3 : 4,
          );
          expect(jsonEncode(messages), isNot(contains('fixture')));
          if (models == 1) {
            return AgentReply('继续查看日志目录', [
              call('directory_usage', {'path': '/var/log'}),
            ]);
          }
          return const AgentReply('日志目录占用较高', []);
        },
      );
      await agent.send('排查磁盘', policy: disk());
      expect(executed.length, 4);
      expect(executed.take(2), ['df -h', 'df -i']);
      expect(agent.status, '任务完成');
      expect(agent.error, isNull);
      agent.dispose();
    },
  );

  test('service task automatically collects status and recent logs', () async {
    final executed = <String>[];
    final agent = AgentController(
      connectionIsCurrent: () => true,
      executeTool: (request, _) async {
        executed.add(request.command);
        return '{"exit_code":3,"stdout":"inactive"}';
      },
      requestModel: (messages, _, _) async {
        expect(messages.where((m) => m['role'] == 'tool').length, 2);
        expect(jsonEncode(messages), contains('inactive'));
        return const AgentReply('服务未运行', []);
      },
    );
    await agent.send('检查服务', policy: service());
    expect(executed[0], contains("status -- 'nginx.service'"));
    expect(executed[1], contains("--unit='nginx.service'"));
    expect(agent.error, isNull);
    agent.dispose();
  });

  test(
    'a mixed batch is validated before any model-requested execution',
    () async {
      var executions = 0;
      final agent = AgentController(
        connectionIsCurrent: () => true,
        executeTool: (_, _) async {
          executions++;
          return 'ok';
        },
        requestModel: (_, _, _) async => AgentReply('', [
          call('directory_usage', {'path': '/var/log'}),
          call('directory_usage', {'path': '/etc'}),
        ]),
      );
      await agent.send('检查', policy: disk());
      expect(executions, 3);
      expect(agent.error, contains('范围'));
      agent.dispose();
    },
  );

  test(
    'connection changes after a tool block all later execution and sharing',
    () async {
      var current = true, executions = 0;
      final agent = AgentController(
        connectionIsCurrent: () => current,
        requestModel: (_, _, _) async => fail('Connection changed'),
        executeTool: (_, _) async {
          executions++;
          current = false;
          return 'result';
        },
      );
      await agent.send('检查', policy: disk());
      expect(executions, 1);
      expect(agent.error, contains('会话'));
      agent.dispose();
    },
  );

  test('stop during execution cancels and ignores late output', () async {
    final entered = Completer<void>(), result = Completer<String>();
    var cancelled = false, executions = 0;
    final agent = AgentController(
      connectionIsCurrent: () => true,
      requestModel: (_, _, _) async => fail('Stopped'),
      executeTool: (_, cancellation) {
        executions++;
        cancellation.onCancel(() => cancelled = true);
        entered.complete();
        return result.future;
      },
    );
    final task = agent.send('检查', policy: disk());
    await entered.future;
    agent.stop();
    await task;
    result.complete('late private output');
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isTrue);
    expect(executions, 1);
    expect(agent.status, '已停止');
    expect(
      agent.events.map((e) => e.text).join(),
      isNot(contains('late private')),
    );
    agent.dispose();
  });

  test('task deadline cancels pending execution', () async {
    final agent = AgentController(
      taskTimeout: const Duration(milliseconds: 10),
      connectionIsCurrent: () => true,
      executeTool: (_, _) => Completer<String>().future,
      requestModel: (_, _, _) async => fail('Timed out'),
    );
    await agent.send('检查', policy: disk());
    expect(agent.running, isFalse);
    expect(agent.status, '任务超时');
    agent.dispose();
  });

  test(
    'tool errors are passed to model as failures instead of success',
    () async {
      final agent = AgentController(
        connectionIsCurrent: () => true,
        executeTool: (_, _) async => throw StateError('failure'),
        requestModel: (messages, _, _) async {
          expect(
            messages
                .where((m) => m['role'] == 'tool')
                .every((m) => (m['content'] as String).contains('error')),
            isTrue,
          );
          return const AgentReply('无法完成检查', []);
        },
      );
      await agent.send('检查', policy: service());
      expect(
        agent.events
            .where((e) => e.kind == 'tool')
            .every((e) => e.status.startsWith('检查失败')),
        isTrue,
      );
      agent.dispose();
    },
  );

  test(
    'follow-ups retain history, changing target or clearing resets it',
    () async {
      final counts = <int>[];
      final agent = AgentController(
        connectionIsCurrent: () => true,
        executeTool: (_, _) async => 'ok',
        requestModel: (messages, _, _) async {
          counts.add(messages.where((m) => m['role'] == 'user').length);
          return const AgentReply('报告', []);
        },
      );
      await agent.send('检查', policy: disk());
      await agent.send('继续', policy: disk());
      await agent.send('检查', policy: disk('/opt'));
      agent.clear();
      await agent.send('检查', policy: disk('/opt'));
      expect(counts, [1, 2, 1, 1]);
      agent.dispose();
    },
  );

  test('repeated calls stop at budget', () async {
    var executions = 0;
    final agent = AgentController(
      connectionIsCurrent: () => true,
      executeTool: (_, _) async {
        executions++;
        return 'ok';
      },
      requestModel: (_, _, _) async => AgentReply('', [
        for (var i = 0; i < 4; i++)
          AgentToolCall(
            id: 'tool-$i',
            name: 'diagnose',
            arguments: '{"check":"disks"}',
          ),
      ]),
    );
    await agent.send('检查', policy: disk());
    expect(executions, 11);
    expect(agent.error, contains('上限'));
    agent.dispose();
  });
}
