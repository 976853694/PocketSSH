import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/app_store.dart';
import 'package:pocket_ssh/core/device_bridge.dart';
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

  testWidgets('first frame shows the workspace while device settings load', (
    tester,
  ) async {
    final state = Completer<String?>();
    var workspaceWasBuilt = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeDeviceChannel, (call) async {
      expect(call.method, 'loadState');
      workspaceWasBuilt = find.text('连接工作台').evaluate().isNotEmpty;
      return state.future;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(nativeDeviceChannel, null),
    );
    await tester.pumpWidget(const PocketSshApp());
    expect(workspaceWasBuilt, isTrue);
    expect(find.text('正在读取主机配置…'), findsOneWidget);
    final quick = find.ancestor(
      of: find.text('快速连接'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    expect(tester.widget<FilledButton>(quick).onPressed, isNull);
    final settings = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '设置',
    );
    expect(tester.widget<IconButton>(settings).onPressed, isNull);
    expect(find.byType(CustomScrollView, skipOffstage: false), findsOneWidget);

    state.complete(
      jsonEncode({
        'theme': 'dark',
        'hosts': [
          HostProfile(id: 'a', name: 'Saved Host', host: 'a.test').toJson(),
        ],
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('正在读取主机配置…'), findsNothing);
    expect(find.text('Saved Host'), findsOneWidget);
    expect(tester.widget<FilledButton>(quick).onPressed, isNotNull);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
  });

  testWidgets(
    'host search is restored after lazily switching workspace pages',
    (tester) async {
      final store = AppStore()
        ..hosts.addAll([
          HostProfile(id: 'one', name: 'Alpha host', host: 'one.test'),
          HostProfile(id: 'two', name: 'Beta host', host: 'two.test'),
        ]);
      final sessions = Sessions();
      addTearDown(store.dispose);
      addTearDown(sessions.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: PocketHome(store: store, sessions: sessions),
        ),
      );
      final search = find.byType(TextField);
      await tester.enterText(search, 'Beta');
      await tester.pumpAndSettle();
      expect(find.text('Alpha host'), findsNothing);
      Finder tab(String title) => find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(title),
      );
      await tester.tap(tab('文件'));
      await tester.pumpAndSettle();
      expect(search, findsNothing);
      await tester.tap(tab('主机'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, 'Beta');
      expect(find.text('Beta host'), findsOneWidget);
      expect(find.text('Alpha host'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
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

  testWidgets('no-credential access has no secret prompt or remember toggle', (
    tester,
  ) async {
    final store = AppStore();
    HostProfile? profile;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                profile = await Navigator.of(context).push<HostProfile>(
                  MaterialPageRoute(
                    builder: (_) => const ConnectionPage(quick: true),
                  ),
                );
                if (context.mounted && profile != null) {
                  final credentials = await requestCredentials(
                    context,
                    profile!,
                    store,
                  );
                  expect(credentials?.password, isEmpty);
                  expect(credentials?.key, isEmpty);
                }
              },
              child: const Text('开始'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '服务器地址'),
      'example.test',
    );
    await tester.enterText(find.widgetWithText(TextFormField, '用户名'), 'ops');
    await tester.tap(find.text('无凭据'));
    await tester.pumpAndSettle();
    expect(find.textContaining('仍会校验主机指纹'), findsOneWidget);
    expect(find.text('加密保存凭据'), findsNothing);
    await tester.ensureVisible(find.text('连接'));
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    expect(profile?.auth, HostAuth.none);
    expect(profile?.remember, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
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
