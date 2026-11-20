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

  testWidgets(
    'home exposes host, session and file navigation with settings categories',
    (tester) async {
      final store = AppStore();
      final sessions = Sessions();
      await tester.pumpWidget(
        MaterialApp(
          home: PocketHome(store: store, sessions: sessions),
        ),
      );
      expect(find.text('Pocket SSH'), findsOneWidget);
      expect(find.text('主机'), findsOneWidget);
      expect(find.text('会话'), findsOneWidget);
      expect(find.text('文件'), findsOneWidget);
      expect(find.text('添加第一台服务器'), findsOneWidget);
      await tester.tap(find.text('文件'));
      await tester.pumpAndSettle();
      expect(find.text('SFTP 传输'), findsNothing);
      await tester.tap(find.text('主机'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('外观'), findsOneWidget);
      expect(find.text('终端'), findsOneWidget);
      expect(find.text('AI 助手'), findsOneWidget);
      expect(find.text('安全与隐私'), findsOneWidget);
      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();
      expect(find.text('液态'), findsOneWidget);
      expect(find.text('毛玻璃'), findsOneWidget);
      expect(find.text('透明度 72%'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI 助手'));
      await tester.pumpAndSettle();
      expect(find.text('接口类型'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('终端'));
      await tester.pumpAndSettle();
      expect(find.text('字体大小 · 14 px'), findsOneWidget);
      sessions.dispose();
      store.dispose();
    },
  );

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
