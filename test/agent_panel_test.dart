import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/app_store.dart';
import 'package:pocket_ssh/core/sessions.dart';
import 'package:pocket_ssh/features/terminal/ai_panel.dart';

void main() {
  testWidgets('agent shows host and tool boundaries without sending requests', (
    tester,
  ) async {
    final store = AppStore()..aiModel = 'test-model';
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
    expect(find.text('SSH 运维 Agent'), findsOneWidget);
    expect(find.textContaining('My server'), findsOneWidget);
    expect(find.textContaining('自动诊断'), findsWidgets);
    expect(find.text('开始诊断'), findsOneWidget);
    expect(find.textContaining('点击开始后自动执行'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.widgetWithText(TextField, '/var'), findsOneWidget);
    await tester.tap(find.text('磁盘诊断'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('服务诊断').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'nginx'), findsOneWidget);
    expect(find.text('systemd 服务'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
    store.dispose();
  });
}
