import 'dart:convert';

import 'app_store.dart';
import 'ssh_connection.dart';

String exportHosts(Iterable<HostProfile> hosts) => jsonEncode({
  'version': 2,
  'hosts': [
    for (final host in hosts)
      {
        'name': host.name,
        'host': host.host,
        'port': host.port,
        'username': host.username,
        'group': host.group,
        'auth': host.auth.name,
      },
  ],
});

List<HostProfile> importHosts(String input) {
  if (input.length > 512 * 1024) throw const FormatException();
  final data = jsonDecode(input);
  if (data is! Map || data['hosts'] is! List) throw const FormatException();
  final version = data['version'];
  if (version != 1 && version != 2) throw const FormatException();
  final rows = data['hosts'] as List;
  if (rows.length > 1000) throw const FormatException();
  final idPrefix = DateTime.now().microsecondsSinceEpoch;
  final result = <HostProfile>[];
  for (final row in rows) {
    if (row is! Map) throw const FormatException();
    String field(String key, {bool optional = false}) {
      final value = row[key];
      if (value == null && optional) return '';
      if (value is! String ||
          value.length > 255 ||
          value.codeUnits.any((unit) => unit < 32 || unit == 127) ||
          (!optional && value.trim().isEmpty)) {
        throw const FormatException();
      }
      return value.trim();
    }

    final host = normalizeHost(field('host'));
    final port = row['port'];
    if (host == null ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        (version == 1 ? row['keyAuth'] is! bool : row['auth'] is! String)) {
      throw const FormatException();
    }
    result.add(
      HostProfile(
        id: 'import-$idPrefix-${result.length}',
        name: field('name'),
        host: host,
        port: port,
        username: field('username'),
        group: field('group', optional: true),
        auth: HostAuth.decode(
          version == 1 ? null : row['auth'],
          legacyKeyAuth: row['keyAuth'] == true,
        ),
      ),
    );
  }
  return result;
}
