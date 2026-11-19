import 'package:flutter/services.dart';

import 'device_bridge.dart';

class HostKeyChanged implements Exception {
  const HostKeyChanged(this.expected, this.received);

  final String expected;
  final String received;
}

class HostTrust {
  const HostTrust({this.channel = nativeDeviceChannel});

  final MethodChannel channel;
  DeviceBridge get _device => DeviceBridge(channel: channel);

  Future<bool> verify({
    required String endpoint,
    required String fingerprint,
    required Future<bool> Function() confirm,
  }) async {
    final known = await _device.invokeMethod<String>('readHost', endpoint);
    if (known != null) {
      if (known != fingerprint) throw HostKeyChanged(known, fingerprint);
      return true;
    }
    if (!await confirm()) return false;
    await _device.invokeMethod<void>('rememberHost', {
      'endpoint': endpoint,
      'fingerprint': fingerprint,
    });
    return true;
  }

  Future<void> forget(String endpoint) =>
      _device.invokeMethod<void>('forgetHost', endpoint);
}
