import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/agent_controller.dart';
import '../../core/agent_protocol.dart';
import '../../core/agent_remote.dart';
import '../../core/agent_transport.dart';
import '../../core/ai_endpoint.dart';
import '../../core/app_store.dart';
import '../../core/sessions.dart';
import '../../core/ssh_connection.dart';

class AiAgentPanel extends StatefulWidget {
  const AiAgentPanel({
    super.key,
    required this.store,
    required this.session,
    required this.selection,
  });
  final AppStore store;
  final WorkspaceSession session;
  final String selection;
  @override
  State<AiAgentPanel> createState() => _AiAgentPanelState();
}

class _AiAgentPanelState extends State<AiAgentPanel> {
  final question = TextEditingController();
  final contextText = TextEditingController();
  late final SshConnection connection = widget.session.connection;
  late final AgentController agent;
  AgentTransport? transport;
  bool preparing = false;
  String? localError;
  String? configuration;

  bool get current =>
      widget.session.connected &&
      identical(connection, widget.session.connection);

  @override
  void initState() {
    super.initState();
    final initial = redactSecrets(widget.selection);
    contextText.text = initial.substring(0, initial.length.clamp(0, 12000));
    agent = AgentController(
      requestModel: (messages, cancellation, onText) =>
          transport!.request(messages, cancellation, onText),
      executeTool: AgentRemote(connection).execute,
      approve: approve,
      connectionIsCurrent: () => current,
    );
    widget.session.addListener(connectionChanged);
  }

  void connectionChanged() {
    if (!current) agent.stop();
    if (mounted) setState(() {});
  }

  Future<bool> approve(
    AgentToolRequest request,
    String? result,
    AgentCancellation cancellation,
  ) async {
    if (!mounted || !current || cancellation.cancelled) return false;
    final host = widget.session.profile;
    final target = SshTarget(host.host, host.port, host.username).label;
    final route = DialogRoute<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        title: Text(result == null ? '确认远程读取' : '确认分享工具结果'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('SSH 目标：$target'),
                const SizedBox(height: 8),
                SelectableText(request.description),
                const SizedBox(height: 12),
                if (result == null)
                  const Text('只批准本次读取。读取完成后会先展示结果，确认后才会交给模型继续分析。')
                else ...[
                  Text('将发往 ${transport?.endpoint.host ?? ''}'),
                  const SizedBox(height: 8),
                  const Text('请核对以下内容。自动脱敏无法识别所有隐私信息；不想发送时请选择停止。'),
                  const SizedBox(height: 8),
                  SelectableText(
                    result,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('停止任务'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(result == null ? '批准本次读取' : '确认分享并继续'),
          ),
        ],
      ),
    );
    final navigator = Navigator.of(context, rootNavigator: true);
    final unregister = cancellation.onCancel(() {
      if (route.isActive) navigator.removeRoute(route, false);
    });
    try {
      cancellation.check();
      final approved = await navigator.push(route);
      return approved == true && current && !cancellation.cancelled;
    } finally {
      unregister();
    }
  }

  Future<void> send() async {
    if (preparing || agent.running) return;
    if (!current) {
      setState(() => localError = '请先重新连接 SSH，再打开 Agent');
      return;
    }
    final endpoint = chatEndpoint(widget.store.aiEndpoint);
    final model = widget.store.aiModel.trim();
    if (endpoint == null || model.isEmpty) {
      setState(() => localError = '请在设置中填写 AI 服务地址和模型');
      return;
    }
    final task = question.text.trim();
    if (task.isEmpty) {
      setState(() => localError = '请描述任务');
      return;
    }
    setState(() {
      preparing = true;
      localError = null;
    });
    try {
      if (!await widget.store.unlock() || !mounted || !current) return;
      final key = await widget.store.secret('ai:$endpoint');
      if (!mounted || !current) return;
      final selectedConfiguration = '$endpoint\n$model';
      if (configuration != null && configuration != selectedConfiguration) {
        agent.clear();
      }
      configuration = selectedConfiguration;
      transport = AgentTransport(endpoint: endpoint, model: model, apiKey: key);
      final suppliedContext = contextText.text;
      question.clear();
      contextText.clear();
      setState(() => preparing = false);
      await agent.send(task, context: suppliedContext);
    } catch (_) {
      if (mounted) setState(() => localError = '无法读取 AI 密钥，请检查设备认证和服务设置');
    } finally {
      transport = null;
      if (mounted) setState(() => preparing = false);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(connectionChanged);
    agent.dispose();
    question.dispose();
    contextText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: agent,
    builder: (context, _) {
      final busy = agent.running || preparing;
      final colors = Theme.of(context).colorScheme;
      return SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .92,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.auto_awesome),
                  title: const Text('SSH 运维 Agent'),
                  subtitle: Text(
                    '${widget.session.profile.name} · ${agent.status}',
                  ),
                  trailing: IconButton(
                    tooltip: '新建对话',
                    onPressed: busy
                        ? null
                        : () {
                            agent.clear();
                            setState(() => localError = null);
                          },
                    icon: const Icon(Icons.add_comment_outlined),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    '${widget.store.aiModel} · 固定只读工具 · 每次读取和分享都由你确认',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                if (busy) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (agent.events.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            '描述目标，Agent 会提出检查步骤，申请读取，并根据你确认分享的结果继续分析。\n\n支持磁盘、内存、运行时间、系统信息，以及 SFTP 目录和文本预览。对话仅保留在当前面板。',
                          ),
                        ),
                      for (final event in agent.events)
                        Card(
                          color: event.kind == 'user'
                              ? colors.primaryContainer
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: event.kind == 'tool'
                                ? ExpansionTile(
                                    tilePadding: EdgeInsets.zero,
                                    title: Text(event.status),
                                    subtitle: Text(
                                      event.text.split('\n').first,
                                    ),
                                    children: [SelectableText(event.text)],
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        event.kind == 'user' ? '你' : 'Agent',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.labelSmall,
                                      ),
                                      const SizedBox(height: 6),
                                      SelectableText(
                                        event.text.isEmpty
                                            ? '正在思考…'
                                            : event.text,
                                      ),
                                      if (event.text.isNotEmpty)
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: IconButton(
                                            tooltip: '复制',
                                            onPressed: () => Clipboard.setData(
                                              ClipboardData(text: event.text),
                                            ),
                                            icon: const Icon(
                                              Icons.copy,
                                              size: 18,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                          ),
                        ),
                      if (localError ?? agent.error case final error?)
                        Text(error, style: TextStyle(color: colors.error)),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: ExpansionTile(
                    title: const Text('本次附加上下文（发送前核对）'),
                    initiallyExpanded: contextText.text.isNotEmpty,
                    children: [
                      TextField(
                        controller: contextText,
                        enabled: !busy,
                        maxLength: 12000,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          hintText: '仅发送你填写或选中的内容',
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: question,
                          enabled: !busy,
                          minLines: 1,
                          maxLines: 4,
                          maxLength: 4000,
                          decoration: const InputDecoration(
                            hintText: '例如：检查磁盘空间不足的原因',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: FilledButton.icon(
                          onPressed: preparing
                              ? null
                              : agent.running
                              ? agent.stop
                              : send,
                          icon: Icon(
                            agent.running ? Icons.stop : Icons.arrow_upward,
                          ),
                          label: Text(agent.running ? '停止' : '发送'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
