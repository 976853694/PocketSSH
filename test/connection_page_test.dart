import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/main.dart';
import 'package:pocket_ssh/core/ssh_connection.dart';

void main() {
  test('normalizes host names and formats IPv6 endpoints with their ports', () {
    expect(normalizeHost(' Server.Example '), 'server.example');
    final host = normalizeHost('[2001:db8::1]');
    expect(host, '2001:db8::1');
    expect(SshTarget(host!, 2222, 'user').endpoint, '[2001:db8::1]:2222');
    expect(normalizeHost('https://server.example'), isNull);
    expect(normalizeHost('server.example:22'), isNull);
  });

  testWidgets('empty credentials are rejected before navigating',
      (tester) async {
    await tester.pumpWidget(const PocketSshApp());
    final connect = find.text('连接');
    await tester.ensureVisible(connect);
    await tester.tap(connect);
    await tester.pump();
    expect(find.text('请输入有效的主机名或 IP'), findsOneWidget);
    expect(find.text('请输入用户名'), findsOneWidget);
    expect(find.text('请输入密码'), findsOneWidget);
  });

  testWidgets('choosing private-key auth replaces the password field',
      (tester) async {
    await tester.pumpWidget(const PocketSshApp());
    await tester.tap(find.text('私钥'));
    await tester.pumpAndSettle();
    expect(find.text('选择私钥文件'), findsOneWidget);
    expect(find.text('私钥口令（可选）'), findsOneWidget);
  });
}
