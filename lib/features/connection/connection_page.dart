import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/host_trust.dart';
import '../../core/ssh_connection.dart';
import '../terminal/terminal_page.dart';

enum _Auth { password, key }

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key});

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  final _form = GlobalKey<FormState>();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController();
  final _secret = TextEditingController();
  _Auth _auth = _Auth.password;
  Uint8List? _key;
  bool _choosing = false;
  bool _hide = true;

  void _notice(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickKey() async {
    setState(() => _choosing = true);
    try {
      final key = await androidBridge.invokeMethod<Uint8List>('pickKey');
      if (mounted && key != null) setState(() => _key = key);
    } on PlatformException {
      if (mounted) _notice('无法读取私钥文件，请选择不超过 128 KB 的私钥。');
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  Future<void> _forgetHost() async {
    final host = normalizeHost(_host.text);
    final port = int.tryParse(_port.text.trim());
    if (host == null || port == null || port < 1 || port > 65535) {
      _notice('请先填写要清除信任记录的服务器地址和端口。');
      return;
    }
    final endpoint = SshTarget(host, port, '').endpoint;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除服务器信任记录'),
        content: Text('清除 $endpoint 的指纹记录后，下次连接时需要重新核对指纹。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清除')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await const HostTrust().forget(endpoint);
      if (mounted) _notice('已清除服务器信任记录。');
    } on PlatformException {
      if (mounted) _notice('无法清除服务器信任记录。');
    }
  }

  void _connect() {
    if (_choosing || !_form.currentState!.validate()) return;
    if (_auth == _Auth.key && _key == null) {
      _notice('请选择私钥文件。');
      return;
    }
    final target = SshTarget(normalizeHost(_host.text)!,
        int.parse(_port.text.trim()), _user.text.trim());
    final password = _auth == _Auth.password ? _secret.text : null;
    final key = _auth == _Auth.key ? _key : null;
    final passphrase =
        key != null && _secret.text.isNotEmpty ? _secret.text : null;
    FocusManager.instance.primaryFocus?.unfocus();
    _secret.clear();
    setState(() {
      _key = null;
      _hide = true;
    });
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TerminalPage(
          target: target,
          password: password,
          privateKey: key,
          passphrase: passphrase),
    ));
  }

  @override
  void dispose() {
    for (final controller in [_host, _port, _user, _secret]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pocket SSH'),
        actions: [
          PopupMenuButton<String>(
            tooltip: '服务器选项',
            onSelected: (_) => _forgetHost(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'forget', child: Text('清除服务器信任记录'))
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Icon(Icons.terminal_rounded,
                              size: 30,
                              color: theme.colorScheme.onPrimaryContainer),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text('连接服务器', style: theme.textTheme.headlineMedium),
                    const SizedBox(height: 24),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _host,
                            decoration: const InputDecoration(
                                labelText: '服务器地址', hintText: '主机名或 IP'),
                            keyboardType: TextInputType.url,
                            textInputAction: TextInputAction.next,
                            autocorrect: false,
                            validator: (value) =>
                                normalizeHost(value ?? '') == null
                                    ? '请输入有效的主机名或 IP'
                                    : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 98,
                          child: TextFormField(
                            controller: _port,
                            decoration: const InputDecoration(labelText: '端口'),
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.next,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                            validator: (value) {
                              final port = int.tryParse(value ?? '');
                              return port == null || port < 1 || port > 65535
                                  ? '1–65535'
                                  : null;
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _user,
                      decoration: const InputDecoration(labelText: '用户名'),
                      keyboardType: TextInputType.visiblePassword,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      enableSuggestions: false,
                      validator: (value) =>
                          (value ?? '').trim().isEmpty ? '请输入用户名' : null,
                    ),
                    const SizedBox(height: 20),
                    SegmentedButton<_Auth>(
                      segments: const [
                        ButtonSegment(
                            value: _Auth.password,
                            label: Text('密码'),
                            icon: Icon(Icons.password_rounded)),
                        ButtonSegment(
                            value: _Auth.key,
                            label: Text('私钥'),
                            icon: Icon(Icons.key_rounded)),
                      ],
                      selected: {_auth},
                      onSelectionChanged: _choosing
                          ? null
                          : (selected) {
                              setState(() {
                                _auth = selected.first;
                                _secret.clear();
                                _key = null;
                                _hide = true;
                              });
                            },
                    ),
                    const SizedBox(height: 14),
                    if (_auth == _Auth.key) ...[
                      OutlinedButton.icon(
                        onPressed: _choosing ? null : _pickKey,
                        icon: Icon(_key == null
                            ? Icons.file_open_outlined
                            : Icons.check_circle_outline),
                        label: Text(_key == null ? '选择私钥文件' : '已选择私钥 · 重新选择'),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: _secret,
                      decoration: InputDecoration(
                        labelText: _auth == _Auth.password ? '密码' : '私钥口令（可选）',
                        suffixIcon: IconButton(
                          tooltip: _hide ? '显示口令' : '隐藏口令',
                          onPressed: () => setState(() => _hide = !_hide),
                          icon: Icon(_hide
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                        ),
                      ),
                      obscureText: _hide,
                      autocorrect: false,
                      enableSuggestions: false,
                      onFieldSubmitted: (_) => _connect(),
                      validator: (value) =>
                          _auth == _Auth.password && (value ?? '').isEmpty
                              ? '请输入密码'
                              : null,
                    ),
                    const SizedBox(height: 22),
                    FilledButton.icon(
                      onPressed: _choosing ? null : _connect,
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52)),
                      icon: const Icon(Icons.arrow_forward_rounded),
                      label: const Text('连接'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
