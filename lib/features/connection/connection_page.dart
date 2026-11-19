import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/app_store.dart';
import '../../core/host_trust.dart';
import '../../core/ssh_connection.dart';

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({
    super.key,
    this.initial,
    this.store,
    this.quick = false,
  });
  final HostProfile? initial;
  final AppStore? store;
  final bool quick;
  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  final form = GlobalKey<FormState>();
  late final initial = widget.initial;
  late final name = TextEditingController(text: initial?.name);
  late final host = TextEditingController(text: initial?.host);
  late final port = TextEditingController(text: '${initial?.port ?? 22}');
  late final user = TextEditingController(text: initial?.username);
  late final group = TextEditingController(text: initial?.group);
  late final localPort = TextEditingController(
    text: initial?.localForwardPort?.toString() ?? '',
  );
  late final forwardHost = TextEditingController(
    text: initial?.forwardTargetHost ?? '127.0.0.1',
  );
  late final forwardPort = TextEditingController(
    text: '${initial?.forwardTargetPort ?? 5432}',
  );
  late bool keyAuth = initial?.keyAuth ?? false;
  late bool remember = initial?.remember ?? false;
  late String? jumpId = initial?.jumpId;
  bool saving = false;

  Future<void> save() async {
    if (saving || !form.currentState!.validate()) return;
    final profile = HostProfile(
      id: initial?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.text.trim().isEmpty ? host.text.trim() : name.text.trim(),
      host: normalizeHost(host.text)!,
      port: int.parse(port.text),
      username: user.text.trim(),
      group: group.text.trim(),
      localForwardPort: int.tryParse(localPort.text.trim()),
      forwardTargetHost: forwardHost.text.trim().isEmpty
          ? '127.0.0.1'
          : forwardHost.text.trim(),
      forwardTargetPort: int.tryParse(forwardPort.text.trim()) ?? 5432,
      keyAuth: keyAuth,
      remember: remember,
      jumpId: jumpId,
      lastUsed: initial?.lastUsed,
    );
    if (widget.quick) {
      if (mounted) Navigator.pop(context, profile);
      return;
    }
    final store = widget.store;
    setState(() => saving = true);
    try {
      if (!widget.quick && store != null) {
        if (initial != null &&
            (!remember ||
                initial!.keyAuth != keyAuth ||
                initial!.host != profile.host ||
                initial!.port != profile.port ||
                initial!.username != profile.username)) {
          await store.putSecret('host:${profile.id}', null);
        }
        final index = store.hosts.indexWhere((x) => x.id == profile.id);
        if (index < 0) {
          store.hosts.add(profile);
        } else {
          store.hosts[index] = profile;
        }
        await store.save();
      }
      if (mounted) Navigator.pop(context, profile);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法保存主机配置')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void dispose() {
    for (final c in [
      name,
      host,
      port,
      user,
      group,
      localPort,
      forwardHost,
      forwardPort,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.quick
            ? '快速连接'
            : initial == null
            ? '添加主机'
            : '编辑主机',
      ),
    ),
    body: SafeArea(
      child: Form(
        key: form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (!widget.quick) ...[
              TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: host,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '服务器地址'),
              validator: (v) =>
                  normalizeHost(v ?? '') == null ? '请输入有效的主机名或 IP' : null,
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: user,
                    decoration: const InputDecoration(labelText: '用户名'),
                    validator: (v) =>
                        (v ?? '').trim().isEmpty ? '请输入用户名' : null,
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 100,
                  child: TextFormField(
                    controller: port,
                    decoration: const InputDecoration(labelText: '端口'),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null || n < 1 || n > 65535 ? '1–65535' : null;
                    },
                  ),
                ),
              ],
            ),
            if (!widget.quick) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: group,
                decoration: const InputDecoration(labelText: '分组'),
              ),
            ],
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('密码'),
                  icon: Icon(Icons.password),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('私钥'),
                  icon: Icon(Icons.key),
                ),
              ],
              selected: {keyAuth},
              onSelectionChanged: (v) => setState(() => keyAuth = v.first),
            ),
            if (!widget.quick)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('加密保存凭据'),
                value: remember,
                onChanged: (v) => setState(() => remember = v),
              ),
            if (widget.store case final store?)
              ExpansionTile(
                title: const Text('高级连接'),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextFormField(
                      controller: localPort,
                      onChanged: (_) => setState(() {}),
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '本地转发端口（可选）',
                      ),
                      validator: (value) {
                        if ((value ?? '').trim().isEmpty) return null;
                        final number = int.tryParse(value!.trim());
                        return number == null || number < 1 || number > 65535
                            ? '端口需在 1–65535 之间'
                            : null;
                      },
                    ),
                  ),
                  if ((localPort.text.trim().isNotEmpty ||
                      initial?.localForwardPort != null)) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextFormField(
                        controller: forwardHost,
                        decoration: const InputDecoration(labelText: '转发目标主机'),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextFormField(
                        controller: forwardPort,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '转发目标端口'),
                        validator: (value) {
                          final number = int.tryParse(value ?? '');
                          return number == null || number < 1 || number > 65535
                              ? '端口需在 1–65535 之间'
                              : null;
                        },
                      ),
                    ),
                  ],
                  DropdownButtonFormField<String>(
                    initialValue:
                        store.hosts.any(
                          (h) =>
                              h.id == jumpId &&
                              h.id != initial?.id &&
                              h.jumpId == null,
                        )
                        ? jumpId
                        : '',
                    decoration: const InputDecoration(labelText: '跳板机'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('直连')),
                      for (final h in store.hosts.where(
                        (h) => h.id != initial?.id && h.jumpId == null,
                      ))
                        DropdownMenuItem(
                          value: h.id,
                          child: Text(h.name, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) =>
                        setState(() => jumpId = v == '' ? null : v),
                  ),
                ],
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: saving ? null : save,
              icon: Icon(widget.quick ? Icons.terminal : Icons.check),
              label: Text(widget.quick ? '连接' : '保存主机'),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<Credentials?> requestCredentials(
  BuildContext context,
  HostProfile host,
  AppStore store, {
  bool forcePrompt = false,
}) async {
  final saved = forcePrompt ? null : await store.credentials(host);
  if (forcePrompt && host.remember && !await store.unlock()) return null;
  if (saved != null || !context.mounted) return saved;
  final secret = TextEditingController();
  String key = '';
  bool busy = false;
  final canRemember = store.hosts.any((item) => item.id == host.id);
  var remember = host.remember;
  String? error;
  final route = DialogRoute<Credentials>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(host.name),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${host.username}@${host.host}:${host.port}'),
              const SizedBox(height: 12),
              if (host.keyAuth)
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() => busy = true);
                          try {
                            final bytes = await androidBridge
                                .invokeMethod<Uint8List>('pickKey');
                            if (bytes != null) {
                              try {
                                key = utf8.decode(bytes);
                              } finally {
                                bytes.fillRange(0, bytes.length, 0);
                              }
                            }
                          } catch (_) {
                            error = '无法读取私钥';
                          }
                          if (context.mounted) setState(() => busy = false);
                        },
                  icon: Icon(key.isEmpty ? Icons.file_open : Icons.check),
                  label: Text(key.isEmpty ? '选择私钥文件' : '已选择私钥'),
                ),
              TextField(
                controller: secret,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: host.keyAuth ? '私钥口令（可选）' : '密码',
                  errorText: error,
                ),
              ),
              if (canRemember)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(host.keyAuth ? '加密记住私钥和口令' : '加密记住密码'),
                  value: remember,
                  onChanged: (value) =>
                      setState(() => remember = value == true),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () {
                    if (host.keyAuth ? key.isEmpty : secret.text.isEmpty) {
                      setState(() => error = host.keyAuth ? '请选择私钥' : '请输入密码');
                      return;
                    }
                    Navigator.pop(
                      dialog,
                      host.keyAuth
                          ? Credentials(
                              key: key,
                              passphrase: secret.text,
                              remember: canRemember ? remember : null,
                            )
                          : Credentials(
                              password: secret.text,
                              remember: canRemember ? remember : null,
                            ),
                    );
                  },
            child: const Text('连接'),
          ),
        ],
      ),
    ),
  );
  final result = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  secret.dispose();
  return result;
}
