import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';
import '../../core/app_store.dart';
import '../../core/sessions.dart';
import '../../core/ssh_connection.dart';
import '../connection/connection_page.dart';
import 'ai_panel.dart';
import 'sftp_page.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({
    super.key,
    required this.session,
    required this.store,
    required this.sessions,
    required this.verify,
    this.directCredentials,
    this.directJumpCredentials,
  });

  final WorkspaceSession session;
  final AppStore store;
  final Sessions sessions;
  final Future<bool> Function(SshTarget, String, String) verify;
  final Credentials? directCredentials;
  final Credentials? directJumpCredentials;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final view = GlobalKey<TerminalViewState>();
  final controller = TerminalController();
  final draftController = TextEditingController();
  final searchField = TextEditingController();
  WorkspaceSession get session => widget.session;
  String draft = '';
  bool _confirmingDraft = false;
  bool search = false;
  List<TerminalSearchMatch> matches = [];
  int match = 0;
  final tunnelHost = TextEditingController(text: '127.0.0.1');
  final tunnelRemotePort = TextEditingController(text: '5432');
  final tunnelLocalPort = TextEditingController(text: '15432');

  @override
  void initState() {
    super.initState();
    session.addListener(update);
    draftController.addListener(() {
      final value = draftController.text;
      if (draft != value) setState(() => draft = value);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || session.connected || session.opening) return;
      if (widget.directCredentials != null) {
        unawaited(
          _open(widget.directCredentials!, widget.directJumpCredentials),
        );
      } else if (!session.finished) {
        unawaited(_connectAgain());
      }
    });
  }

  void update() {
    if (mounted) setState(() {});
  }

  Future<void> _open(
    Credentials credentials, [
    Credentials? jumpCredentials,
  ]) async {
    HostProfile? jump;
    if (session.profile.jumpId case final id?) {
      jump = widget.store.hosts.where((host) => host.id == id).firstOrNull;
    }
    await session.open(
      credentials,
      widget.verify,
      jump: jump,
      jumpCredentials: jumpCredentials,
      onAuthenticated: () =>
          widget.store.rememberCredentials(session.profile, credentials),
      onJumpAuthenticated: jump == null
          ? null
          : () => widget.store.rememberCredentials(jump!, jumpCredentials!),
    );
  }

  Future<void> _connectAgain() async {
    try {
      final credentials = await requestCredentials(
        context,
        session.profile,
        widget.store,
      );
      if (credentials == null || !mounted) return;
      Credentials? jumpCredentials;
      HostProfile? jump;
      if (session.profile.jumpId case final id?) {
        jump = widget.store.hosts.where((host) => host.id == id).firstOrNull;
        if (jump == null) throw StateError('找不到跳板机');
        jumpCredentials = await requestCredentials(context, jump, widget.store);
        if (jumpCredentials == null || !mounted) return;
      }
      unawaited(_open(credentials, jumpCredentials));
    } catch (_) {
      if (mounted) _notice('无法读取连接凭据。');
    }
  }

  void _notice(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _tunnels() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('本地端口转发'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: tunnelHost,
              decoration: const InputDecoration(labelText: '远程目标主机'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: tunnelRemotePort,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '远程目标端口'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: tunnelLocalPort,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '本地监听端口'),
            ),
            if (session.forwards.isNotEmpty) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('活动转发：\\n${session.forwards.join('\\n')}'),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('启动'),
          ),
        ],
      ),
    );
    if (result != true || !mounted) return;
    final host = tunnelHost.text.trim();
    final remote = int.tryParse(tunnelRemotePort.text.trim());
    final local = int.tryParse(tunnelLocalPort.text.trim());
    if (host.isEmpty ||
        remote == null ||
        local == null ||
        remote < 1 ||
        remote > 65535 ||
        local < 1 ||
        local > 65535) {
      _notice('请输入有效的主机和端口。');
      return;
    }
    try {
      final port = await session.forwardLocal(host, remote, local);
      if (mounted) _notice('转发已启动：127.0.0.1:$port');
    } catch (_) {
      if (mounted) _notice('转发启动失败，请确认本地端口未被占用。');
    }
  }

  void _find(String value) {
    matches = session.terminal.search(value);
    match = 0;
    controller.clearSearchHighlights();
    if (matches.isNotEmpty) {
      controller.setSearchHighlights(
        session.terminal.buffer,
        matches.map((item) => item.range).toList(),
      );
      controller.setCurrentSearchHighlight(0);
    }
    setState(() => search = true);
  }

  Future<void> _copySelection() async {
    final selected = controller.selectionFor(session.terminal.buffer);
    if (selected == null) return;
    final value = session.terminal.buffer.getText(selected, true);
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    controller.clearSelection();
  }

  Future<void> _openAi([String? text]) async {
    final selection = controller.selectionFor(session.terminal.buffer);
    final contextText =
        text ??
        (selection == null
            ? ''
            : session.terminal.buffer.getText(selection, true));
    controller.clearSelection();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => AiAgentPanel(
        store: widget.store,
        session: session,
        selection: contextText,
      ),
    );
  }

  Future<void> _saveDraft() async {
    final controller = TextEditingController(text: draft);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('收藏命令'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '请输入命令或说明'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('收藏'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty) return;
    widget.store.snippets.insert(0, value);
    if (widget.store.snippets.length > 50) widget.store.snippets.removeLast();
    await widget.store.save();
    if (mounted) _notice('已收藏命令。');
  }

  Future<void> _showSnippets() async {
    if (widget.store.snippets.isEmpty) {
      _notice('还没有收藏的命令。');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('命令收藏', style: Theme.of(context).textTheme.titleLarge),
          for (var index = 0; index < widget.store.snippets.length; index++)
            ListTile(
              title: Text(
                widget.store.snippets[index],
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                draftController.text = widget.store.snippets[index];
                Navigator.pop(sheetContext);
              },
              trailing: IconButton(
                onPressed: () async {
                  widget.store.snippets.removeAt(index);
                  await widget.store.save();
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                },
                icon: const Icon(Icons.delete_outline),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _toggleFontSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('终端字体大小'),
            Slider(
              min: 11,
              max: 24,
              divisions: 13,
              value: widget.store.fontSize,
              label: '${widget.store.fontSize.round()} px',
              onChanged: (value) {
                widget.store.fontSize = value;
                setState(() {});
              },
              onChangeEnd: (value) {
                widget.store.fontSize = value;
                widget.store.save();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text != null && session.connected) session.terminal.paste(text);
  }

  @override
  void dispose() {
    session.removeListener(update);
    controller.dispose();
    draftController.dispose();
    searchField.dispose();
    tunnelHost.dispose();
    tunnelRemotePort.dispose();
    tunnelLocalPort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = widget.store.terminalTheme == 'dark';
    final foreground = dark ? const Color(0xffd9e2e5) : const Color(0xff182127);
    final background = dark ? const Color(0xff10181c) : const Color(0xfff5f8f7);
    final theme = TerminalTheme(
      cursor: colors.primary,
      selection: colors.primary.withValues(alpha: .4),
      foreground: foreground,
      background: background,
      black: dark ? Colors.black : const Color(0xff182127),
      white: dark ? const Color(0xffe7eeef) : Colors.white,
      red: const Color(0xffe15c65),
      green: const Color(0xff60c99f),
      yellow: const Color(0xffedc875),
      blue: const Color(0xff66a9e4),
      magenta: const Color(0xffc792ea),
      cyan: const Color(0xff61c7cb),
      brightBlack: const Color(0xff73838a),
      brightRed: const Color(0xffff7280),
      brightGreen: const Color(0xff8ce1b8),
      brightYellow: const Color(0xffffdb91),
      brightBlue: const Color(0xff82bcff),
      brightMagenta: const Color(0xffd8a5ff),
      brightCyan: const Color(0xff84e4e3),
      brightWhite: dark ? Colors.white : const Color(0xff111a20),
      searchHitBackground: const Color(0xffffe36e),
      searchHitBackgroundCurrent: const Color(0xff36d789),
      searchHitForeground: Colors.black,
    );

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              session.profile.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${session.profile.username}@${session.profile.host}:${session.profile.port} · ${session.status}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'SFTP 文件管理',
            onPressed: session.connected
                ? () => Navigator.push<void>(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          SftpPage(session: session, store: widget.store),
                    ),
                  )
                : null,
            icon: const Icon(Icons.folder_open_outlined),
          ),
          IconButton(
            tooltip: 'AI 助手',
            onPressed: () => _openAi(),
            icon: const Icon(Icons.auto_awesome_outlined),
          ),
          IconButton(
            tooltip: '本地端口转发',
            onPressed: session.connected ? _tunnels : null,
            icon: Icon(
              Icons.lan_outlined,
              color: session.forwards.isEmpty
                  ? null
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
          if (widget.sessions.items.length > 1)
            PopupMenuButton<WorkspaceSession>(
              tooltip: '切换 SSH 会话',
              icon: const Icon(Icons.tab),
              onSelected: (target) {
                if (identical(target, session)) return;
                Navigator.of(context).pushReplacement<void, void>(
                  MaterialPageRoute(
                    builder: (_) => TerminalPage(
                      session: target,
                      store: widget.store,
                      sessions: widget.sessions,
                      verify: widget.verify,
                    ),
                  ),
                );
              },
              itemBuilder: (_) => [
                for (final target in widget.sessions.items)
                  PopupMenuItem(
                    value: target,
                    enabled: !identical(target, session),
                    child: Text('${target.profile.name} · ${target.status}'),
                  ),
              ],
            ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'search') setState(() => search = !search);
              if (value == 'theme') {
                widget.store.terminalTheme = dark ? 'light' : 'dark';
                widget.store.save();
                setState(() {});
              }
              if (value == 'font') _toggleFontSheet();
              if (value == 'copy') _copySelection();
              if (value == 'snippets') _showSnippets();
              if (value == 'save') _saveDraft();
              if (value == 'clear') session.terminal.clear();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'search', child: Text('搜索输出')),
              PopupMenuItem(value: 'copy', child: Text('复制选中内容')),
              PopupMenuItem(value: 'snippets', child: Text('命令收藏')),
              PopupMenuItem(value: 'save', child: Text('收藏当前草稿')),
              PopupMenuItem(value: 'theme', child: Text('切换终端主题')),
              PopupMenuItem(value: 'font', child: Text('调整字体大小')),
              PopupMenuItem(value: 'clear', child: Text('清空终端')),
            ],
          ),
          IconButton(
            tooltip: '停止端口转发',
            onPressed: session.forwarding ? session.stopForwards : null,
            icon: const Icon(Icons.stop_circle_outlined),
          ),
          IconButton(
            tooltip: '断开连接',
            onPressed: () => session.stop(),
            icon: const Icon(Icons.link_off),
          ),
        ],
      ),
      body: Column(
        children: [
          if (search)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: searchField,
                      decoration: const InputDecoration(hintText: '搜索终端输出'),
                      onSubmitted: _find,
                    ),
                  ),
                  IconButton(
                    onPressed: () => _find(searchField.text),
                    icon: const Icon(Icons.search),
                  ),
                  IconButton(
                    onPressed: _nextMatch,
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                  IconButton(
                    onPressed: _closeSearch,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          if (!session.connected && !session.finished)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: Container(
              color: background,
              child: TerminalView(
                session.terminal,
                key: view,
                controller: controller,
                theme: theme,
                textStyle: TerminalStyle(fontSize: widget.store.fontSize),
                padding: const EdgeInsets.all(10),
                readOnly: !session.connected,
                onPaste: _paste,
              ),
            ),
          ),
          if (session.finished)
            Padding(
              padding: const EdgeInsets.all(8),
              child: FilledButton.icon(
                onPressed: _connectAgain,
                icon: const Icon(Icons.refresh),
                label: const Text('重新连接'),
              ),
            ),
          if (session.connected)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  IconButton(
                    tooltip: '打开键盘',
                    onPressed: () => view.currentState?.requestKeyboard(),
                    icon: const Icon(Icons.keyboard_outlined),
                  ),
                  for (final shortcut in _terminalKeys)
                    _shortcut(shortcut.$1, shortcut.$2, shortcut.$3),
                  if (widget.store.recentCommandHistory &&
                      widget.store.recentCommands.isNotEmpty)
                    TextButton.icon(
                      onPressed: _showRecentCommands,
                      icon: const Icon(Icons.history),
                      label: const Text('最近命令'),
                    ),
                ],
              ),
            ),
          if (session.connected)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: draftController,
                      onSubmitted: _sendDraft,
                      textInputAction: TextInputAction.send,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        hintText: '命令草稿 · 检查后发送',
                        isDense: true,
                        suffixIcon: IconButton(
                          onPressed: () {
                            draftController.clear();
                          },
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: draft.trim().isEmpty
                        ? null
                        : () => _sendDraft(draft),
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _nextMatch() {
    if (matches.isEmpty) return;
    match = (match + 1) % matches.length;
    controller.setCurrentSearchHighlight(match);
  }

  void _closeSearch() {
    controller.clearSearchHighlights();
    searchField.clear();
    setState(() => search = false);
  }

  Future<void> _showRecentCommands() async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('最近发送的命令')),
          for (final command in widget.store.recentCommands)
            ListTile(
              title: Text(
                command,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                draftController.text = command;
                Navigator.pop(context);
              },
            ),
        ],
      ),
    );
  }

  Future<void> _sendDraft(String value) async {
    if (_confirmingDraft || !session.connected || value.trim().isEmpty) return;
    final highRisk = isHighRiskCommand(value);
    if (highRisk || value.contains('\n') || value.contains('\r')) {
      final connection = session.connection;
      final target = session.profile;
      final targetLabel = SshTarget(
        target.host,
        target.port,
        target.username,
      ).label;
      _confirmingDraft = true;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(highRisk ? '确认高风险命令' : '确认执行命令'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('目标会话 · $targetLabel'),
                const SizedBox(height: 12),
                SelectableText(
                  value,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('执行'),
            ),
          ],
        ),
      );
      _confirmingDraft = false;
      if (!mounted ||
          approved != true ||
          !session.connected ||
          !identical(connection, session.connection) ||
          draftController.text != value) {
        return;
      }
    }
    _writeConfirmedCommand(value);
    draftController.clear();
  }

  void _writeConfirmedCommand(String value) {
    if (widget.store.recentCommandHistory &&
        !widget.store.recentCommands.contains(value)) {
      widget.store.recentCommands.insert(0, value);
      if (widget.store.recentCommands.length > 20) {
        widget.store.recentCommands.removeLast();
      }
      unawaited(widget.store.save());
    }
    session.terminal.paste(value);
    session.terminal.keyInput(TerminalKey.enter);
  }

  Widget _shortcut(String label, TerminalKey key, bool ctrl) => TextButton(
    onPressed: () => session.terminal.keyInput(key, ctrl: ctrl),
    child: Text(label),
  );
}

const _terminalKeys = [
  ('Esc', TerminalKey.escape, false),
  ('Tab', TerminalKey.tab, false),
  ('Ctrl+C', TerminalKey.keyC, true),
  ('Ctrl+D', TerminalKey.keyD, true),
  ('↑', TerminalKey.arrowUp, false),
  ('↓', TerminalKey.arrowDown, false),
  ('←', TerminalKey.arrowLeft, false),
  ('→', TerminalKey.arrowRight, false),
];
