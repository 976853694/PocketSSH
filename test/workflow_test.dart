import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Android workflow builds after verification and signs only from secrets',
    () {
      final workflow = File('.github/workflows/android.yml').readAsStringSync();
      expect(workflow, contains('run: flutter analyze'));
      expect(workflow, contains('run: flutter test'));
      expect(workflow, contains('needs: verify'));
      expect(
        workflow,
        contains('flutter build apk --debug --target-platform android-arm64'),
      );
      expect(workflow, contains('name: pocket-ssh-debug-arm64'));
      expect(workflow, contains('secrets.ANDROID_KEYSTORE_BASE64'));
      expect(workflow, contains('SIGN_ANDROID_RELEASE'));
      expect(workflow, isNot(contains('-----BEGIN')));
    },
  );
}
