import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_store.dart';
import 'core/host_trust.dart';
import 'core/sessions.dart';
import 'core/ssh_connection.dart';
import 'features/connection/connection_page.dart';
import 'features/terminal/sftp_page.dart';
import 'features/terminal/terminal_page.dart';

void main() => runApp(const PocketSshApp());

class PocketSshApp extends StatefulWidget {
  const PocketSshApp({super.key});

  @override
  State<PocketSshApp> createState() => _PocketSshAppState();
}

class _PocketSshAppState extends State<PocketSshApp> {
  final store = AppStore();
  final sessions = Sessions();

  @override
  void initState() {
    super.initState();
    sessions.addListener(syncKeepAwake);
    store.addListener(syncKeepAwake);
    unawaited(store.load());
  }

  void syncKeepAwake() {
    final active =
        store.keepAwake && sessions.items.any((session) => session.connected);
    unawaited(
      androidBridge.invokeMethod<void>('keepAwake', active).catchError((_) {}),
    );
  }

  @override
  void dispose() {
    sessions.removeListener(syncKeepAwake);
    store.removeListener(syncKeepAwake);
    for (final session in sessions.items) {
      session.stop();
    }
    sessions.dispose();
    store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) => MaterialApp(
      title: 'Pocket SSH',
      debugShowCheckedModeBanner: false,
      themeMode: switch (store.theme) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: PocketHome(store: store, sessions: sessions),
    ),
  );

  ThemeData _theme(Brightness brightness) {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xff087f68),
      brightness: brightness,
      surface: brightness == Brightness.dark
          ? const Color(0xff11171f)
          : const Color(0xfff5f7f7),
    );
    final fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: colors.outlineVariant),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerHighest.withValues(alpha: .45),
        border: fieldBorder,
        enabledBorder: fieldBorder,
        focusedBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: .6)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surface,
        elevation: 0,
        indicatorColor: colors.primaryContainer,
      ),
    );
  }
}

class PocketHome extends StatefulWidget {
  const PocketHome({super.key, required this.store, required this.sessions});

  final AppStore store;
  final Sessions sessions;

  @override
  State<PocketHome> createState() => _PocketHomeState();
}

class _PocketHomeState extends State<PocketHome> {
  int tab = 0;
  String filter = '';

  @override
  void initState() {
    super.initState();
    widget.sessions.addListener(_refresh);
    widget.store.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant PocketHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessions != widget.sessions) {
      oldWidget.sessions.removeListener(_refresh);
      widget.sessions.addListener(_refresh);
    }
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_refresh);
      widget.store.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.sessions.removeListener(_refresh);
    widget.store.removeListener(_refresh);
    super.dispose();
  }

  Future<bool> verify(SshTarget target, String type, String fingerprint) async {
    try {
      return await const HostTrust().verify(
        endpoint: target.endpoint,
        fingerprint: fingerprint,
        confirm: () async {
          if (!mounted) return false;
          return await showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (context) => AlertDialog(
                  title: const Text('核对服务器指纹'),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(target.endpoint),
                        const SizedBox(height: 8),
                        const Text('请与服务器管理员提供的指纹核对后再继续。'),
                        const SizedBox(height: 12),
                        SelectableText('$type\n$fingerprint'),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('拒绝'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('一致并信任'),
                    ),
                  ],
                ),
              ) ==
              true;
        },
      );
    } on HostKeyChanged catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('服务器指纹变化，连接已阻止：${error.received}')),
        );
      }
      return false;
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法读取服务器信任记录')));
      }
      return false;
    }
  }

  Future<void> connect(HostProfile host) async {
    try {
      final credentials = await requestCredentials(context, host, widget.store);
      if (credentials == null || !mounted) return;
      Credentials? jumpCredentials;
      if (host.jumpId case final jumpId?) {
        final jump = widget.store.hosts
            .where((item) => item.id == jumpId)
            .firstOrNull;
        if (jump == null) throw StateError('找不到跳板机');
        jumpCredentials = await requestCredentials(context, jump, widget.store);
        if (jumpCredentials == null || !mounted) return;
      }
      final session = WorkspaceSession(host, widget.store.scrollback);
      widget.sessions.add(session);
      host.lastUsed = DateTime.now();
      await widget.store.save();
      if (!mounted) {
        session.stop();
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => TerminalPage(
            session: session,
            store: widget.store,
            sessions: widget.sessions,
            verify: verify,
            directCredentials: credentials,
            directJumpCredentials: jumpCredentials,
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error is StateError ? error.message : '连接配置读取失败'),
          ),
        );
      }
    }
  }

  Future<void> edit([HostProfile? host, bool quick = false]) async {
    final result = await Navigator.of(context).push<HostProfile>(
      MaterialPageRoute<HostProfile>(
        builder: (_) =>
            ConnectionPage(initial: host, store: widget.store, quick: quick),
      ),
    );
    if (result != null && mounted) {
      if (quick) {
        await connect(result);
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('主机已保存')));
      }
    }
  }

  Future<void> removeHost(HostProfile host) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除主机'),
        content: Text('删除“${host.name}”？不会影响服务器上的文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.store.deleteHost(host);
    await const HostTrust().forget(
      SshTarget(host.host, host.port, host.username).endpoint,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: IndexedStack(
        index: tab,
        children: [
          hostsPage(),
          transfersPage(),
          SettingsPage(store: widget.store),
        ],
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (index) => setState(() => tab = index),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.dns_outlined),
          selectedIcon: Icon(Icons.dns),
          label: '主机',
        ),
        NavigationDestination(icon: Icon(Icons.swap_vert), label: '传输'),
        NavigationDestination(icon: Icon(Icons.tune), label: '设置'),
      ],
    ),
  );

  Widget hostsPage() {
    final hosts =
        widget.store.hosts
            .where(
              (host) =>
                  '${host.name} ${host.host} ${host.username} ${host.group}'
                      .toLowerCase()
                      .contains(filter.toLowerCase()),
            )
            .toList()
          ..sort(
            (a, b) => (b.lastUsed ?? DateTime(0)).compareTo(
              a.lastUsed ?? DateTime(0),
            ),
          );
    final groups =
        hosts
            .map((host) => host.group.isEmpty ? '未分组' : host.group)
            .toSet()
            .toList()
          ..sort();
    final active = widget.sessions.items;
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          floating: true,
          title: const Text(
            'Pocket SSH',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          actions: [
            IconButton(
              onPressed: () => edit(null, true),
              tooltip: '快速连接',
              icon: const Icon(Icons.bolt_outlined),
            ),
            IconButton(
              onPressed: () => edit(),
              tooltip: '添加主机',
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          sliver: SliverToBoxAdapter(
            child: TextField(
              onChanged: (value) => setState(() => filter = value),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索主机、地址或分组',
              ),
            ),
          ),
        ),
        if (active.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionTitle('活动会话'),
                  for (final session in active)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.circle,
                        size: 12,
                        color: session.connected ? Colors.green : Colors.amber,
                      ),
                      title: Text(session.profile.name),
                      subtitle: Text(session.status),
                      onTap: () => Navigator.push<void>(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => TerminalPage(
                            session: session,
                            store: widget.store,
                            sessions: widget.sessions,
                            verify: verify,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (hosts.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyState(onAdd: () => edit()),
          )
        else
          for (final group in groups) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              sliver: SliverToBoxAdapter(child: _SectionTitle(group)),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final rows = hosts
                        .where(
                          (host) =>
                              (host.group.isEmpty ? '未分组' : host.group) ==
                              group,
                        )
                        .toList();
                    final host = rows[index];
                    return Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        leading: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: Icon(
                            host.keyAuth
                                ? Icons.key_rounded
                                : Icons.dns_outlined,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        title: Text(
                          host.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          '${host.username}@${host.host}:${host.port}',
                        ),
                        onTap: () => connect(host),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'edit') edit(host);
                            if (value == 'delete') removeHost(host);
                            if (value == 'trust') forgetTrust(host);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('编辑')),
                            PopupMenuItem(
                              value: 'trust',
                              child: Text('重新核对指纹'),
                            ),
                            PopupMenuItem(value: 'delete', child: Text('删除')),
                          ],
                        ),
                      ),
                    );
                  },
                  childCount: hosts
                      .where(
                        (host) =>
                            (host.group.isEmpty ? '未分组' : host.group) == group,
                      )
                      .length,
                ),
              ),
            ),
          ],
      ],
    );
  }

  Future<void> forgetTrust(HostProfile host) async {
    final endpoint = SshTarget(host.host, host.port, host.username).endpoint;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新核对指纹'),
        content: Text('清除 $endpoint 的指纹记录，下次连接时需要重新核对。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除记录'),
          ),
        ],
      ),
    );
    if (confirmed == true) await const HostTrust().forget(endpoint);
  }

  Widget transfersPage() => CustomScrollView(
    slivers: [
      const SliverAppBar(floating: true, title: Text('SFTP 传输')),
      if (widget.sessions.items.isEmpty)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyStateMessage(
            icon: Icons.swap_vert,
            title: '还没有活动会话',
            message: '连接主机后即可通过 SFTP 管理文件。',
          ),
        )
      else
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final session = widget.sessions.items[index];
            final failed = session.transferStatus == '传输失败';
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              child: ListTile(
                leading: Icon(
                  Icons.folder_open_outlined,
                  color: failed ? Theme.of(context).colorScheme.error : null,
                ),
                title: Text(session.transferStatus ?? session.profile.name),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(session.profile.name),
                    if (session.transferStatus != null) ...[
                      const SizedBox(height: 4),
                      Text('${session.transferBytes} bytes transferred'),
                      LinearProgressIndicator(
                        value:
                            session.transferTotal == null ||
                                session.transferTotal == 0
                            ? null
                            : (session.transferBytes / session.transferTotal!)
                                  .clamp(0, 1),
                      ),
                    ],
                  ],
                ),
                trailing: session.transferStatus != null
                    ? Wrap(
                        children: [
                          IconButton(
                            tooltip: '取消',
                            onPressed: session.cancelTransfer,
                            icon: const Icon(Icons.close),
                          ),
                          IconButton(
                            tooltip: '重试',
                            onPressed: session.retryTransfer,
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      )
                    : const Icon(Icons.chevron_right),
                onTap: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        SftpPage(session: session, store: widget.store),
                  ),
                ),
              ),
            );
          }, childCount: widget.sessions.items.length),
        ),
    ],
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.store});
  final AppStore store;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final endpoint = TextEditingController(text: widget.store.aiEndpoint);
  late final model = TextEditingController(text: widget.store.aiModel);
  final apiKey = TextEditingController();
  bool hidden = true;
  @override
  void dispose() {
    endpoint.dispose();
    model.dispose();
    apiKey.dispose();
    super.dispose();
  }

  Future<void> saveAi() async {
    final uri = Uri.tryParse(endpoint.text.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        model.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入有效的 HTTPS 服务地址和模型')));
      return;
    }
    if (widget.store.aiEndpoint != uri.toString()) {
      await widget.store.putSecret('ai:${widget.store.aiEndpoint}', null);
    }
    widget.store.aiEndpoint = uri.toString();
    widget.store.aiModel = model.text.trim();
    if (apiKey.text.isNotEmpty) {
      await widget.store.putSecret('ai:$uri', apiKey.text);
      apiKey.clear();
    }
    await widget.store.save();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('AI 设置已加密保存')));
    }
  }

  Future<void> setDeviceLock(bool value) async {
    try {
      final authenticated =
          await androidBridge.invokeMethod<bool>('authenticate') == true;
      if (!authenticated) return;
      widget.store.deviceLock = value;
      await widget.store.save();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先设置设备锁屏认证')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      const SliverAppBar(floating: true, title: Text('设置')),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        sliver: SliverList(
          delegate: SliverChildListDelegate([
            Card(
              child: Column(
                children: [
                  const ListTile(title: Text('外观'), subtitle: Text('选择应用主题')),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'system', label: Text('系统')),
                        ButtonSegment(value: 'light', label: Text('浅色')),
                        ButtonSegment(value: 'dark', label: Text('深色')),
                      ],
                      selected: {widget.store.theme},
                      onSelectionChanged: (value) async {
                        widget.store.theme = value.first;
                        await widget.store.save();
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('终端字体大小'),
                        Slider(
                          value: widget.store.fontSize,
                          min: 11,
                          max: 24,
                          divisions: 13,
                          label: '${widget.store.fontSize.round()} px',
                          onChanged: (value) =>
                              setState(() => widget.store.fontSize = value),
                          onChangeEnd: (value) {
                            widget.store.fontSize = value;
                            widget.store.save();
                          },
                        ),
                        const Text('终端主题'),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'dark', label: Text('深色')),
                            ButtonSegment(value: 'light', label: Text('浅色')),
                          ],
                          selected: {widget.store.terminalTheme},
                          onSelectionChanged: (value) async {
                            widget.store.terminalTheme = value.first;
                            await widget.store.save();
                          },
                        ),
                      ],
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('记录最近发送的命令'),
                    subtitle: const Text('只记录由终端草稿发送的命令，不保存完整终端输出。'),
                    value: widget.store.recentCommandHistory,
                    onChanged: (value) async {
                      widget.store.recentCommandHistory = value;
                      if (!value) widget.store.recentCommands.clear();
                      await widget.store.save();
                      if (mounted) setState(() {});
                    },
                  ),
                  SwitchListTile(
                    title: const Text('连接时保持屏幕常亮'),
                    value: widget.store.keepAwake,
                    onChanged: (value) async {
                      widget.store.keepAwake = value;
                      await androidBridge.invokeMethod<void>(
                        'keepAwake',
                        value,
                      );
                      await widget.store.save();
                    },
                  ),
                  SwitchListTile(
                    title: const Text('读取已保存凭据前进行设备认证'),
                    subtitle: const Text('使用锁屏 PIN、图案或生物认证'),
                    value: widget.store.deviceLock,
                    onChanged: setDeviceLock,
                  ),
                ],
              ),
            ),
            const _SectionTitle('AI 助手'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    TextField(
                      controller: endpoint,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'OpenAI 兼容 HTTPS 接口',
                        hintText: 'https://api.example.com/v1/chat/completions',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: model,
                      decoration: const InputDecoration(labelText: '模型名称'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: apiKey,
                      obscureText: hidden,
                      decoration: InputDecoration(
                        labelText: 'API 密钥（留空保留现有密钥）',
                        suffixIcon: IconButton(
                          onPressed: () => setState(() => hidden = !hidden),
                          icon: Icon(
                            hidden ? Icons.visibility : Icons.visibility_off,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('只有确认发送后才会向模型发送你核对过的上下文；建议命令仅作为草稿，不会自动执行。'),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: saveAi,
                        child: const Text('加密保存 AI 设置'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const _SectionTitle('关于'),
            const Card(
              child: ListTile(
                leading: Icon(Icons.terminal),
                title: Text('Pocket SSH'),
                subtitle: Text('AI 建议由用户检查并确认后发送。'),
              ),
            ),
          ]),
        ),
      ),
    ],
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.dns_outlined, size: 48),
          const SizedBox(height: 16),
          Text('添加第一台服务器', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('保存连接配置，随时开始 SSH 会话。', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('添加主机'),
          ),
        ],
      ),
    ),
  );
}

class _EmptyStateMessage extends StatelessWidget {
  const _EmptyStateMessage({
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
