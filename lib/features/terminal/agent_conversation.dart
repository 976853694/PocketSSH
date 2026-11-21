import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/agent_controller.dart';

class AgentConversation extends StatefulWidget {
  const AgentConversation({super.key, required this.agent, this.error});
  final AgentController agent;
  final String? error;

  @override
  State<AgentConversation> createState() => _AgentConversationState();
}

class _AgentConversationState extends State<AgentConversation> {
  final _scroll = ScrollController();
  final _cards = <AgentEvent, Widget>{};
  final _indices = <AgentEvent, int>{};
  AgentEvent? _tail, _lastUser;
  bool _following = true, _scrollScheduled = false, _userScrolling = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    widget.agent.addListener(_onAgentChanged);
    _syncEvents();
  }

  @override
  void didUpdateWidget(covariant AgentConversation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agent != widget.agent) {
      oldWidget.agent.removeListener(_onAgentChanged);
      widget.agent.addListener(_onAgentChanged);
      _cards.clear();
      _lastUser = null;
      _following = true;
      _syncEvents();
    }
    if (oldWidget.error != widget.error) _scheduleFollow();
  }

  void _syncEvents() {
    final events = widget.agent.events;
    _indices.clear();
    for (var i = 0; i < events.length; i++) {
      _indices[events[i]] = i;
    }
    _cards.removeWhere((event, _) => !_indices.containsKey(event));
    final tail = events.isEmpty ? null : events.last;
    if (_tail != tail) {
      _tail?.removeListener(_scheduleFollow);
      _tail = tail;
      _tail?.addListener(_scheduleFollow);
    }
    AgentEvent? user;
    for (var i = events.length - 1; i >= 0; i--) {
      if (events[i].kind == 'user') {
        user = events[i];
        break;
      }
    }
    if (user != _lastUser) {
      _lastUser = user;
      _following = true;
    }
    if (events.isEmpty) _following = true;
  }

  void _onAgentChanged() {
    _syncEvents();
    setState(() {});
    _scheduleFollow();
  }

  void _onScroll() {
    if (_userScrolling) return;
    final following = _scroll.position.pixels <= 1;
    if (_following != following) setState(() => _following = following);
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userScrolling = true;
      if (_following) setState(() => _following = false);
    } else if (notification is ScrollEndNotification) {
      _userScrolling = false;
      _onScroll();
    }
    return false;
  }

  void _scheduleFollow() {
    if (!mounted || !_following || _scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_following || !_scroll.hasClients) return;
      if (_scroll.offset != 0) _scroll.jumpTo(0);
    });
  }

  void _showLatest() {
    setState(() => _following = true);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    widget.agent.removeListener(_onAgentChanged);
    _tail?.removeListener(_scheduleFollow);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final events = widget.agent.events;
    final error = widget.error ?? widget.agent.error;
    final errorCount = error == null ? 0 : 1;
    final count = events.length + errorCount;
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (_) {
              _scheduleFollow();
              return false;
            },
            child: ListView.builder(
              key: const ValueKey('agent-messages'),
              controller: _scroll,
              reverse: true,
              padding: const EdgeInsets.all(16),
              itemCount: count == 0 ? 1 : count,
              findChildIndexCallback: (key) {
                if (key == const ValueKey('agent-error')) {
                  return error == null ? null : 0;
                }
                if (key is! ObjectKey) return null;
                final index = _indices[key.value];
                return index == null
                    ? null
                    : events.length - 1 - index + errorCount;
              },
              itemBuilder: (context, index) {
                if (count == 0) {
                  return const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      '描述你要完成的任务。Agent 会按需执行命令、读取结果并继续操作。也可以直接聊天。\n\n每条命令使用独立 Shell，可指定工作目录；不会混入你正在输入的交互终端。',
                    ),
                  );
                }
                if (index < errorCount) {
                  return SelectableText(
                    error!,
                    key: const ValueKey('agent-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  );
                }
                final event = events[events.length - 1 - (index - errorCount)];
                return _cards.putIfAbsent(
                  event,
                  () => _AgentMessage(key: ObjectKey(event), event: event),
                );
              },
            ),
          ),
        ),
        if (!_following)
          Positioned(
            right: 16,
            bottom: 12,
            child: FloatingActionButton.small(
              key: const ValueKey('agent-show-latest'),
              heroTag: null,
              tooltip: '回到最新消息',
              onPressed: _showLatest,
              child: const Icon(Icons.arrow_downward),
            ),
          ),
      ],
    );
  }
}

class _AgentMessage extends StatelessWidget {
  const _AgentMessage({super.key, required this.event});
  final AgentEvent event;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: event,
    builder: (context, _) {
      final lineEnd = event.text.indexOf('\n');
      final colors = Theme.of(context).colorScheme;
      final userMessage = event.kind == 'user';
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: userMessage ? colors.primaryContainer : null,
          border: Border(
            left: BorderSide(
              color: userMessage ? colors.primary : colors.outlineVariant,
              width: userMessage ? 3 : 1,
            ),
            bottom: BorderSide(color: colors.outlineVariant),
          ),
        ),
        child: event.kind == 'tool'
            ? ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(event.status),
                subtitle: Text(
                  lineEnd < 0 ? event.text : event.text.substring(0, lineEnd),
                ),
                children: [
                  SelectableText(
                    event.text,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.kind == 'user'
                        ? '你'
                        : event.kind == 'context'
                        ? event.status
                        : 'Agent',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  const SizedBox(height: 6),
                  SelectableText(event.text.isEmpty ? '正在思考…' : event.text),
                  if (event.text.isNotEmpty)
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        tooltip: '复制',
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: event.text)),
                        icon: const Icon(Icons.copy, size: 18),
                      ),
                    ),
                ],
              ),
      );
    },
  );
}
