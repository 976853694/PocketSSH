import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/app_store.dart';
import 'package:pocket_ssh/core/host_backup.dart';

void main() {
  test(
    'profile backups exclude credentials and device-specific associations',
    () {
      final source = HostProfile(
        id: 'local',
        name: 'Example',
        host: 'example.test',
        port: 2222,
        username: 'ops',
        auth: HostAuth.privateKey,
        remember: true,
        jumpId: 'jump',
      );
      final backup = exportHosts([source]);
      expect(backup, isNot(contains('remember')));
      expect(backup, isNot(contains('jumpId')));
      final restored = importHosts(backup).single;
      expect(restored.id, isNot(source.id));
      expect(restored.port, 2222);
      expect(restored.auth, HostAuth.privateKey);
      expect(restored.remember, isFalse);
    },
  );

  test('backup preserves none authentication and imports old key profiles', () {
    final host = HostProfile(
      id: 'local',
      name: 'Example',
      host: 'example.test',
      auth: HostAuth.none,
    );
    expect(importHosts(exportHosts([host])).single.auth, HostAuth.none);
    final legacy = importHosts('''
      {"version":1,"hosts":[{"name":"Old","host":"example.test",
      "port":22,"username":"ops","keyAuth":true}]}
    ''').single;
    expect(legacy.auth, HostAuth.privateKey);
  });

  test('profile import rejects invalid target ports', () {
    final backup = exportHosts([
      HostProfile(id: 'local', name: 'Bad', host: 'example.test', port: 0),
    ]);
    expect(() => importHosts(backup), throwsFormatException);
  });
}
