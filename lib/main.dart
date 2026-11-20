import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/ai_endpoint.dart';
import 'core/app_palette.dart';
import 'core/ai_headers.dart';
import 'core/agent_context.dart';
import 'core/app_store.dart';
import 'core/host_trust.dart';
import 'core/host_backup.dart';
import 'core/device_bridge.dart';
import 'core/sessions.dart';
import 'core/ssh_connection.dart';
import 'features/connection/connection_page.dart';
import 'features/terminal/sftp_page.dart';
import 'features/terminal/terminal_page.dart';
import 'features/settings/glass_surface.dart';

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
      deviceBridge.invokeMethod<void>('keepAwake', active).catchError((_) {}),
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
    final dark = brightness == Brightness.dark;
    final colors = AppPalette.scheme(brightness);
    final fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: colors.outlineVariant),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface.withValues(
          alpha: store.glassStyle == 'solid' ? 1 : .94,
        ),
        surfaceTintColor: Colors.transparent,
        foregroundColor: colors.onSurface,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerHighest.withValues(
          alpha: dark ? .48 : .62,
        ),
        border: fieldBorder,
        enabledBorder: fieldBorder,
        focusedBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
        labelStyle: TextStyle(color: colors.onSurfaceVariant),
        hintStyle: TextStyle(
          color: colors.onSurfaceVariant.withValues(alpha: .8),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: .75)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surface,
        elevation: 0,
        indicatorColor: colors.primaryContainer,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(color: colors.onSurfaceVariant),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.inverseSurface,
        contentTextStyle: TextStyle(color: colors.onInverseSurface),
        behavior: SnackBarBehavior.floating,
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

  bool connecting = false;

  Future<void> connect(
    HostProfile host, {
    bool sftp = false,
    bool replaceCredentials = false,
  }) async {
    if (connecting) return;
    setState(() => connecting = true);
    try {
      if (sftp) {
        final active = widget.sessions.items
            .where((item) => item.profile.id == host.id && item.connected)
            .firstOrNull;
        if (active != null) {
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => SftpPage(session: active, store: widget.store),
            ),
          );
          return;
        }
      }
      final credentials = await requestCredentials(
        context,
        host,
        widget.store,
        forcePrompt: replaceCredentials,
      );
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
      if (sftp) {
        try {
          final jump = widget.store.hosts
              .where((item) => item.id == host.jumpId)
              .firstOrNull;
          await session.open(
            credentials,
            verify,
            jump: jump,
            jumpCredentials: jumpCredentials,
            fileOnly: true,
            onAuthenticated: () =>
                widget.store.rememberCredentials(host, credentials),
            onJumpAuthenticated: jump == null
                ? null
                : () =>
                      widget.store.rememberCredentials(jump, jumpCredentials!),
          );
          if (!mounted) return;
          if (!session.connected) throw StateError(session.status);
          host.lastUsed = DateTime.now();
          await widget.store.save();
          if (!mounted) return;
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => SftpPage(session: session, store: widget.store),
            ),
          );
        } finally {
          session.stop();
        }
        return;
      }
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
    } finally {
      if (mounted) setState(() => connecting = false);
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

  void openSettings() {
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          store: widget.store,
          onImportHosts: () => transferProfiles('import'),
          onExportHosts: () => transferProfiles('export'),
        ),
      ),
    );
  }

  void openSession(WorkspaceSession session) {
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => TerminalPage(
          session: session,
          store: widget.store,
          sessions: widget.sessions,
          verify: verify,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final page = IndexedStack(
      index: tab,
      children: [hostsPage(), sessionsPage(), transfersPage()],
    );
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(child: GlassBackdrop(store: widget.store)),
          SafeArea(
            child: wide
                ? Row(
                    children: [
                      NavigationRail(
                        backgroundColor: Theme.of(context).colorScheme.surface
                            .withValues(
                              alpha: widget.store.glassStyle == 'solid'
                                  ? 1
                                  : widget.store.glassOpacity.clamp(.35, .9),
                            ),
                        extended: true,
                        selectedIndex: tab,
                        onDestinationSelected: (index) =>
                            setState(() => tab = index),
                        destinations: const [
                          NavigationRailDestination(
                            icon: Icon(Icons.dns_outlined),
                            label: Text('主机'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.terminal),
                            label: Text('会话'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.folder_open_outlined),
                            label: Text('文件'),
                          ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: page),
                    ],
                  )
                : page,
          ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: widget.store.glassStyle == 'solid' ? 0 : 22,
                  sigmaY: widget.store.glassStyle == 'solid' ? 0 : 22,
                ),
                child: NavigationBar(
                  backgroundColor: Theme.of(context).colorScheme.surface
                      .withValues(
                        alpha: widget.store.glassStyle == 'solid'
                            ? 1
                            : widget.store.glassOpacity.clamp(.35, .9),
                      ),
                  selectedIndex: tab,
                  onDestinationSelected: (index) => setState(() => tab = index),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.dns_outlined),
                      selectedIcon: Icon(Icons.dns),
                      label: '主机',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.terminal),
                      label: '会话',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.folder_open_outlined),
                      label: '文件',
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Future<void> transferProfiles(String action) async {
    try {
      if (action == 'export') {
        await Clipboard.setData(
          ClipboardData(text: exportHosts(widget.store.hosts)),
        );
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('主机配置已复制，不含凭据和指纹')));
        }
        return;
      }
      final input = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (!mounted || input == null) return;
      final profiles = importHosts(input);
      if (profiles.isEmpty) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导入主机配置'),
          content: Text('从剪贴板添加 ${profiles.length} 个主机，不覆盖已有配置。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('导入'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      widget.store.hosts.addAll(profiles);
      try {
        await widget.store.save();
      } catch (_) {
        widget.store.hosts.removeWhere(profiles.contains);
        rethrow;
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法处理主机配置，请检查剪贴板或存储权限')));
      }
    }
  }

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
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          floating: true,
          title: const Text(
            'Pocket SSH',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -.3),
          ),
          actions: [
            IconButton(
              onPressed: openSettings,
              tooltip: '设置',
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          sliver: SliverToBoxAdapter(
            child: _WorkspaceHero(
              hostCount: widget.store.hosts.length,
              sessionCount: widget.sessions.items
                  .where((session) => session.connected)
                  .length,
              onQuickConnect: () => edit(null, true),
              onAddHost: () => edit(),
            ),
          ),
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
        if (hosts.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyStateMessage(
              icon: filter.isEmpty ? Icons.dns_outlined : Icons.search_off,
              title: filter.isEmpty ? '还没有保存主机' : '没有找到匹配主机',
              message: filter.isEmpty
                  ? '使用上方的快速连接，或添加一台服务器开始工作。'
                  : '试试更短的名称、地址或分组关键字。',
            ),
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
                    final activeSession = widget.sessions.items
                        .where((session) => session.profile.id == host.id)
                        .firstOrNull;
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      clipBehavior: Clip.antiAlias,
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
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                host.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (activeSession != null) ...[
                              const SizedBox(width: 8),
                              _StatusBadge(
                                label: activeSession.connected ? '在线' : '连接中',
                                active: activeSession.connected,
                              ),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          '${host.username}@${host.host}:${host.port}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => connect(host),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton.filledTonal(
                              tooltip: '连接 ${host.name}',
                              onPressed: connecting
                                  ? null
                                  : () => connect(host),
                              icon: const Icon(Icons.terminal),
                            ),
                            PopupMenuButton<String>(
                              onSelected: (value) {
                                if (value == 'edit') edit(host);
                                if (value == 'sftp') connect(host, sftp: true);
                                if (value == 'credentials') {
                                  connect(host, replaceCredentials: true);
                                }
                                if (value == 'delete') removeHost(host);
                                if (value == 'trust') forgetTrust(host);
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 'edit', child: Text('编辑')),
                                PopupMenuItem(
                                  value: 'sftp',
                                  child: Text('打开 SFTP'),
                                ),
                                PopupMenuItem(
                                  value: 'credentials',
                                  child: Text('更换登录凭据'),
                                ),
                                PopupMenuItem(
                                  value: 'trust',
                                  child: Text('重新核对指纹'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('删除'),
                                ),
                              ],
                            ),
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

  Widget sessionsPage() => CustomScrollView(
    slivers: [
      SliverAppBar(
        floating: true,
        title: const Text('Pocket SSH'),
        actions: [
          IconButton(
            tooltip: '设置',
            onPressed: openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
        sliver: SliverToBoxAdapter(
          child: _PageIntro(
            eyebrow: 'LIVE CONNECTIONS',
            title: '会话',
            subtitle: '管理正在运行的 SSH 终端。',
            trailing:
                '${widget.sessions.items.where((s) => s.connected).length} 在线',
          ),
        ),
      ),
      if (widget.sessions.items.isEmpty)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyStateMessage(
            icon: Icons.terminal,
            title: '还没有活动会话',
            message: '从主机页连接服务器后，会话会显示在这里。',
          ),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final session = widget.sessions.items[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  leading: Icon(
                    Icons.circle,
                    size: 12,
                    color: session.connected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.error,
                  ),
                  title: Text(session.profile.name),
                  subtitle: Text(session.status),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => openSession(session),
                ),
              );
            }, childCount: widget.sessions.items.length),
          ),
        ),
    ],
  );

  Widget transfersPage() => CustomScrollView(
    slivers: [
      SliverAppBar(
        floating: true,
        title: const Text('Pocket SSH'),
        actions: [
          IconButton(
            tooltip: '设置',
            onPressed: openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
        sliver: SliverToBoxAdapter(
          child: _PageIntro(
            eyebrow: 'SFTP WORKSPACE',
            title: '文件',
            subtitle: '选择主机，浏览和传输远程文件。',
            trailing: '${widget.store.hosts.length} 主机',
          ),
        ),
      ),
      if (connecting)
        const SliverToBoxAdapter(child: LinearProgressIndicator()),
      for (final host in widget.store.hosts)
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
          sliver: SliverToBoxAdapter(
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: Text(host.name),
                subtitle: Text(
                  SshTarget(host.host, host.port, host.username).label,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: connecting ? null : () => connect(host, sftp: true),
              ),
            ),
          ),
        ),
      if (widget.sessions.items.isEmpty && widget.store.hosts.isEmpty)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyStateMessage(
            icon: Icons.folder_open_outlined,
            title: '还没有文件会话',
            message: '添加主机后，从上方列表打开 SFTP。',
          ),
        )
      else
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final session = widget.sessions.items[index];
            final failed = session.transferStatus == '传输失败';
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              clipBehavior: Clip.antiAlias,
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

class _AiHeaderRow {
  _AiHeaderRow([String headerName = '', String headerValue = ''])
    : name = TextEditingController(text: headerName),
      value = TextEditingController(text: headerValue);
  final TextEditingController name, value;
  void dispose() {
    name.dispose();
    value.dispose();
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.store,
    this.section = 'home',
    this.onImportHosts,
    this.onExportHosts,
  });
  final AppStore store;
  final String section;
  final VoidCallback? onImportHosts;
  final VoidCallback? onExportHosts;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final channelName = TextEditingController(
    text: widget.store.aiChannelName,
  );
  late final endpoint = TextEditingController(
    text:
        aiBaseUrl(widget.store.aiEndpoint)?.toString() ??
        widget.store.aiEndpoint,
  );
  late AiApi selectedApi = widget.store.aiApi;
  late final contextWindow = TextEditingController(
    text: '${widget.store.aiContextTokens}',
  );
  late final maxOutput = TextEditingController(
    text: '${widget.store.aiMaxOutputTokens}',
  );
  late final compression = TextEditingController(
    text: '${(widget.store.aiCompressionThreshold * 100).round()}',
  );
  late final model = TextEditingController(text: widget.store.aiModel);
  final apiKey = TextEditingController();
  bool hidden = true;
  bool aiBusy = false;
  String? aiStatus;
  bool removeAiKey = false;
  List<String> models = [];
  final headerRows = <_AiHeaderRow>[];
  bool headersLoaded = false, headersEdited = false, headersHidden = true;

  Map<String, String> _editedHeaders() {
    final values = <String, String>{};
    final names = <String>{};
    for (final row in headerRows) {
      final name = row.name.text.trim();
      if (!names.add(name.toLowerCase())) {
        throw const FormatException('请求头名称不能重复（不区分大小写）');
      }
      values[name] = row.value.text;
    }
    return validateAiHeaders(values);
  }

  void _resetHeaders() {
    for (final row in headerRows) {
      row.dispose();
    }
    headerRows.clear();
    headersLoaded = false;
    headersEdited = false;
    headersHidden = true;
  }

  Future<void> _loadHeaders() async {
    if (aiBusy) return;
    if (aiBaseUrl(endpoint.text) == null) {
      setState(() => aiStatus = '请先填写有效的 AI 网站地址');
      return;
    }
    setState(() {
      aiBusy = true;
      aiStatus = null;
    });
    try {
      if (!await widget.store.unlock() || !mounted) return;
      final headers = await widget.store.aiHeaders(endpoint.text);
      if (!mounted) return;
      setState(() {
        _resetHeaders();
        headerRows.addAll(
          headers.entries.map((entry) => _AiHeaderRow(entry.key, entry.value)),
        );
        headersLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => aiStatus = '无法读取已保存请求头，请检查设备认证和存储');
    } finally {
      if (mounted) setState(() => aiBusy = false);
    }
  }

  Future<Map<String, String>> _requestHeaders() async {
    if (headersEdited) return _editedHeaders();
    return widget.store.aiHeaders(endpoint.text);
  }

  Future<void> checkAi({required bool listModels}) async {
    final uri = aiEndpoint(endpoint.text, selectedApi);
    final selectedModel = model.text.trim();
    if (uri == null || (!listModels && selectedModel.isEmpty)) {
      setState(
        () => aiStatus = '请填写有效的 HTTP/HTTPS 网站地址${listModels ? '' : '和模型名称'}',
      );
      return;
    }
    setState(() {
      aiBusy = true;
      aiStatus = null;
    });
    try {
      if (!await widget.store.unlock() || !mounted) return;
      final headers = await _requestHeaders();
      if (!mounted) return;
      String? key = apiKey.text.trim();
      if (key.isEmpty &&
          !removeAiKey &&
          aiBaseUrl(widget.store.aiEndpoint) == aiBaseUrl(endpoint.text)) {
        key = await widget.store.aiSecret(endpoint.text);
      }
      final result = await checkAiEndpoint(
        uri,
        key,
        model: listModels ? null : selectedModel,
        api: selectedApi,
        customHeaders: headers,
      );
      if (!mounted) return;
      setState(() {
        if (listModels) models = result;
        aiStatus = listModels
            ? (result.isEmpty ? '服务未列出模型，可手动填写' : '已获取 ${result.length} 个模型')
            : '模型已返回流式回复';
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => aiStatus = error is HttpException
              ? error.message
              : '请求失败，请检查地址、密钥和模型',
        );
      }
    } finally {
      if (mounted) setState(() => aiBusy = false);
    }
  }

  @override
  void dispose() {
    endpoint.dispose();
    channelName.dispose();
    model.dispose();
    apiKey.dispose();
    contextWindow.dispose();
    maxOutput.dispose();
    compression.dispose();
    for (final row in headerRows) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> saveAi() async {
    final uri = aiEndpoint(endpoint.text, selectedApi);
    if (uri == null || model.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入有效的 HTTP/HTTPS 网站地址和模型')),
      );
      return;
    }
    late final AgentBudget limits;
    Map<String, String>? editedHeaders;
    try {
      if (headersEdited) editedHeaders = _editedHeaders();
      limits = AgentBudget(
        contextTokens: int.tryParse(contextWindow.text) ?? 0,
        maxOutputTokens: int.tryParse(maxOutput.text) ?? 0,
        compressionThreshold: (double.tryParse(compression.text) ?? 0) / 100,
      );
    } on FormatException catch (error) {
      setState(() => aiStatus = error.message);
      return;
    }
    final base = aiBaseUrl(endpoint.text)!;
    final previousChannelName = widget.store.aiChannelName;
    final previousEndpoint = widget.store.aiEndpoint;
    final previousModel = widget.store.aiModel;
    final previousApi = widget.store.aiApi;
    final previousBudget = widget.store.aiBudget;
    Map<String, String>? previousHeaders;
    setState(() {
      aiBusy = true;
      aiStatus = null;
    });
    try {
      if ((editedHeaders != null || removeAiKey) &&
          (!await widget.store.unlock() || !mounted)) {
        return;
      }
      if (removeAiKey) {
        for (final address in {
          base.toString(),
          aiEndpoint(base.toString(), AiApi.chat).toString(),
          aiEndpoint(base.toString(), AiApi.responses).toString(),
          widget.store.aiEndpoint,
        }) {
          if (aiBaseUrl(address) == base) {
            await widget.store.putSecret('ai:$address', null);
          }
        }
      } else if (apiKey.text.trim().isNotEmpty) {
        await widget.store.putSecret('ai:$base', apiKey.text.trim());
      }
      if (editedHeaders != null) {
        previousHeaders = await widget.store.aiHeaders(base.toString());
        await widget.store.putAiHeaders(base.toString(), editedHeaders);
      }
      widget.store.aiChannelName = channelName.text.trim();
      widget.store.aiEndpoint = base.toString();
      widget.store.aiModel = model.text.trim();
      widget.store.aiApi = selectedApi;
      widget.store.aiContextTokens = limits.contextTokens;
      widget.store.aiMaxOutputTokens = limits.maxOutputTokens;
      widget.store.aiCompressionThreshold = limits.compressionThreshold;
      try {
        await widget.store.save();
      } catch (_) {
        widget.store.aiChannelName = previousChannelName;
        widget.store.aiEndpoint = previousEndpoint;
        widget.store.aiModel = previousModel;
        widget.store.aiApi = previousApi;
        widget.store.aiContextTokens = previousBudget.contextTokens;
        widget.store.aiMaxOutputTokens = previousBudget.maxOutputTokens;
        widget.store.aiCompressionThreshold =
            previousBudget.compressionThreshold;
        if (previousHeaders != null) {
          await widget.store.putAiHeaders(base.toString(), previousHeaders);
        }
        rethrow;
      }
      if (mounted) {
        endpoint.text = base.toString();
        channelName.text = widget.store.aiChannelName;
        apiKey.clear();
        setState(() {
          removeAiKey = false;
          headersEdited = false;
          aiStatus = 'AI 设置已保存';
        });
      }
    } catch (_) {
      if (mounted) setState(() => aiStatus = '无法保存 AI 设置，请重试');
    } finally {
      if (mounted) setState(() => aiBusy = false);
    }
  }

  Future<void> setDeviceLock(bool value) async {
    try {
      final authenticated =
          await deviceBridge.invokeMethod<bool>('authenticate') == true;
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

  void openSection(String section) {
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          store: widget.store,
          section: section,
          onImportHosts: widget.onImportHosts,
          onExportHosts: widget.onExportHosts,
        ),
      ),
    );
  }

  Widget _settingsFrame(String title, List<Widget> children) => Scaffold(
    backgroundColor: Theme.of(context).colorScheme.surface,
    appBar: AppBar(
      title: Text(title),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
    ),
    body: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: children,
          ),
        ),
      ),
    ),
  );

  Widget _settingsHome() => Scaffold(
    backgroundColor: Theme.of(context).colorScheme.surface,
    appBar: AppBar(
      title: const Text('设置'),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
    ),
    body: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _SettingsGroupTitle('工作区'),
              _SettingsEntry(
                store: widget.store,
                icon: Icons.palette_outlined,
                title: '外观',
                subtitle: '主题、液态玻璃与透明度',
                onTap: () => openSection('appearance'),
              ),
              _SettingsEntry(
                store: widget.store,
                icon: Icons.terminal,
                title: '终端',
                subtitle: '字体、配色、命令历史与屏幕常亮',
                onTap: () => openSection('terminal'),
              ),
              const SizedBox(height: 18),
              _SettingsGroupTitle('AI 与连接'),
              _SettingsEntry(
                store: widget.store,
                icon: Icons.auto_awesome_outlined,
                title: 'AI 助手',
                subtitle: widget.store.aiEndpoint.isEmpty
                    ? '配置模型与接口'
                    : '${widget.store.aiChannelLabel} · ${widget.store.aiModel}',
                onTap: () => openSection('ai'),
              ),
              _SettingsEntry(
                store: widget.store,
                icon: Icons.shield_outlined,
                title: '安全与隐私',
                subtitle: '凭据保存与设备认证',
                onTap: () => openSection('security'),
              ),
              const SizedBox(height: 18),
              _SettingsGroupTitle('应用'),
              _SettingsEntry(
                store: widget.store,
                icon: Icons.import_export,
                title: '配置备份',
                subtitle: '导入或导出主机配置',
                onTap: () => openSection('backup'),
              ),
              _SettingsEntry(
                store: widget.store,
                icon: Icons.info_outline,
                title: '关于',
                subtitle: '应用信息与功能说明',
                onTap: () => openSection('about'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _appearanceSettings() => _settingsFrame('外观', [
    const _SectionTitle('应用主题'),
    _SettingsPanel(
      store: widget.store,
      padding: const EdgeInsets.all(16),
      child: SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'system', label: Text('系统')),
          ButtonSegment(value: 'light', label: Text('浅色')),
          ButtonSegment(value: 'dark', label: Text('深色')),
        ],
        selected: {widget.store.theme},
        onSelectionChanged: (value) async {
          setState(() => widget.store.theme = value.first);
          await widget.store.save();
        },
      ),
    ),
    const _SectionTitle('玻璃材质'),
    GlassSurface(
      store: widget.store,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'liquid',
                icon: Icon(Icons.water_drop_outlined),
                label: Text('液态'),
              ),
              ButtonSegment(
                value: 'frosted',
                icon: Icon(Icons.blur_on_outlined),
                label: Text('毛玻璃'),
              ),
              ButtonSegment(
                value: 'solid',
                icon: Icon(Icons.crop_square),
                label: Text('不透明'),
              ),
            ],
            selected: {widget.store.glassStyle},
            onSelectionChanged: (value) async {
              setState(() => widget.store.glassStyle = value.first);
              await widget.store.save();
            },
          ),
          if (widget.store.glassStyle != 'solid') ...[
            const SizedBox(height: 12),
            Text('透明度 ${(widget.store.glassOpacity * 100).round()}%'),
            Slider(
              value: widget.store.glassOpacity.clamp(.35, .9),
              min: .35,
              max: .9,
              divisions: 11,
              onChanged: (value) =>
                  setState(() => widget.store.glassOpacity = value),
              onChangeEnd: (_) => widget.store.save(),
            ),
          ],
          const Text('液态与毛玻璃仅用于导航、卡片和浮层；终端内容保持清晰高对比。'),
        ],
      ),
    ),
  ]);

  Widget _terminalSettings() => _settingsFrame('终端', [
    const _SectionTitle('显示'),
    _SettingsPanel(
      store: widget.store,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('字体大小 · ${widget.store.fontSize.round()} px'),
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
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'dark', label: Text('深色终端')),
                ButtonSegment(value: 'light', label: Text('浅色终端')),
              ],
              selected: {widget.store.terminalTheme},
              onSelectionChanged: (value) async {
                setState(() => widget.store.terminalTheme = value.first);
                await widget.store.save();
              },
            ),
          ],
        ),
      ),
    ),
    const _SectionTitle('操作'),
    _SettingsPanel(
      store: widget.store,
      child: Column(
        children: [
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
              await deviceBridge.invokeMethod<void>('keepAwake', value);
              await widget.store.save();
            },
          ),
        ],
      ),
    ),
  ]);

  Widget _securitySettings() => _settingsFrame('安全与隐私', [
    const _SectionTitle('设备安全'),
    _SettingsPanel(
      store: widget.store,
      child: SwitchListTile(
        title: const Text('读取已保存凭据前进行设备认证'),
        subtitle: const Text('使用锁屏 PIN、图案或生物认证'),
        value: widget.store.deviceLock,
        onChanged: setDeviceLock,
      ),
    ),
    const Padding(
      padding: EdgeInsets.all(8),
      child: Text('SSH 凭据和主机指纹使用设备安全存储；连接前会核对服务器指纹。'),
    ),
  ]);

  Widget _backupSettings() => _settingsFrame('配置备份', [
    const _SectionTitle('主机配置'),
    _SettingsPanel(
      store: widget.store,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.content_copy),
            title: const Text('复制主机配置 JSON'),
            subtitle: const Text('导出内容不包含登录凭据和主机指纹。'),
            onTap: widget.onExportHosts,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.content_paste),
            title: const Text('从剪贴板导入配置'),
            subtitle: const Text('导入后不会覆盖已有主机。'),
            onTap: widget.onImportHosts,
          ),
        ],
      ),
    ),
  ]);

  Widget _aboutSettings() => _settingsFrame('关于', [
    _SettingsPanel(
      store: widget.store,
      child: const ListTile(
        leading: Icon(Icons.terminal),
        title: Text('Pocket SSH'),
        subtitle: Text('SSH 终端、SFTP 与 AI 终端助手。'),
      ),
    ),
  ]);

  @override
  Widget build(BuildContext context) {
    return switch (widget.section) {
      'home' => _settingsHome(),
      'appearance' => _appearanceSettings(),
      'terminal' => _terminalSettings(),
      'security' => _securitySettings(),
      'backup' => _backupSettings(),
      'about' => _aboutSettings(),
      _ => _buildAiSettings(),
    };
  }

  Widget _buildAiSettings() => Scaffold(
    backgroundColor: Theme.of(context).colorScheme.surface,
    appBar: AppBar(
      title: const Text('AI 助手'),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
    ),
    body: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              const _SectionTitle('模型连接'),
              _SettingsPanel(
                store: widget.store,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: channelName,
                      enabled: !aiBusy,
                      decoration: const InputDecoration(
                        labelText: '渠道名称',
                        hintText: '例如：主用接口',
                        helperText: '留空时显示网站域名',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: endpoint,
                      enabled: !aiBusy,
                      onChanged: (_) => setState(() {
                        models = [];
                        aiStatus = null;
                        removeAiKey = false;
                        _resetHeaders();
                      }),
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'AI 网站地址（HTTP / HTTPS）',
                        hintText: 'https://api.example.com',
                        helperText: '只填网站，接口路径自动补全',
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<AiApi>(
                      initialValue: selectedApi,
                      decoration: const InputDecoration(labelText: '接口类型'),
                      items: const [
                        DropdownMenuItem(
                          value: AiApi.chat,
                          child: Text('Chat'),
                        ),
                        DropdownMenuItem(
                          value: AiApi.responses,
                          child: Text('Responses'),
                        ),
                      ],
                      onChanged: aiBusy
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() {
                                  selectedApi = value;
                                  aiStatus = null;
                                });
                              }
                            },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: model,
                      enabled: !aiBusy,
                      decoration: const InputDecoration(labelText: '模型名称'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: apiKey,
                      obscureText: hidden,
                      enabled: !aiBusy && !removeAiKey,
                      enableSuggestions: false,
                      autocorrect: false,
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
                    if (widget.store.aiEndpoint.isNotEmpty &&
                        aiBaseUrl(endpoint.text) ==
                            aiBaseUrl(widget.store.aiEndpoint))
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('保存时清除现有 API 密钥'),
                        value: removeAiKey,
                        onChanged: aiBusy
                            ? null
                            : (value) =>
                                  setState(() => removeAiKey = value == true),
                      ),
                    ExpansionTile(
                      title: const Text('自定义请求头'),
                      onExpansionChanged: (expanded) {
                        if (expanded && !headersLoaded) {
                          unawaited(_loadHeaders());
                        }
                      },
                      children: [
                        const Text(
                          '适用于 Chat、Responses、模型列表和连接测试。请求头值加密保存；Authorization 可覆盖默认 Bearer。',
                        ),
                        if (!headersLoaded)
                          TextButton(
                            onPressed: aiBusy ? null : _loadHeaders,
                            child: const Text('读取已保存请求头'),
                          ),
                        for (final row in headerRows)
                          Padding(
                            key: ObjectKey(row),
                            padding: const EdgeInsets.only(top: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    children: [
                                      TextField(
                                        controller: row.name,
                                        enabled: !aiBusy,
                                        autocorrect: false,
                                        enableSuggestions: false,
                                        decoration: const InputDecoration(
                                          labelText: '请求头名称',
                                          hintText: 'X-Custom-Header',
                                        ),
                                        onChanged: (_) => headersEdited = true,
                                      ),
                                      TextField(
                                        controller: row.value,
                                        enabled: !aiBusy,
                                        obscureText: headersHidden,
                                        autocorrect: false,
                                        enableSuggestions: false,
                                        decoration: const InputDecoration(
                                          labelText: '请求头值',
                                        ),
                                        onChanged: (_) => headersEdited = true,
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: '删除请求头',
                                  onPressed: aiBusy
                                      ? null
                                      : () {
                                          setState(() {
                                            headerRows.remove(row);
                                            headersEdited = true;
                                          });
                                          row.dispose();
                                        },
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                          ),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton.icon(
                              onPressed: aiBusy || !headersLoaded
                                  ? null
                                  : () => setState(() {
                                      headerRows.add(_AiHeaderRow());
                                      headersEdited = true;
                                    }),
                              icon: const Icon(Icons.add),
                              label: const Text('添加请求头'),
                            ),
                            TextButton.icon(
                              onPressed: aiBusy || headerRows.isEmpty
                                  ? null
                                  : () => setState(
                                      () => headersHidden = !headersHidden,
                                    ),
                              icon: Icon(
                                headersHidden
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                              ),
                              label: Text(headersHidden ? '显示请求头值' : '隐藏请求头值'),
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (models.isNotEmpty)
                      DropdownMenu<String>(
                        expandedInsets: EdgeInsets.zero,
                        enabled: !aiBusy,
                        enableFilter: true,
                        label: const Text('从服务模型列表选择'),
                        dropdownMenuEntries: [
                          for (final name in models)
                            DropdownMenuEntry(value: name, label: name),
                        ],
                        onSelected: (value) {
                          if (value != null) model.text = value;
                        },
                      ),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: aiBusy
                              ? null
                              : () => checkAi(listModels: true),
                          child: const Text('获取模型列表'),
                        ),
                        OutlinedButton(
                          onPressed: aiBusy
                              ? null
                              : () => checkAi(listModels: false),
                          child: const Text('测试模型连接'),
                        ),
                      ],
                    ),
                    if (aiBusy) const LinearProgressIndicator(),
                    if (aiStatus != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(aiStatus!),
                      ),
                    ExpansionTile(
                      title: const Text('模型容量与上下文压缩'),
                      children: [
                        TextField(
                          controller: contextWindow,
                          enabled: !aiBusy,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '模型上下文窗口（tokens）',
                          ),
                        ),
                        TextField(
                          controller: maxOutput,
                          enabled: !aiBusy,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '最大输出（含推理 tokens）',
                          ),
                        ),
                        TextField(
                          controller: compression,
                          enabled: !aiBusy,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '自动压缩阈值（50%–90%）',
                          ),
                        ),
                        const Text(
                          '按服务提供的模型规格填写；无 usage 数据时显示估算值，不能从模型名称可靠推断容量。',
                        ),
                      ],
                    ),
                    const Text('连接测试使用所选接口发送固定消息。Agent 执行结果会发送给此服务继续分析。'),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: aiBusy ? null : saveAi,
                        child: const Text('加密保存 AI 设置'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({
    required this.store,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final AppStore store;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow.withValues(
          alpha: store.glassStyle == 'solid' ? 1 : .98,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .5)),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _WorkspaceHero extends StatelessWidget {
  const _WorkspaceHero({
    required this.hostCount,
    required this.sessionCount,
    required this.onQuickConnect,
    required this.onAddHost,
  });

  final int hostCount;
  final int sessionCount;
  final VoidCallback onQuickConnect;
  final VoidCallback onAddHost;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppPalette.heroTop,
              AppPalette.heroMiddle,
              AppPalette.heroBottom,
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: colors.primary.withValues(alpha: .15),
              blurRadius: 30,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              top: -56,
              right: -32,
              child: Container(
                width: 190,
                height: 190,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .08),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.shield_outlined,
                        size: 16,
                        color: AppPalette.heroHighlight,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          'SECURE REMOTE WORKSPACE',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: AppPalette.heroText,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.1,
                              ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '你的服务器，随时就绪。',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.4,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '安全连接主机，继续终端与文件工作。',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: .78),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 18,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _HeroMetric(value: '$hostCount', label: '已保存主机'),
                      Container(
                        width: 1,
                        height: 30,
                        color: Colors.white.withValues(alpha: .22),
                      ),
                      _HeroMetric(value: '$sessionCount', label: '在线会话'),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppPalette.heroButton,
                          foregroundColor: AppPalette.heroButtonText,
                        ),
                        onPressed: onQuickConnect,
                        icon: const Icon(Icons.bolt_rounded),
                        label: const Text('快速连接'),
                      ),
                      Tooltip(
                        message: '添加主机',
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: .42),
                            ),
                          ),
                          onPressed: onAddHost,
                          icon: const Icon(Icons.add),
                          label: const Text('添加主机'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = active ? colors.primary : colors.tertiary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PageIntro extends StatelessWidget {
  const _PageIntro({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final String eyebrow;
  final String title;
  final String subtitle;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: colors.primary,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.5,
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.primaryContainer.withValues(alpha: .55),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(
                  trailing,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

class _HeroMetric extends StatelessWidget {
  const _HeroMetric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(
        value,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(width: 8),
      Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Colors.white.withValues(alpha: .76),
        ),
      ),
    ],
  );
}

class _SettingsGroupTitle extends StatelessWidget {
  const _SettingsGroupTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.3,
      ),
    ),
  );
}

class _SettingsEntry extends StatelessWidget {
  const _SettingsEntry({
    required this.store,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final AppStore store;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer.withValues(alpha: .55),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: colors.primary),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
