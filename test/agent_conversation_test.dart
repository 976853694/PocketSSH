import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/agent_controller.dart';
import 'package:pocket_ssh/core/agent_policy.dart';
import 'package:pocket_ssh/core/agent_protocol.dart';
import 'package:pocket_ssh/features/terminal/agent_conversation.dart';

Widget host(AgentController agent, {double height = 400, String? error}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: height,
          child: AgentConversation(agent: agent, error: error),
        ),
      ),
    );

AgentController controller({AgentModelRequest? model}) => AgentController(
  connectionIsCurrent: () => true,
  executeTool: (_, _) async => fail('No tool expected'),
  requestModel: model ?? (_, _, _) async => const AgentReply('回答', []),
);

void seed(AgentController agent, [int count = 200]) {
  agent.events.addAll(
    List.generate(
      count,
      (i) => AgentEvent('assistant', '历史消息 $i\n${'历史内容\n' * 8}'),
    ),
  );
}

void main() {
  testWidgets(
    'long conversation builds only visible messages and opens at the latest',
    (tester) async {
      final agent = controller();
      seed(agent);
      await tester.pumpWidget(host(agent));
      await tester.pump();
      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('agent-messages')),
      );
      expect(list.reverse, isTrue);
      expect(list.controller!.offset, 0);
      expect(find.byType(SelectableText).evaluate().length, lessThan(20));
      expect(find.textContaining('历史消息 0\n'), findsNothing);
      expect(find.textContaining('历史消息 199\n'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      agent.dispose();
    },
  );

  testWidgets(
    'streaming follows the latest and preserves final chunks and keyboard resizing',
    (tester) async {
      final reply = Completer<AgentReply>();
      late void Function(String) emit;
      final agent = controller(
        model: (_, _, onText) {
          emit = onText;
          return reply.future;
        },
      );
      seed(agent, 30);
      await tester.pumpWidget(host(agent));
      final task = agent.send('继续', policy: const AgentPolicy());
      await tester.pump();
      emit('第一段\n' * 30);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump();
      final scroll = tester
          .widget<ListView>(find.byKey(const ValueKey('agent-messages')))
          .controller!;
      expect(scroll.offset, 0);
      expect(agent.events.last.text, contains('第一段'));
      await tester.pumpWidget(host(agent, height: 240));
      await tester.pump();
      expect(scroll.offset, 0);
      emit('最后一段');
      reply.complete(AgentReply('${'第一段\n' * 30}最后一段', const []));
      await task;
      await tester.pump();
      await tester.pump();
      expect(scroll.offset, 0);
      expect(agent.events.last.text, endsWith('最后一段'));
      expect(find.byKey(const ValueKey('agent-show-latest')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      agent.dispose();
    },
  );

  testWidgets('reading history pauses following and latest button resumes it', (
    tester,
  ) async {
    final agent = controller();
    seed(agent);
    await tester.pumpWidget(host(agent));
    final finder = find.byKey(const ValueKey('agent-messages'));
    await tester.drag(finder, const Offset(0, 500));
    await tester.pumpAndSettle();
    final scroll = tester.widget<ListView>(finder).controller!;
    expect(scroll.offset, greaterThan(48));
    final before = scroll.offset;
    agent.events.last.text += '后台新增内容\n' * 30;
    await tester.pump();
    await tester.pump();
    expect(scroll.offset, greaterThan(48));
    expect(scroll.offset, closeTo(before, 1));
    await tester.tap(find.byKey(const ValueKey('agent-show-latest')));
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    expect(find.byKey(const ValueKey('agent-show-latest')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    agent.dispose();
  });

  testWidgets('sending a new message returns from history to the latest', (
    tester,
  ) async {
    final agent = controller();
    seed(agent);
    await tester.pumpWidget(host(agent));
    final finder = find.byKey(const ValueKey('agent-messages'));
    await tester.drag(finder, const Offset(0, 500));
    await tester.pumpAndSettle();
    await agent.send('新问题', policy: const AgentPolicy());
    await tester.pump();
    await tester.pump();
    expect(tester.widget<ListView>(finder).controller!.offset, 0);
    expect(find.text('回答'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    agent.dispose();
  });

  testWidgets(
    'tool updates, errors and clearing remain visible without stale listeners',
    (tester) async {
      final agent = controller();
      final tool = AgentEvent('tool', '读取目录\n输出', status: '执行中');
      agent.events.add(tool);
      await tester.pumpWidget(host(agent));
      tool.status = '已返回';
      await tester.pump();
      expect(find.text('已返回'), findsOneWidget);
      await tester.pumpWidget(host(agent, error: '连接失败'));
      await tester.pump();
      expect(find.text('连接失败'), findsOneWidget);
      agent.clear();
      await tester.pumpWidget(host(agent));
      await tester.pump();
      tool.text = '旧消息不应显示';
      await tester.pump();
      expect(find.text('旧消息不应显示'), findsNothing);
      expect(find.textContaining('描述你要完成的任务'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      agent.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
