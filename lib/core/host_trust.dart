import 'package:flutter/services.dart';

const androidBridge = MethodChannel('app.pocketssh/device');

class HostKeyChanged implements Exception {
  const HostKeyChanged(this.expected, this.received);

  final String expected;
  final String received;
}

class HostTrust {
  const HostTrust({this.channel = androidBridge});

  final MethodChannel channel;

  Future<bool> verify({
    required String endpoint,
    required String fingerprint,
    required Future<bool> Function() confirm,
  }) async {
    final known = await channel.invokeMethod<String>('readHost', endpoint);
    if (known != null) {
      if (known != fingerprint) throw HostKeyChanged(known, fingerprint);
      return true;
    }
    if (!await confirm()) return false;
    await channel.invokeMethod<void>('rememberHost', {
      'endpoint': endpoint,
      'fingerprint': fingerprint,
    });
    return true;
  }

  Future<void> forget(String endpoint) =>
      channel.invokeMethod<void>('forgetHost', endpoint);
}
