import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/app_store.dart';
import 'package:pocket_ssh/core/sessions.dart';
import 'package:pocket_ssh/features/terminal/terminal_page.dart';

void main() {
  testWidgets(
    'risky draft waits for explicit approval before terminal output',
    (tester) async {
      final store = AppStore();
      final sessions = Sessions();
      final session = WorkspaceSession(
        HostProfile(
          id: 'test',
          name: 'Test host',
          host: 'example.test',
          username: 'ops',
        ),
        500,
      );
      final sent = <String>[];
      session.connected = true;
      session.terminal.onOutput = sent.add;
      await tester.pumpWidget(
        MaterialApp(
          home: TerminalPage(
            session: session,
            store: store,
            sessions: sessions,
            verify: (_, _, _) async => false,
          ),
        ),
      );
      const draft = 'sudo reboot';
      final field = find.byType(TextField);
      await tester.enterText(field, draft);
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      expect(find.text('目标会话 · ops@example.test:22'), findsOneWidget);
      expect(sent, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行'));
      await tester.pumpAndSettle();
      expect(sent, [draft, '\r']);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      sessions.dispose();
      store.dispose();
    },
  );
}
