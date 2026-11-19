import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

import '../../core/host_trust.dart';
import '../../core/ssh_connection.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({
    super.key,
    required this.target,
    this.password,
    this.privateKey,
    this.passphrase,
    this.hostTrust = const HostTrust(),
  });

  final SshTarget target;
  final String? password;
  final Uint8List? privateKey;
  final String? passphrase;
  final HostTrust hostTrust;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final _terminal = Terminal(maxLines: 3000);
  final _view = GlobalKey<TerminalViewState>();
  final _connection = SshConnection();
  final _output = <StreamSubscription<String>>[];
  DialogRoute<bool>? _verificationDialog;
  SSHSession? _session;
  String _status = '正在连接…';
  String? _details;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = (text) => _session?.write(utf8.encode(text));
    _terminal.onResize = (columns, rows, width, height) {
      if (columns > 0 && rows > 0) {
        _session?.resizeTerminal(columns, rows, width, height);
      }
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_connect());
    });
  }

  Future<bool> _verify(String type, String fingerprint) async {
    try {
      return await widget.hostTrust.verify(
        endpoint: widget.target.endpoint,
        fingerprint: fingerprint,
        confirm: () => _confirmFingerprint(type, fingerprint),
      );
    } on HostKeyChanged catch (error) {
      _details =
          '服务器指纹已变更，连接已阻止。\n已保存：${error.expected}\n本次收到：${error.received}';
      return false;
    } on PlatformException catch (error) {
      _details = connectionError(error);
      return false;
    }
  }

  Future<bool> _confirmFingerprint(String type, String fingerprint) async {
    if (!mounted || _finished) return false;
    final dialog = DialogRoute<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('核对服务器指纹'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.target.endpoint),
              const SizedBox(height: 8),
              const Text('请与管理员提供的指纹比对，相同后再确认。'),
              const SizedBox(height: 12),
              SelectableText('$type\n$fingerprint'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('拒绝')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('一致并信任')),
        ],
      ),
    );
    _verificationDialog = dialog;
    final accepted = await Navigator.of(context).push(dialog);
    _verificationDialog = null;
    return mounted && !_finished && accepted == true;
  }

  Future<void> _connect() async {
    try {
      final session = await _connection.open(
        target: widget.target,
        verify: _verify,
        columns: _terminal.viewWidth > 0 ? _terminal.viewWidth : 80,
        rows: _terminal.viewHeight > 0 ? _terminal.viewHeight : 24,
        password: widget.password,
        privateKey: widget.privateKey,
        passphrase: widget.passphrase,
      );
      if (!mounted || _finished) return;
      setState(() {
        _session = session;
        _status = '已连接';
      });
      if (_terminal.viewWidth > 0 && _terminal.viewHeight > 0) {
        session.resizeTerminal(_terminal.viewWidth, _terminal.viewHeight);
      }
      final drains = <Future<void>>[];
      for (final stream in [session.stdout, session.stderr]) {
        final drain = Completer<void>();
        drains.add(drain.future);
        _output.add(stream
            .cast<List<int>>()
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(
          _terminal.write,
          onError: (Object error) {
            if (!drain.isCompleted) drain.complete();
            _finish('连接中断', connectionError(error));
          },
          onDone: () {
            if (!drain.isCompleted) drain.complete();
          },
        ));
      }
      await session.done;
      await Future.wait(drains).timeout(const Duration(seconds: 2));
      final code = session.exitCode;
      _finish(code == null ? '会话已结束' : '会话已结束 · 退出码 $code');
    } catch (error) {
      _finish('连接已结束', _details ?? connectionError(error));
    }
  }

  void _finish(String status, [String? details]) {
    if (!mounted || _finished) return;
    _finished = true;
    final dialog = _verificationDialog;
    if (dialog != null && dialog.isActive) {
      dialog.navigator?.removeRoute(dialog);
    }
    _connection.close();
    setState(() {
      _session = null;
      _status = status;
      _details = details;
    });
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted || _session == null || text == null || text.isEmpty) return;
    _terminal.paste(text);
  }

  @override
  void dispose() {
    _finished = true;
    _terminal.onOutput = null;
    _terminal.onResize = null;
    for (final subscription in _output) {
      unawaited(subscription.cancel());
    }
    _connection.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _session != null;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.target.label,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (!_finished)
            IconButton(
              tooltip: connected ? '断开连接' : '取消连接',
              onPressed: () => _finish(connected ? '已断开' : '已取消'),
              icon: const Icon(Icons.link_off_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!connected && !_finished)
              const LinearProgressIndicator(minHeight: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(_status,
                    style: TextStyle(
                        color: connected
                            ? colors.primary
                            : colors.onSurfaceVariant)),
              ),
            ),
            if (_details case final details?)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: SelectableText(details,
                      style: TextStyle(color: colors.error)),
                ),
              ),
            Expanded(
              child: TerminalView(
                _terminal,
                key: _view,
                padding: const EdgeInsets.all(8),
                textStyle: const TerminalStyle(fontSize: 14),
                readOnly: !connected,
                onPaste: _paste,
              ),
            ),
            if (connected)
              SizedBox(
                height: 48,
                child: Row(
                  children: [
                    IconButton(
                        tooltip: '键盘',
                        onPressed: () => _view.currentState?.requestKeyboard(),
                        icon: const Icon(Icons.keyboard_outlined)),
                    Expanded(
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          _key('Esc', TerminalKey.escape),
                          _key('Tab', TerminalKey.tab),
                          _key('Ctrl+C', TerminalKey.keyC, ctrl: true),
                          _key('Ctrl+D', TerminalKey.keyD, ctrl: true),
                          _key('↑', TerminalKey.arrowUp, tooltip: '上方向键'),
                          _key('↓', TerminalKey.arrowDown, tooltip: '下方向键'),
                          _key('←', TerminalKey.arrowLeft, tooltip: '左方向键'),
                          _key('→', TerminalKey.arrowRight, tooltip: '右方向键'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _key(String label, TerminalKey key,
      {bool ctrl = false, String? tooltip}) {
    return Semantics(
      label: tooltip,
      child: TextButton(
        style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 10)),
        onPressed: () => _terminal.keyInput(key, ctrl: ctrl),
        child: Text(label),
      ),
    );
  }
}
