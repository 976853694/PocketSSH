import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/app_store.dart';
import 'package:pocket_ssh/core/device_bridge.dart';
import 'package:pocket_ssh/core/sessions.dart';
import 'package:pocket_ssh/core/ssh_connection.dart';
import 'package:pocket_ssh/features/connection/connection_page.dart';
import 'package:pocket_ssh/features/terminal/terminal_page.dart';
import 'package:pocket_ssh/main.dart';

Finder _bottomTab(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

void main() {
  test('normalizes host names and formats IPv6 endpoints with their ports', () {
    expect(normalizeHost(' Server.Example '), 'server.example');
    final host = normalizeHost('[2001:db8::1]');
    expect(host, '2001:db8::1');
    expect(SshTarget(host!, 2222, 'user').endpoint, '[2001:db8::1]:2222');
    expect(normalizeHost('https://server.example'), isNull);
    expect(normalizeHost('server.example:22'), isNull);
  });

  testWidgets('mobile navigation opens hosts, files and settings in order', (
    tester,
  ) async {
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
    final bar = find.byType(NavigationBar);
    expect(
      tester
          .widget<NavigationBar>(bar)
          .destinations
          .cast<NavigationDestination>()
          .map((item) => item.label),
      ['主机', '文件', '设置'],
    );
    expect(find.text('快速连接'), findsOneWidget);
    await tester.tap(_bottomTab('文件'));
    await tester.pumpAndSettle();
    expect(find.text('远程文件'), findsOneWidget);
    expect(find.text('选择主机，浏览和传输远程文件。'), findsOneWidget);
    await tester.tap(_bottomTab('设置'));
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(bar).selectedIndex, 2);
    expect(find.byType(BackButton), findsNothing);
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
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(bar).selectedIndex, 2);
    await tester.tap(_bottomTab('主机'));
    await tester.pumpAndSettle();
    expect(find.text('连接工作台'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    sessions.dispose();
    store.dispose();
  });

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
    expect(find.byType(CustomScrollView, skipOffstage: false), findsOneWidget);
    await tester.tap(_bottomTab('设置'));
    await tester.pumpAndSettle();
    expect(find.text('正在读取设置…'), findsOneWidget);
    expect(find.text('外观'), findsNothing);

    state.complete(
      jsonEncode({
        'theme': 'dark',
        'hosts': [
          HostProfile(id: 'a', name: 'Saved Host', host: 'a.test').toJson(),
        ],
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('正在读取设置…'), findsNothing);
    expect(find.text('外观'), findsOneWidget);
    await tester.tap(_bottomTab('主机'));
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
      await tester.tap(_bottomTab('文件'));
      await tester.pumpAndSettle();
      expect(search, findsNothing);
      await tester.tap(_bottomTab('主机'));
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
    final rail = find.byType(NavigationRail);
    expect(find.byType(NavigationBar), findsNothing);
    expect(
      tester
          .widget<NavigationRail>(rail)
          .destinations
          .map((item) => (item.label as Text).data),
      ['主机', '文件', '设置'],
    );
    await tester.tap(find.descendant(of: rail, matching: find.text('设置')));
    await tester.pumpAndSettle();
    expect(find.text('配置备份'), findsOneWidget);
    expect(tester.widget<NavigationRail>(rail).selectedIndex, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    sessions.dispose();
    store.dispose();
  });

  testWidgets('terminal connections do not add rows to the files tab', (
    tester,
  ) async {
    final host = HostProfile(
      id: 'saved',
      name: 'Office host',
      host: 'office.test',
    );
    final store = AppStore()..hosts.add(host);
    final sessions = Sessions();
    final opened = <WorkspaceSession>[];
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      sessions.dispose();
      for (final session in opened) {
        session.dispose();
      }
      store.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: PocketHome(store: store, sessions: sessions),
      ),
    );
    await tester.tap(_bottomTab('文件'));
    await tester.pumpAndSettle();
    expect(find.text('Office host'), findsOneWidget);

    for (var i = 0; i < 3; i++) {
      final session = WorkspaceSession(host, store.scrollback)
        ..connected = true;
      opened.add(session);
      sessions.add(session);
      if (i == 1) session.stop();
      await tester.pump();
      expect(find.byType(ListTile), findsOneWidget);
      expect(find.text('Office host'), findsOneWidget);
    }
    expect(find.text('传输任务'), findsNothing);
  });

  testWidgets(
    'files tab shows only real transfer tasks for quick connections',
    (tester) async {
      final store = AppStore();
      final host = HostProfile(
        id: 'quick',
        name: 'Quick host',
        host: 'quick.test',
      );
      final session = WorkspaceSession(host, store.scrollback)
        ..connected = true;
      final sessions = Sessions()..add(session);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        sessions.dispose();
        session.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: PocketHome(store: store, sessions: sessions),
        ),
      );
      await tester.tap(_bottomTab('文件'));
      await tester.pumpAndSettle();
      expect(find.text('还没有可浏览的主机'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);

      session
        ..transferStatus = '上传 report.txt'
        ..transferBytes = 1024
        ..transferTotal = 2048
        ..updateTransfer();
      await tester.pump();
      expect(find.text('传输任务'), findsOneWidget);
      expect(find.text('上传 report.txt'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .5,
      );

      session
        ..transferStatus = null
        ..updateTransfer();
      await tester.pump();
      expect(find.text('传输任务'), findsNothing);
      expect(find.text('还没有可浏览的主机'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
    },
  );

  testWidgets('opening an already connected host reuses its terminal', (
    tester,
  ) async {
    final host = HostProfile(
      id: 'prod',
      name: 'Production',
      host: 'example.test',
    );
    final store = AppStore()..hosts.add(host);
    final session = WorkspaceSession(host, store.scrollback)..connected = true;
    final sessions = Sessions()..add(session);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      sessions.dispose();
      session.dispose();
      store.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: PocketHome(store: store, sessions: sessions),
      ),
    );
    await tester.tap(find.byTooltip('连接 Production'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TerminalPage>(find.byType(TerminalPage)).session,
      same(session),
    );
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(sessions.items, [session]);
    expect(session.connected, isTrue);
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
