import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/host_trust.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/host_trust');
  const trust = HostTrust(channel: channel);
  const endpoint = 'server.example:22';
  const fingerprint = 'SHA256:expected';
  final pins = <String, String>{};
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    pins.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'readHost':
          return pins[call.arguments];
        case 'rememberHost':
          final args = call.arguments as Map<Object?, Object?>;
          pins[args['endpoint'] as String] = args['fingerprint'] as String;
          return null;
        case 'forgetHost':
          pins.remove(call.arguments);
          return null;
        default:
          fail('Unexpected method ${call.method}');
      }
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('first connection only remembers an accepted fingerprint', () async {
    expect(
        await trust.verify(
            endpoint: endpoint,
            fingerprint: fingerprint,
            confirm: () async => false),
        isFalse);
    expect(pins, isEmpty);
    expect(
        await trust.verify(
            endpoint: endpoint,
            fingerprint: fingerprint,
            confirm: () async => true),
        isTrue);
    expect(pins[endpoint], fingerprint);
  });

  test('a matching fingerprint is accepted without a second prompt', () async {
    pins[endpoint] = fingerprint;
    expect(
        await trust.verify(
            endpoint: endpoint,
            fingerprint: fingerprint,
            confirm: () async => fail('unexpected prompt')),
        isTrue);
  });

  test(
      'a changed fingerprint is blocked and leaves the known fingerprint intact',
      () async {
    pins[endpoint] = fingerprint;
    await expectLater(
      trust.verify(
          endpoint: endpoint,
          fingerprint: 'SHA256:changed',
          confirm: () async => fail('unexpected prompt')),
      throwsA(isA<HostKeyChanged>()),
    );
    expect(pins[endpoint], fingerprint);
  });

  test('trust is scoped to one host and port', () async {
    pins[endpoint] = fingerprint;
    pins['server.example:2222'] = fingerprint;
    await trust.forget(endpoint);
    expect(pins, {'server.example:2222': fingerprint});
  });

  test('storage failure does not silently trust the endpoint', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readHost') return null;
      throw PlatformException(code: 'host_store');
    });
    await expectLater(
      trust.verify(
          endpoint: endpoint,
          fingerprint: fingerprint,
          confirm: () async => true),
      throwsA(isA<PlatformException>()),
    );
  });
}
