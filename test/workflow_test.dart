import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one workflow verifies and builds all four platforms', () {
    final workflows = Directory('.github/workflows')
        .listSync()
        .whereType<File>()
        .where(
          (file) => file.path.endsWith('.yml') || file.path.endsWith('.yaml'),
        );
    expect(workflows.map((file) => file.path), [
      '.github/workflows/platforms.yml',
    ]);
    final workflow = workflows.single.readAsStringSync();
    expect(workflow, contains('run: flutter analyze'));
    expect(workflow, contains('run: flutter test'));
    expect(workflow, contains('needs: verify'));
    expect(
      workflow,
      contains('flutter build apk --debug --target-platform android-arm64'),
    );
    expect(workflow, contains('name: pocket-ssh-debug-arm64'));
    expect(workflow, contains('flutter build ios --release --no-codesign'));
    expect(workflow, contains('flutter build macos --release'));
    expect(workflow, contains('flutter build windows --release'));
    expect(workflow, contains('needs: [android, ios, macos, windows]'));
    expect(workflow, contains('secrets.ANDROID_KEYSTORE_BASE64'));
    expect(workflow, contains('SIGN_ANDROID_RELEASE'));
    expect(workflow, isNot(contains('-----BEGIN')));
  });
}
