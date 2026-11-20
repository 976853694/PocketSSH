import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/agent_controller.dart';
import 'package:pocket_ssh/core/agent_policy.dart';
import 'package:pocket_ssh/core/agent_protocol.dart';

void main() {
  testWidgets('many stream chunks update only the active message in batches', (
    tester,
  ) async {
    final reply = Completer<AgentReply>();
    late void Function(String) emit;
    final agent = AgentController(
      connectionIsCurrent: () => true,
      executeTool: (_, _) async => fail('No tool expected'),
      requestModel: (_, _, onText) {
        emit = onText;
        return reply.future;
      },
    );
    var panelUpdates = 0, messageUpdates = 0;
    agent.addListener(() => panelUpdates++);
    final task = agent.send('回答', policy: const AgentPolicy());
    final message = agent.events.last;
    message.addListener(() => messageUpdates++);
    for (var i = 0; i < 1000; i++) {
      emit('x');
    }
    await tester.pump(const Duration(milliseconds: 49));
    expect(message.text, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(message.text, 'x' * 1000);
    expect(messageUpdates, 1);
    expect(panelUpdates, lessThan(5));
    emit('尾部');
    reply.complete(AgentReply('${'x' * 1000}尾部', const []));
    await task;
    expect(message.text, endsWith('尾部'));
    expect(messageUpdates, 2);
    expect(panelUpdates, lessThan(5));
    agent.dispose();
  });

  testWidgets('cancelling flushes pending text and leaves no render timer', (
    tester,
  ) async {
    final reply = Completer<AgentReply>();
    late void Function(String) emit;
    final agent = AgentController(
      connectionIsCurrent: () => true,
      executeTool: (_, _) async => fail('No tool expected'),
      requestModel: (_, _, onText) {
        emit = onText;
        return reply.future;
      },
    );
    final task = agent.send('回答', policy: const AgentPolicy());
    emit('已收到的部分');
    agent.stop();
    await task;
    expect(agent.events.last.text, '已收到的部分');
    agent.dispose();
    emit('迟到的内容');
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
