import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const nativeDeviceChannel = MethodChannel('app.pocketssh/device');
const deviceBridge = DeviceBridge();

class DeviceBridge {
  const DeviceBridge({this.channel = nativeDeviceChannel});
  final MethodChannel channel;
  static const _vault = FlutterSecureStorage(
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );
  static final _documents = <String, _Document>{};
  static bool get _portable =>
      Platform.isIOS || Platform.isMacOS || Platform.isWindows;

  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    if (!_portable || channel != nativeDeviceChannel) {
      if (method == 'finishDownload') {
        return channel.invokeMethod<T>('closeDocument', arguments);
      }
      return channel.invokeMethod<T>(method, arguments);
    }
    try {
      return await _invoke(method, arguments) as T?;
    } on PlatformException {
      rethrow;
    } catch (_) {
      throw PlatformException(code: 'device_operation', message: '系统操作失败');
    }
  }

  String _key(String prefix, String value) =>
      '$prefix${base64Url.encode(utf8.encode(value))}';

  Future<Object?> _invoke(String method, Object? args) async {
    switch (method) {
      case 'loadState':
        return _vault.read(key: 'pocketssh_state');
      case 'saveState':
        await _vault.write(key: 'pocketssh_state', value: args as String);
      case 'readSecret':
        return _vault.read(key: _key('secret_', args as String));
      case 'writeSecret':
        final values = args as Map;
        await _vault.write(
          key: _key('secret_', values['key'] as String),
          value: values['value'] as String?,
        );
      case 'readHost':
        return _vault.read(key: _key('host_', args as String));
      case 'forgetHost':
        await _vault.delete(key: _key('host_', args as String));
      case 'rememberHost':
        final values = args as Map;
        final key = _key('host_', values['endpoint'] as String);
        final value = values['fingerprint'] as String;
        final saved = await _vault.read(key: key);
        if (saved != null && saved != value) {
          throw PlatformException(
            code: 'host_key_changed',
            message: '服务器指纹已变更',
          );
        }
        await _vault.write(key: key, value: value);
      case 'authenticate':
        return LocalAuthentication().authenticate(
          localizedReason: '解锁 Pocket SSH 中保存的凭据',
        );
      case 'keepAwake':
        await WakelockPlus.toggle(enable: args == true);
      case 'pickKey':
        final selected = await openFile();
        if (selected == null) return null;
        final data = BytesBuilder(copy: false);
        await for (final chunk in selected.openRead(0, 128 * 1024 + 1)) {
          data.add(chunk);
          if (data.length > 128 * 1024) throw const FormatException();
        }
        return data.takeBytes();
      case 'pickUpload':
        final selected = await openFile();
        if (selected == null) return null;
        final size = await selected.length();
        final document = _Document(await File(selected.path).open());
        final id = _register(document);
        return {'uri': id, 'name': selected.name, 'size': size};
      case 'createDownload':
        final name = args as String;
        if (name.isEmpty ||
            name == '.' ||
            name == '..' ||
            name.contains('/') ||
            name.contains('\\') ||
            name.contains('\u0000')) {
          throw const FormatException();
        }
        final destination = Platform.isIOS
            ? null
            : await getSaveLocation(suggestedName: name);
        if (!Platform.isIOS && destination == null) return null;
        final temp = await Directory.systemTemp.createTemp('pocketssh-');
        final staged = File(
          '${temp.path}${Platform.pathSeparator}${Platform.isIOS ? name : 'download'}',
        );
        try {
          final id = _register(
            _Document(
              await staged.open(mode: FileMode.write),
              temp: temp,
              staged: staged,
              destination: destination?.path,
            ),
          );
          return {'uri': id};
        } catch (_) {
          await temp.delete(recursive: true);
          rethrow;
        }
      case 'readChunk':
        final bytes = await _documents[args as String]!.handle.read(64 * 1024);
        return bytes.isEmpty ? null : bytes;
      case 'writeChunk':
        final values = args as Map;
        await _documents[values['uri']]!.handle.writeFrom(
          values['bytes'] as Uint8List,
        );
      case 'closeDocument':
      case 'deleteDocument':
      case 'finishDownload':
        final document = _documents.remove(args as String);
        if (document == null) return method == 'deleteDocument' ? false : null;
        try {
          await document.handle.close();
          if (method == 'finishDownload') {
            final staged = document.staged!;
            if (Platform.isIOS) {
              final saved = await channel.invokeMethod<bool>(
                'exportDocument',
                staged.path,
              );
              if (saved != true) {
                throw PlatformException(
                  code: 'save_cancelled',
                  message: '已取消保存文件',
                );
              }
            } else {
              await staged.copy(document.destination!);
            }
          }
        } finally {
          await document.temp?.delete(recursive: true);
        }
        return method == 'deleteDocument' ? true : null;
      default:
        throw MissingPluginException(method);
    }
    return null;
  }

  static int _sequence = 0;
  String _register(_Document document) {
    final id = '${_sequence++}';
    _documents[id] = document;
    return id;
  }
}

class _Document {
  const _Document(this.handle, {this.temp, this.staged, this.destination});
  final RandomAccessFile handle;
  final Directory? temp;
  final File? staged;
  final String? destination;
}
