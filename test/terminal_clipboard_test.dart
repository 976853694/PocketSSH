import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';
import 'package:pocket_ssh/core/app_store.dart';
import 'package:pocket_ssh/core/sessions.dart';
import 'package:pocket_ssh/features/terminal/terminal_page.dart';

Future<({WorkspaceSession session, List<String> sent})> openTerminal(
  WidgetTester tester, {
  bool connected = true,
  String output = 'hello world',
}) async {
  final store = AppStore();
  final sessions = Sessions();
  final session =
      WorkspaceSession(
          HostProfile(id: 'test', name: 'Test host', host: 'example.test'),
          500,
        )
        ..connected = connected
        ..finished = !connected;
  final sent = <String>[];
  session.terminal.onOutput = sent.add;
  session.terminal.write(output);
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
  await tester.pump();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
    sessions.dispose();
    store.dispose();
  });
  return (session: session, sent: sent);
}

Offset cellPosition(WidgetTester tester, int x, [int y = 0]) {
  final render = tester
      .state<TerminalViewState>(find.byType(TerminalView))
      .renderTerminal;
  return render.localToGlobal(
    render.getOffset(CellOffset(x, y)) + Offset(2, render.lineHeight / 2),
  );
}

Future<void> longPressCell(WidgetTester tester, int x, [int y = 0]) async {
  final gesture = await tester.startGesture(cellPosition(tester, x, y));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  await gesture.up();
  await tester.pumpAndSettle();
}

Finder item(String value) => find.byKey(ValueKey('terminal-$value'));

bool enabled(WidgetTester tester, String value) =>
    tester.widget<TextButton>(item(value)).onPressed != null;

TerminalViewState terminalView(WidgetTester tester) =>
    tester.state<TerminalViewState>(find.byType(TerminalView));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? clipboard;
  Completer<Map<String, String>?>? pendingRead;
  setUp(() {
    clipboard = null;
    pendingRead = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            if (pendingRead != null) return await pendingRead!.future;
            return clipboard == null ? null : {'text': clipboard!};
          }
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.hasStrings') {
            return {'value': clipboard?.isNotEmpty == true};
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  testWidgets(
    'long press selects a word and copies it without terminal input',
    (tester) async {
      final fixture = await openTerminal(tester);
      await longPressCell(tester, 1);
      expect(item('copy'), findsOneWidget);
      expect(item('paste'), findsOneWidget);
      expect(enabled(tester, 'copy'), isTrue);
      expect(terminalView(tester).hasInputConnection, isFalse);
      expect(find.byType(PopupMenuItem<String>), findsNothing);
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(clipboard, 'hello');
      expect(fixture.sent, isEmpty);
    },
  );

  testWidgets('long press dragging preserves native multiword selection', (
    tester,
  ) async {
    await openTerminal(tester);
    final gesture = await tester.startGesture(cellPosition(tester, 1));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(cellPosition(tester, 8));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(clipboard, 'hello world');
  });

  testWidgets(
    'both handles adjust an exact selection without closing the terminal IME',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fixture = await openTerminal(tester);
      await tester.tapAt(cellPosition(tester, 1));
      await tester.pump();
      final view = terminalView(tester);
      expect(view.hasInputConnection, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final viewport = tester.getRect(find.byType(TerminalView));
      tester.testTextInput.log.clear();

      await longPressCell(tester, 1);
      final cellWidth = view.renderTerminal.cellSize.width;
      await tester.drag(item('selection-start'), Offset(cellWidth * 2, 0));
      await tester.pumpAndSettle();
      await tester.drag(item('selection-end'), Offset(cellWidth * 3, 0));
      await tester.pumpAndSettle();
      await tester.tap(item('copy'));
      await tester.pumpAndSettle();

      expect(clipboard, 'llo wo');
      expect(fixture.sent, isEmpty);
      expect(view.hasInputConnection, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.getRect(find.byType(TerminalView)), viewport);
      expect(
        tester.testTextInput.log.map((call) => call.method),
        isNot(
          contains(
            anyOf(
              'TextInput.hide',
              'TextInput.clearClient',
              'TextInput.setClient',
            ),
          ),
        ),
      );
    },
  );

  testWidgets('selection does not steal focus from the command draft', (
    tester,
  ) async {
    await openTerminal(tester);
    final draft = find.byType(TextField);
    await tester.enterText(draft, 'my draft');
    await tester.pumpAndSettle();
    final focus = tester
        .widget<EditableText>(find.byType(EditableText))
        .focusNode;
    expect(focus.hasPrimaryFocus, isTrue);
    tester.testTextInput.log.clear();
    await longPressCell(tester, 1);
    await tester.tap(item('copy'));
    await tester.pumpAndSettle();
    expect(clipboard, 'hello');
    expect(focus.hasPrimaryFocus, isTrue);
    expect(terminalView(tester).hasInputConnection, isFalse);
    expect(tester.widget<TextField>(draft).controller!.text, 'my draft');
    expect(
      tester.testTextInput.log.map((call) => call.method),
      isNot(
        contains(
          anyOf(
            'TextInput.hide',
            'TextInput.clearClient',
            'TextInput.setClient',
          ),
        ),
      ),
    );
  });

  testWidgets('handles can extend selection across lines and wide characters', (
    tester,
  ) async {
    await openTerminal(tester, output: 'hello\r\n甲乙丙');
    await longPressCell(tester, 2);
    final render = terminalView(tester).renderTerminal;
    final width = render.cellSize.width;
    await tester.drag(item('selection-start'), Offset(width, 0));
    await tester.pumpAndSettle();
    await tester.drag(
      item('selection-end'),
      Offset(-2 * width, render.lineHeight),
    );
    await tester.pumpAndSettle();
    await tester.tap(item('copy'));
    await tester.pumpAndSettle();
    expect(clipboard, 'ello\n甲乙');
  });

  testWidgets('paste uses terminal bracketed paste without appending enter', (
    tester,
  ) async {
    final fixture = await openTerminal(tester);
    fixture.session.terminal.write('\x1b[?2004h');
    clipboard = 'echo hello';
    await longPressCell(tester, 1);
    await tester.tap(find.text('粘贴'));
    await tester.pumpAndSettle();
    expect(fixture.sent, ['\x1b[200~echo hello\x1b[201~']);
  });

  testWidgets('blank output still offers paste and disables empty copy', (
    tester,
  ) async {
    final fixture = await openTerminal(tester, output: '');
    clipboard = 'pwd';
    await longPressCell(tester, 1);
    expect(enabled(tester, 'copy'), isFalse);
    expect(enabled(tester, 'paste'), isTrue);
    await tester.tap(find.text('粘贴'));
    await tester.pumpAndSettle();
    expect(fixture.sent, ['pwd']);
  });

  testWidgets('disconnected terminals can copy output but cannot paste', (
    tester,
  ) async {
    final fixture = await openTerminal(tester, connected: false);
    await longPressCell(tester, 1);
    expect(enabled(tester, 'copy'), isTrue);
    expect(enabled(tester, 'paste'), isFalse);
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(clipboard, 'hello');
    expect(fixture.sent, isEmpty);
  });

  testWidgets('disconnecting with the menu open prevents pending paste', (
    tester,
  ) async {
    final fixture = await openTerminal(tester);
    clipboard = 'pwd';
    await longPressCell(tester, 1);
    fixture.session.stop();
    await tester.pumpAndSettle();
    expect(enabled(tester, 'paste'), isFalse);
    expect(fixture.sent, isEmpty);
  });

  testWidgets('clipboard data returned after disconnect is never sent', (
    tester,
  ) async {
    final fixture = await openTerminal(tester);
    pendingRead = Completer();
    await longPressCell(tester, 1);
    await tester.tap(item('paste'));
    await tester.pump();
    fixture.session.stop();
    pendingRead!.complete({'text': 'pwd'});
    await tester.pumpAndSettle();
    expect(fixture.sent, isEmpty);
  });

  testWidgets('scrolling and short taps do not open clipboard menus', (
    tester,
  ) async {
    await openTerminal(tester, output: 'line\r\n' * 100);
    await tester.drag(find.byType(TerminalView), const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(item('paste'), findsNothing);
    await tester.tap(find.byType(TerminalView));
    await tester.pumpAndSettle();
    expect(item('paste'), findsNothing);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TerminalView)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox.shrink());
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
