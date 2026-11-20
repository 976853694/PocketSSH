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
    expect(find.textContaining('固定只读工具'), findsOneWidget);
    expect(find.text('发送'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
    store.dispose();
  });
}
