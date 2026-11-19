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
        keyAuth: true,
        remember: true,
        jumpId: 'jump',
      );
      final backup = exportHosts([source]);
      expect(backup, isNot(contains('remember')));
      expect(backup, isNot(contains('jumpId')));
      final restored = importHosts(backup).single;
      expect(restored.id, isNot(source.id));
      expect(restored.port, 2222);
      expect(restored.keyAuth, isTrue);
      expect(restored.remember, isFalse);
    },
  );

  test('profile import rejects invalid target ports', () {
    final backup = exportHosts([
      HostProfile(id: 'local', name: 'Bad', host: 'example.test', port: 0),
    ]);
    expect(() => importHosts(backup), throwsFormatException);
  });
}
