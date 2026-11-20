import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/app_store.dart';
import 'package:pocket_ssh/main.dart';

class _SettingsStore extends AppStore {
  bool failSave = false;
  String? savedName;
  @override
  Future<void> save() async {
    if (failSave) throw StateError('storage unavailable');
    savedName = aiChannelName;
  }
}

void main() {
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
            home: Scaffold(body: SettingsPage(store: store)),
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
        await tester.ensureVisible(field);
        await tester.enterText(field, '  新渠道  ');
        tester.testTextInput.hide();
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('加密保存 AI 设置'),
          250,
          scrollable: vertical,
        );
        await tester.ensureVisible(find.text('加密保存 AI 设置'));
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
