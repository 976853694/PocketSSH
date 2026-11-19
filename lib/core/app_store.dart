import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'host_trust.dart';

class HostProfile {
  HostProfile({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    this.username = 'root',
    this.group = '',
    this.keyAuth = false,
    this.remember = false,
    this.lastUsed,
    this.jumpId,
    this.localForwardPort,
    this.forwardTargetHost = '127.0.0.1',
    this.forwardTargetPort = 5432,
  });
  final String id;
  String name, host, username, group;
  int port;
  bool keyAuth, remember;
  DateTime? lastUsed;
  String? jumpId;
  int? localForwardPort;
  String forwardTargetHost;
  int forwardTargetPort;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'group': group,
    'keyAuth': keyAuth,
    'remember': remember,
    'lastUsed': lastUsed?.toIso8601String(),
    'jumpId': jumpId,
    'localForwardPort': localForwardPort,
    'forwardTargetHost': forwardTargetHost,
    'forwardTargetPort': forwardTargetPort,
  };
  factory HostProfile.fromJson(Map<String, dynamic> j) => HostProfile(
    id: j['id'] as String,
    name: j['name'] as String,
    host: j['host'] as String,
    port: j['port'] as int,
    username: j['username'] as String,
    group: j['group'] as String? ?? '',
    keyAuth: j['keyAuth'] == true,
    remember: j['remember'] == true,
    lastUsed: DateTime.tryParse(j['lastUsed'] as String? ?? ''),
    jumpId: j['jumpId'] as String?,
    localForwardPort: j['localForwardPort'] as int?,
    forwardTargetHost: j['forwardTargetHost'] as String? ?? '127.0.0.1',
    forwardTargetPort: j['forwardTargetPort'] as int? ?? 5432,
  );
}

class Credentials {
  Credentials({this.password = '', this.key = '', this.passphrase = ''});
  String password, key, passphrase;
  Map<String, dynamic> toJson() => {
    'password': password,
    'key': key,
    'passphrase': passphrase,
  };
  factory Credentials.fromJson(Map<String, dynamic> j) => Credentials(
    password: j['password'] as String? ?? '',
    key: j['key'] as String? ?? '',
    passphrase: j['passphrase'] as String? ?? '',
  );
}

class AppStore extends ChangeNotifier {
  AppStore({this.channel = androidBridge});
  final MethodChannel channel;
  final List<HostProfile> hosts = [];
  final List<String> snippets = [];
  final List<String> recentCommands = [];
  String theme = 'system',
      terminalTheme = 'dark',
      aiEndpoint = '',
      aiModel = '';
  double fontSize = 14;
  int scrollback = 5000;
  bool keepAwake = false, deviceLock = false, recentCommandHistory = false;
  String? error;

  Future<void> load() async {
    try {
      final raw = await channel.invokeMethod<String>('loadState');
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        hosts.addAll(
          (j['hosts'] as List? ?? []).map(
            (x) => HostProfile.fromJson(Map<String, dynamic>.from(x as Map)),
          ),
        );
        snippets.addAll((j['snippets'] as List? ?? []).cast<String>());
        recentCommands.addAll(
          (j['recentCommands'] as List? ?? []).cast<String>(),
        );
        theme = j['theme'] as String? ?? 'system';
        terminalTheme = j['terminalTheme'] as String? ?? 'dark';
        aiEndpoint = j['aiEndpoint'] as String? ?? '';
        aiModel = j['aiModel'] as String? ?? '';
        fontSize = (j['fontSize'] as num?)?.toDouble() ?? 14;
        scrollback = j['scrollback'] as int? ?? 5000;
        keepAwake = j['keepAwake'] == true;
        deviceLock = j['deviceLock'] == true;
        recentCommandHistory = j['recentCommandHistory'] == true;
      }
    } catch (_) {
      error = '无法读取本地配置，请检查应用存储。';
    }
    notifyListeners();
  }

  Future<void> save() async {
    await channel.invokeMethod<void>(
      'saveState',
      jsonEncode({
        'hosts': hosts.map((h) => h.toJson()).toList(),
        'snippets': snippets,
        'recentCommands': recentCommands,
        'theme': theme,
        'terminalTheme': terminalTheme,
        'fontSize': fontSize,
        'scrollback': scrollback,
        'keepAwake': keepAwake,
        'deviceLock': deviceLock,
        'recentCommandHistory': recentCommandHistory,
        'aiEndpoint': aiEndpoint,
        'aiModel': aiModel,
      }),
    );
    notifyListeners();
  }

  Future<bool> isUnlocked() => unlock();
  Future<bool> unlock() async =>
      !deviceLock || await channel.invokeMethod<bool>('authenticate') == true;
  Future<String?> secret(String key) =>
      channel.invokeMethod<String>('readSecret', key);
  Future<void> putSecret(String key, String? value) =>
      channel.invokeMethod<void>('writeSecret', {'key': key, 'value': value});
  Future<Credentials?> credentials(
    HostProfile host, {
    bool authenticate = true,
  }) async {
    if (!host.remember) return null;
    if (authenticate && !await unlock()) throw StateError('设备认证已取消');
    final raw = await secret('host:${host.id}');
    return raw == null
        ? null
        : Credentials.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> deleteHost(HostProfile host) async {
    await putSecret('host:${host.id}', null);
    hosts.removeWhere((x) => x.id == host.id);
    for (final h in hosts) {
      if (h.jumpId == host.id) h.jumpId = null;
    }
    await save();
  }
}

bool isHighRiskCommand(String command) {
  final value = command
      .toLowerCase()
      .replaceAll('\t', ' ')
      .replaceAll('\n', ' ')
      .split(' ')
      .where((part) => part.isNotEmpty)
      .join(' ');
  return value.contains('rm -rf') ||
      value.contains('rm -r') && value.contains(' -f') ||
      value.contains('mkfs') ||
      value.contains('dd ') && value.contains('of=') ||
      value.contains('shutdown') ||
      value.contains('reboot') ||
      value.contains('poweroff') ||
      value.contains('chmod -r') ||
      value.contains('chown -r') ||
      value.contains('drop database') ||
      value.contains('drop table') ||
      value.contains('find ') && value.contains('-delete') ||
      value.contains('curl ') && value.contains('| sh') ||
      value.contains('wget ') && value.contains('| sh');
}

String redactSecrets(String value) => value
    .replaceAll(
      RegExp(
        r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----',
      ),
      '[私钥已隐藏]',
    )
    .replaceAllMapped(
      RegExp(r'([a-z][a-z0-9+.-]*://[^:/\s@]+:)[^@\s]+@', caseSensitive: false),
      (match) => '${match[1]}[已隐藏]@',
    )
    .replaceAllMapped(
      RegExp(
        r'(authorization\s*[:=]\s*|(?:aws[_-]?)?(?:password|passwd|token|api[_-]?key|access[_-]?key|secret(?:[_-]access)?[_-]?key)\s*[:=]\s*)([^\r\n]+)',
        caseSensitive: false,
      ),
      (m) => '${m[1]}[已隐藏]',
    );
