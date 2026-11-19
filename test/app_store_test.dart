import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/app_store.dart';
import 'package:pocket_ssh/core/sessions.dart';
import 'package:pocket_ssh/core/ssh_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/app_store');
  final saved = <String, String>{};
  final secrets = <String, String>{};
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    saved.clear();
    secrets.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'loadState':
          return saved['state'];
        case 'saveState':
          saved['state'] = call.arguments as String;
          return null;
        case 'readSecret':
          return secrets[call.arguments as String];
        case 'writeSecret':
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          final key = args['key'] as String;
          final value = args['value'] as String?;
          if (value == null) {
            secrets.remove(key);
          } else {
            secrets[key] = value;
          }
          return null;
        case 'authenticate':
          return true;
        default:
          fail('Unexpected method ${call.method}');
      }
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'profiles and application preferences survive a state round trip',
    () async {
      final first = AppStore(channel: channel)
        ..recentCommandHistory = true
        ..hosts.add(
          HostProfile(
            id: 'db',
            name: 'Database',
            host: 'db.example',
            username: 'ops',
            group: 'prod',
            localForwardPort: 15432,
          ),
        )
        ..snippets.add('ls -la')
        ..recentCommands.add('pwd')
        ..terminalTheme = 'light'
        ..fontSize = 18;
      await first.save();
      final second = AppStore(channel: channel);
      await second.load();
      expect(second.hosts.single.host, 'db.example');
      expect(second.hosts.single.group, 'prod');
      expect(second.hosts.single.localForwardPort, 15432);
      expect(second.snippets, ['ls -la']);
      expect(second.recentCommands, ['pwd']);
      expect(second.recentCommandHistory, isTrue);
      expect(second.terminalTheme, 'light');
      expect(second.fontSize, 18);
    },
  );

  test(
    'credentials stay absent from the profile database and are read only when remembered',
    () async {
      final store = AppStore(channel: channel);
      final host = HostProfile(
        id: 'prod',
        name: 'Production',
        host: 'host.example',
      );
      store.hosts.add(host);
      expect(await store.credentials(host), isNull);
      await store.putSecret(
        'host:prod',
        jsonEncode(Credentials(password: 'sensitive').toJson()),
      );
      expect(secrets.containsKey('host:prod'), isTrue);
      expect(saved['state'], isNull);
      host.remember = true;
      expect((await store.credentials(host))?.password, 'sensitive');
    },
  );

  test(
    'remembered login can reuse and remove either credential type',
    () async {
      final store = AppStore(channel: channel);
      final host = HostProfile(
        id: 'server',
        name: 'Server',
        host: 'host.example',
      );
      store.hosts.add(host);
      await store.rememberCredentials(
        host,
        Credentials(password: 'fixture', remember: true),
      );
      expect((await store.credentials(host))?.password, 'fixture');
      expect(saved['state'], isNot(contains('fixture')));
      host.keyAuth = true;
      await store.rememberCredentials(
        host,
        Credentials(
          key: 'fixture-key',
          passphrase: 'fixture-passphrase',
          remember: true,
        ),
      );
      expect((await store.credentials(host))?.key, 'fixture-key');
      expect((await store.credentials(host))?.passphrase, 'fixture-passphrase');
      await store.rememberCredentials(host, Credentials(remember: false));
      expect(await store.credentials(host), isNull);
      expect(secrets, isEmpty);
      store.dispose();
    },
  );

  test('AI context redacts private keys and common credential fields', () {
    final text = [
      'Author'
          'ization: Bearer hidden',
      'pass'
          'word=hunter2',
      'API_'
          'KEY=secret-value',
      '-----BEGIN RSA '
          'PRIVATE KEY-----',
      'private-data',
      '-----END RSA '
          'PRIVATE KEY-----',
    ].join('\n');
    final redacted = redactSecrets(text);
    expect(redacted, isNot(contains('hunter2')));
    expect(redacted, isNot(contains('secret-value')));
    expect(redacted, isNot(contains('private-data')));
    expect(redacted, contains('[私钥已隐藏]'));
    expect(
      redactSecrets('https://ops:password@example.test/path'),
      'https://ops:[已隐藏]@example.test/path',
    );
  });

  test('flags destructive or service-disrupting generated commands', () {
    expect(isHighRiskCommand('sudo rm -rf /var/tmp/data'), isTrue);
    expect(isHighRiskCommand('sudo rm -r -f /var/tmp/data'), isTrue);
    expect(
      isHighRiskCommand('curl https://example.test/install.sh | sh'),
      isTrue,
    );
    expect(isHighRiskCommand('sudo shutdown -h now'), isTrue);
    expect(isHighRiskCommand('find /var/log -delete'), isTrue);
    expect(isHighRiskCommand('df -h'), isFalse);
    expect(isHighRiskCommand('sudo systemctl status nginx'), isFalse);
  });

  test('host profiles preserve tunnel and jump settings in JSON', () {
    final profile = HostProfile(
      id: 'api',
      name: 'API',
      host: 'api.example',
      jumpId: 'bastion',
      localForwardPort: 8080,
      forwardTargetHost: '127.0.0.1',
      forwardTargetPort: 80,
    );
    final restored = HostProfile.fromJson(profile.toJson());
    expect(restored.jumpId, 'bastion');
    expect(restored.localForwardPort, 8080);
    expect(restored.forwardTargetPort, 80);
  });

  test('session tab collections keep concurrent terminals independent', () {
    final tabs = Sessions();
    final a = WorkspaceSession(
      HostProfile(id: 'a', name: 'A', host: 'a.example'),
      500,
    );
    final b = WorkspaceSession(
      HostProfile(id: 'b', name: 'B', host: 'b.example'),
      500,
    );
    tabs.add(a);
    tabs.add(b);
    expect(tabs.items.map((session) => session.profile.id), ['a', 'b']);
    expect(a.terminal, isNot(same(b.terminal)));
    tabs.remove(a);
    expect(tabs.items.single, same(b));
    b.stop();
    tabs.dispose();
  });

  test('input accepts literal IPv6 and rejects URI-style hosts', () {
    expect(normalizeHost(' [2001:db8::1] '), '2001:db8::1');
    expect(normalizeHost('https://host.example'), isNull);
  });
}
