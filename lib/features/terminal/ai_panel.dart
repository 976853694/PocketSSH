import 'package:flutter/material.dart';

import '../../core/agent_controller.dart';
import '../../core/agent_policy.dart';
import '../../core/agent_protocol.dart';
import '../../core/agent_remote.dart';
import '../../core/agent_transport.dart';
import '../../core/ai_endpoint.dart';
import '../../core/app_store.dart';
import '../../core/sessions.dart';
import '../../core/ssh_connection.dart';
import 'agent_conversation.dart';

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
  AgentMode mode = AgentMode.review;
  AgentTransport? transport;
  AgentCancellation? preparing;
  String? localError, configuration;
  bool get current =>
      widget.session.connected &&
      identical(connection, widget.session.connection);
  String get target => SshTarget(
    widget.session.profile.host,
    widget.session.profile.port,
    widget.session.profile.username,
  ).label;
  @override
  void initState() {
    super.initState();
    contextText.text = redactSecrets(widget.selection);
    agent = AgentController(
      requestModel: (messages, cancel, onText) =>
          transport!.request(messages, cancel, onText),
      requestSummary: (messages, cancel, onText) => transport!.request(
        messages,
        cancel,
        onText,
        toolsEnabled: false,
        outputTokens: (widget.store.aiMaxOutputTokens ~/ 2).clamp(256, 2048),
      ),
      executeTool: (request, cancel) => AgentRemote(
        connection,
        maxOutputBytes: (widget.store.aiBudget.inputLimit * 2).clamp(
          8192,
          256 * 1024,
        ),
      ).execute(request, cancel),
      connectionIsCurrent: () => current,
      approve: approve,
    );
    widget.session.addListener(connectionChanged);
  }

  void stop() {
    preparing?.cancel();
    agent.stop();
  }

  void connectionChanged() {
    if (!current) stop();
    if (mounted) setState(() {});
  }

  Future<bool> approve(
    AgentToolRequest request,
    AgentCancellation cancellation,
  ) async {
    if (!mounted || !current || cancellation.cancelled) return false;
    final route = DialogRoute<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('审查终端命令'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('目标：$target'),
                const SizedBox(height: 8),
                Text(request.purpose),
                Text(
                  '工作目录：${request.workingDirectory.isEmpty ? '登录目录' : request.workingDirectory} · 超时 ${request.timeoutSeconds} 秒',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  request.command,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('拒绝并停止'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('批准执行'),
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
      return approved == true && mounted && current && !cancellation.cancelled;
    } finally {
      unregister();
    }
  }

  Future<void> send() async {
    if (preparing != null || agent.running) return;
    final task = question.text.trim();
    if (task.isEmpty) return;
    final endpoint = aiEndpoint(widget.store.aiEndpoint, widget.store.aiApi);
    if (endpoint == null || widget.store.aiModel.trim().isEmpty) {
      setState(() => localError = '请在设置中填写网站地址、接口类型和模型');
      return;
    }
    final cancel = AgentCancellation();
    setState(() {
      preparing = cancel;
      localError = null;
    });
    try {
      final budget = widget.store.aiBudget;
      if (!await cancel.wait(widget.store.unlock()) || !mounted) return;
      final key = await cancel.wait(
        widget.store.aiSecret(widget.store.aiEndpoint),
      );
      if (!mounted) return;
      cancel.check();
      final selected =
          '$endpoint\n${widget.store.aiModel}\n${budget.contextTokens}\n${budget.maxOutputTokens}';
      if (configuration != null && configuration != selected) agent.clear();
      configuration = selected;
      transport = AgentTransport(
        endpoint: endpoint,
        model: widget.store.aiModel.trim(),
        apiKey: key,
        api: widget.store.aiApi,
        maxOutputTokens: budget.maxOutputTokens,
      );
      final supplied = contextText.text;
      question.clear();
      contextText.clear();
      setState(() => preparing = null);
      await agent.send(
        task,
        policy: AgentPolicy(mode: mode),
        budget: budget,
        context: supplied,
        modelName: widget.store.aiModel,
        target: target,
      );
    } on AgentCancelled {
      /* A cancelled unlock must never start a command. */
    } catch (error) {
      if (mounted) setState(() => localError = redactSecrets(error.toString()));
    } finally {
      transport = null;
      if (mounted) setState(() => preparing = null);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(connectionChanged);
    stop();
    agent.dispose();
    question.dispose();
    contextText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: agent,
    builder: (context, _) {
      final busy = agent.running || preparing != null;
      final colors = Theme.of(context).colorScheme;
      return SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .94,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.terminal),
                  title: const Text('AI 终端'),
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
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${widget.store.aiModel} · ${widget.store.aiApi == AiApi.chat ? 'Chat' : 'Responses'}',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                      DropdownButton<AgentMode>(
                        value: mode,
                        items: const [
                          DropdownMenuItem(
                            value: AgentMode.review,
                            child: Text('审查模式'),
                          ),
                          DropdownMenuItem(
                            value: AgentMode.dangerous,
                            child: Text('危险模式'),
                          ),
                        ],
                        onChanged: busy
                            ? null
                            : (value) {
                                if (value != null) setState(() => mode = value);
                              },
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '目标：$target${current ? '' : '（SSH 未连接）'}\n'
                      '${mode == AgentMode.dangerous ? '自动执行命令，可修改主机。' : '命令执行前由你审查。'}结果会发送至 ${aiBaseUrl(widget.store.aiEndpoint)?.host ?? '配置的 AI 服务'}。\n'
                      '上下文 ${agent.usageEstimated ? '估算 ' : ''}${agent.contextTokens}/${widget.store.aiContextTokens} tokens · 已压缩 ${agent.compressionCount} 次',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: mode == AgentMode.dangerous
                            ? colors.error
                            : null,
                      ),
                    ),
                  ),
                ),
                if (busy) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: AgentConversation(agent: agent, error: localError),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: ExpansionTile(
                    title: const Text('附加上下文'),
                    initiallyExpanded: contextText.text.isNotEmpty,
                    children: [
                      TextField(
                        controller: contextText,
                        enabled: !busy,
                        minLines: 1,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          hintText: '选中的终端内容或任务相关日志',
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: question,
                          enabled: !busy,
                          minLines: 1,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            hintText: '输入任务或继续追问',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: busy ? stop : send,
                        icon: Icon(busy ? Icons.stop : Icons.arrow_upward),
                        label: Text(busy ? '停止' : '发送'),
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
