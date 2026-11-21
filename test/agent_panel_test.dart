import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/app_store.dart';
import 'package:pocket_ssh/core/sessions.dart';
import 'package:pocket_ssh/features/terminal/ai_panel.dart';

void main() {
  testWidgets('agent shows host and tool boundaries without sending requests', (
    tester,
  ) async {
    final store = AppStore()
      ..aiModel = 'test-model'
      ..aiChannelName = '主用渠道';
    final session = WorkspaceSession(
      HostProfile(id: 'test', name: 'My server', host: 'example.test'),
      500,
    );
    session.connected = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiAgentPanel(
            store: store,
            session: session,
            selection: 'selected log',
          ),
        ),
      ),
    );
    expect(find.text('AI 助手  /  My server'), findsOneWidget);
    expect(find.textContaining('主用渠道 · test-model · Chat'), findsOneWidget);
    expect(find.textContaining('My server'), findsOneWidget);
    expect(find.text('发送'), findsOneWidget);
    expect(find.textContaining('上下文'), findsWidgets);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('磁盘诊断'), findsNothing);
    await tester.tap(find.text('审查模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('危险模式').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('危险模式：命令自动执行。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
    store.dispose();
  });
}
