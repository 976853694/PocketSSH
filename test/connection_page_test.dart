import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/app_store.dart';
import 'package:pocket_ssh/core/sessions.dart';
import 'package:pocket_ssh/core/ssh_connection.dart';
import 'package:pocket_ssh/features/connection/connection_page.dart';
import 'package:pocket_ssh/main.dart';

void main() {
  test('normalizes host names and formats IPv6 endpoints with their ports', () {
    expect(normalizeHost(' Server.Example '), 'server.example');
    final host = normalizeHost('[2001:db8::1]');
    expect(host, '2001:db8::1');
    expect(SshTarget(host!, 2222, 'user').endpoint, '[2001:db8::1]:2222');
    expect(normalizeHost('https://server.example'), isNull);
    expect(normalizeHost('server.example:22'), isNull);
  });

  testWidgets('home exposes host, transfer and settings navigation', (
    tester,
  ) async {
    final store = AppStore();
    final sessions = Sessions();
    await tester.pumpWidget(
      MaterialApp(
        home: PocketHome(store: store, sessions: sessions),
      ),
    );
    expect(find.text('Pocket SSH'), findsOneWidget);
    expect(find.text('主机'), findsOneWidget);
    expect(find.text('传输'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('添加第一台服务器'), findsOneWidget);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('AI 终端'),
      100,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .last,
    );
    expect(find.text('AI 终端'), findsOneWidget);
    final vertical = find
        .byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        )
        .last;
    await tester.scrollUntilVisible(
      find.text('接口类型'),
      150,
      scrollable: vertical,
    );
    await tester.ensureVisible(find.text('Chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Responses').last);
    await tester.pumpAndSettle();
    expect(find.text('Responses'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('终端字体大小'),
      -200,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .last,
    );
    expect(find.text('终端字体大小'), findsOneWidget);
    sessions.dispose();
    store.dispose();
  });

  testWidgets('host profile form exposes connection and jump-host fields', (
    tester,
  ) async {
    final store = AppStore();
    final sessions = Sessions();
    await tester.pumpWidget(
      MaterialApp(
        home: PocketHome(store: store, sessions: sessions),
      ),
    );
    await tester.tap(find.byTooltip('添加主机'));
    await tester.pumpAndSettle();
    expect(find.byType(Form), findsOneWidget);
    expect(find.text('添加主机'), findsOneWidget);
    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('高级连接'), findsOneWidget);
    sessions.dispose();
    store.dispose();
  });

  testWidgets('connection form can select private-key authentication', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: ConnectionPage(quick: true)),
    );
    await tester.tap(find.text('私钥'));
    await tester.pumpAndSettle();
    expect(find.text('保存主机'), findsNothing);
    expect(find.text('私钥'), findsOneWidget);
  });
}
