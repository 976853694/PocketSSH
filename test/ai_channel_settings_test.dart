import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/app_store.dart';
import 'package:pocket_ssh/core/device_bridge.dart';
import 'package:pocket_ssh/main.dart';

class _SettingsStore extends AppStore {
  bool failSave = false;
  String? savedName;
  Map<String, String> headers = {};
  @override
  Future<Map<String, String>> aiHeaders(String input) async => Map.of(headers);
  @override
  Future<void> putAiHeaders(String input, Map<String, String> values) async {
    headers = Map.of(values);
  }

  @override
  Future<void> save() async {
    if (failSave) throw StateError('storage unavailable');
    savedName = aiChannelName;
  }
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pumpAndSettle();
}

Future<void> _showHeaders(WidgetTester tester, _SettingsStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SettingsPage(store: store, section: 'ai'),
      ),
    ),
  );
  final vertical = find
      .byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      )
      .last;
  await tester.scrollUntilVisible(
    find.text('自定义请求头'),
    250,
    scrollable: vertical,
  );
  await _reveal(tester, find.text('自定义请求头'));
  await tester.tap(find.text('自定义请求头'));
  await tester.pumpAndSettle();
}

Future<void> _saveHeadersForm(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
  await _reveal(tester, find.text('加密保存 AI 设置'));
  await tester.tap(find.text('加密保存 AI 设置'));
  await tester.pumpAndSettle();
}

void main() {
  for (final (theme, textScale) in [('light', 1.0), ('dark', 1.5)]) {
    testWidgets('AI field labels clear the border and value in $theme mode', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(nativeDeviceChannel, (call) async {
        expect(call.method, 'loadState');
        return jsonEncode({
          'theme': theme,
          'aiChannelName': '测试渠道',
          'aiEndpoint': 'https://models.example.test',
          'aiModel': 'fixture-model',
          'aiApi': 'responses',
        });
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(nativeDeviceChannel, null),
      );

      await tester.pumpWidget(const PocketSshApp());
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('设置'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI 助手'));
      await tester.pumpAndSettle();

      for (final (title, previousHelp, value) in [
        ('AI 网站地址（HTTP / HTTPS）', '留空时显示网站域名', find.byType(EditableText)),
        ('接口类型', '只填网站，接口路径自动补全', find.text('Responses')),
      ]) {
        final label = find.text(title);
        final field = find.ancestor(
          of: label,
          matching: find.byType(InputDecorator),
        );
        final labelRect = tester.getRect(label);
        final valueRect = tester.getRect(
          find.descendant(of: field, matching: value),
        );
        expect(labelRect.top, greaterThan(tester.getTopLeft(field).dy));
        expect(
          labelRect.top,
          greaterThan(tester.getBottomLeft(find.text(previousHelp)).dy),
        );
        expect(labelRect.bottom, lessThanOrEqualTo(valueRect.top));
      }
    });
  }

  for (final failSave in [false, true]) {
    testWidgets(
      'custom headers ${failSave ? 'restore old encrypted values after failed save' : 'can be edited with values hidden by default'}',
      (tester) async {
        final store = _SettingsStore()
          ..aiEndpoint = 'http://models.example.test'
          ..aiModel = 'fixture-model'
          ..headers = {'X-Channel': 'old-fixture-value'}
          ..failSave = failSave;
        await _showHeaders(tester, store);
        final value = find.widgetWithText(TextField, '请求头值');
        expect(tester.widget<TextField>(value).obscureText, isTrue);
        await _reveal(tester, value);
        await tester.enterText(value, 'new-fixture-value');
        await _saveHeadersForm(tester);
        expect(store.headers, {
          'X-Channel': failSave ? 'old-fixture-value' : 'new-fixture-value',
        });
        await tester.pumpWidget(const SizedBox.shrink());
        store.dispose();
      },
    );
  }

  testWidgets('headers can be added and explicitly removed', (tester) async {
    final store = _SettingsStore()
      ..aiEndpoint = 'http://models.example.test'
      ..aiModel = 'fixture-model';
    await _showHeaders(tester, store);
    await _reveal(tester, find.text('添加请求头'));
    await tester.tap(find.text('添加请求头'));
    await tester.pumpAndSettle();
    final name = find.widgetWithText(TextField, '请求头名称');
    final value = find.widgetWithText(TextField, '请求头值');
    await _reveal(tester, name);
    await tester.enterText(name, 'X-Channel');
    await _reveal(tester, value);
    await tester.enterText(value, 'fixture-value');
    await _saveHeadersForm(tester);
    expect(store.headers, {'X-Channel': 'fixture-value'});
    await _reveal(tester, find.byTooltip('删除请求头'));
    await tester.tap(find.byTooltip('删除请求头'));
    await tester.pumpAndSettle();
    await _saveHeadersForm(tester);
    expect(store.headers, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  for (final failSave in [false, true]) {
    testWidgets(
      'channel name ${failSave ? 'rolls back after a failed save' : 'is saved from the website settings form'}',
      (tester) async {
        final store = _SettingsStore()
          ..aiEndpoint = 'http://models.example.test'
          ..aiModel = 'test-model'
          ..aiChannelName = '原渠道'
          ..failSave = failSave;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SettingsPage(store: store, section: 'ai'),
            ),
          ),
        );
        final vertical = find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .last;
        await tester.scrollUntilVisible(
          find.text('渠道名称'),
          250,
          scrollable: vertical,
        );
        final field = find.widgetWithText(TextField, '渠道名称');
        await _reveal(tester, field);
        await tester.enterText(field, '  新渠道  ');
        tester.testTextInput.hide();
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('加密保存 AI 设置'),
          250,
          scrollable: vertical,
        );
        await _reveal(tester, find.text('加密保存 AI 设置'));
        await tester.tap(find.text('加密保存 AI 设置'));
        await tester.pumpAndSettle();
        expect(store.aiChannelName, failSave ? '原渠道' : '新渠道');
        expect(store.savedName, failSave ? isNull : '新渠道');
        expect(store.aiEndpoint, 'http://models.example.test');
        expect(
          find.text(failSave ? '无法保存 AI 设置，请重试' : 'AI 设置已保存'),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        store.dispose();
      },
    );
  }
}
