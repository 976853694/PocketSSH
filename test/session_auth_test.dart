import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/app_store.dart';
import 'package:pocket_ssh/core/sessions.dart';
import 'package:pocket_ssh/core/ssh_connection.dart';

class _Connection extends SshConnection {
  _Connection({this.rejectAuth = false});

  final bool rejectAuth;
  final _done = Completer<void>();
  String? sentPassword, sentKey, sentPassphrase;

  @override
  Future<void> get done => _done.future;

  @override
  Future<SSHSession?> open({
    required SshTarget target,
    required Future<bool> Function(String, String) verify,
    required int columns,
    required int rows,
    String? password,
    Uint8List? privateKey,
    String? passphrase,
    Future<SSHSocket> Function()? dial,
    bool interactive = true,
    void Function(String)? onStage,
  }) async {
    if (!await verify('ssh-ed25519', 'fixture-fingerprint')) {
      throw SSHHostkeyError('Host key rejected');
    }
    sentPassword = password;
    sentKey = privateKey == null ? null : utf8.decode(privateKey);
    sentPassphrase = passphrase;
    if (rejectAuth) throw SSHAuthFailError('Credentials required');
    return null;
  }

  @override
  void close() {
    if (!_done.isCompleted) _done.complete();
    super.close();
  }
}

void main() {
  for (final auth in HostAuth.values) {
    test(
      '$auth sends only its credentials after verifying the target',
      () async {
        final connection = _Connection();
        final profile = HostProfile(
          id: 'id',
          name: 'Fixture',
          host: 'example.test',
          auth: auth,
        );
        final session = WorkspaceSession(profile, 500)..connection = connection;
        addTearDown(() {
          session.stop();
          session.dispose();
        });
        var verified = false;
        await session.open(
          Credentials(
            password: 'fixture-password',
            key: 'fixture-key',
            passphrase: 'fixture-passphrase',
          ),
          (target, type, fingerprint) async {
            expect(target.endpoint, 'example.test:22');
            expect(type, 'ssh-ed25519');
            expect(fingerprint, 'fixture-fingerprint');
            verified = true;
            return true;
          },
          fileOnly: true,
        );
        expect(verified, isTrue);
        expect(session.connected, isTrue);
        expect(
          connection.sentPassword,
          auth == HostAuth.password ? 'fixture-password' : null,
        );
        expect(
          connection.sentKey,
          auth == HostAuth.privateKey ? 'fixture-key' : null,
        );
        expect(
          connection.sentPassphrase,
          auth == HostAuth.privateKey ? 'fixture-passphrase' : null,
        );
      },
    );
  }

  test('server rejection of none does not fall back to a credential', () async {
    final connection = _Connection(rejectAuth: true);
    final session = WorkspaceSession(
      HostProfile(
        id: 'id',
        name: 'Fixture',
        host: 'example.test',
        auth: HostAuth.none,
      ),
      500,
    )..connection = connection;
    addTearDown(session.dispose);
    await session.open(Credentials(), (_, _, _) async => true, fileOnly: true);
    expect(session.connected, isFalse);
    expect(session.status, contains('服务器未接受无凭据认证'));
    expect(connection.sentPassword, isNull);
    expect(connection.sentKey, isNull);
  });

  test('none still honors rejected host fingerprints', () async {
    final session = WorkspaceSession(
      HostProfile(
        id: 'id',
        name: 'Fixture',
        host: 'example.test',
        auth: HostAuth.none,
      ),
      500,
    )..connection = _Connection();
    addTearDown(session.dispose);
    await session.open(Credentials(), (_, _, _) async => false, fileOnly: true);
    expect(session.connected, isFalse);
    expect(session.status, '服务器指纹校验未通过。');
  });
}
