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
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = AppStore();
      final sessions = Sessions();
      await tester.pumpWidget(
        MaterialApp(
          home: PocketHome(store: store, sessions: sessions),
        ),
      );
      expect(find.text('连接工作台'), findsOneWidget);
      expect(find.text('远程访问  /  SSH'), findsOneWidget);
      expect(find.byType(Card), findsNothing);
      expect(find.text('你的服务器，随时就绪。'), findsNothing);
      expect(find.text('主机'), findsNWidgets(2));
      expect(find.text('会话'), findsOneWidget);
      expect(find.text('文件'), findsOneWidget);
      expect(find.text('你的服务器，随时就绪。'), findsNothing);
      expect(find.text('远程访问  /  SSH'), findsOneWidget);
      expect(find.text('快速连接'), findsOneWidget);
      await tester.tap(find.text('文件').first);
      await tester.pumpAndSettle();
      expect(find.text('远程文件'), findsOneWidget);
      expect(find.text('选择主机，浏览和传输远程文件。'), findsOneWidget);
      await tester.tap(find.text('主机').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('外观'), findsOneWidget);
      expect(find.text('终端'), findsOneWidget);
      expect(find.text('AI 助手'), findsOneWidget);
      expect(find.text('安全与隐私'), findsOneWidget);
      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();
      expect(find.text('应用主题'), findsOneWidget);
      expect(find.text('系统模式会跟随设备浅色或深色外观。'), findsOneWidget);
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

  testWidgets('wide workspace switches to a side navigation rail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = AppStore();
    final sessions = Sessions();
    await tester.pumpWidget(
      MaterialApp(
        home: PocketHome(store: store, sessions: sessions),
      ),
    );
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(tester.takeException(), isNull);
    sessions.dispose();
    store.dispose();
  });

  testWidgets('host list action buttons fit on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = AppStore()
      ..hosts.add(
        HostProfile(
          id: 'prod',
          name: 'Production API Server',
          host: 'api.example.test',
          username: 'operator',
          group: 'Production',
        ),
      );
    final sessions = Sessions();
    await tester.pumpWidget(
      MaterialApp(
        home: PocketHome(store: store, sessions: sessions),
      ),
    );
    expect(find.text('Production API Server'), findsOneWidget);
    expect(find.byTooltip('连接 Production API Server'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
