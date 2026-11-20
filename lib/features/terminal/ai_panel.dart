import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/agent_controller.dart';
import '../../core/agent_policy.dart';
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
  final targetText = TextEditingController(text: '/var');
  AgentTaskKind taskKind = AgentTaskKind.disk;
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
      connectionIsCurrent: () => current,
    );
    widget.session.addListener(connectionChanged);
  }

  void connectionChanged() {
    if (!current) agent.stop();
    if (mounted) setState(() {});
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
    late final AgentPolicy policy;
    try {
      policy = AgentPolicy(kind: taskKind, target: targetText.text.trim());
    } on FormatException catch (error) {
      setState(() => localError = error.message);
      return;
    }
    final task = question.text.trim().isEmpty
        ? '请完成${policy.description}，给出结论、证据和处理建议。'
        : question.text.trim();
    final suppliedContext = contextText.text;
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
      transport = AgentTransport(
        endpoint: endpoint,
        model: model,
        apiKey: key,
        tools: policy.tools,
      );
      question.clear();
      contextText.clear();
      setState(() => preparing = false);
      await agent.send(task, policy: policy, context: suppliedContext);
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
    targetText.dispose();
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
                    '${widget.store.aiModel} · 自动诊断 · 最长 3 分钟 / 12 次工具调用',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Row(
                    children: [
                      DropdownButton<AgentTaskKind>(
                        value: taskKind,
                        items: const [
                          DropdownMenuItem(
                            value: AgentTaskKind.disk,
                            child: Text('磁盘诊断'),
                          ),
                          DropdownMenuItem(
                            value: AgentTaskKind.service,
                            child: Text('服务诊断'),
                          ),
                        ],
                        onChanged: busy
                            ? null
                            : (value) {
                                if (value == null) return;
                                setState(() {
                                  taskKind = value;
                                  targetText.text = value == AgentTaskKind.disk
                                      ? '/var'
                                      : 'nginx';
                                });
                              },
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: targetText,
                          enabled: !busy,
                          decoration: InputDecoration(
                            labelText: taskKind == AgentTaskKind.disk
                                ? '诊断目录（含子目录）'
                                : 'systemd 服务',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    '目标：${SshTarget(widget.session.profile.host, widget.session.profile.port, widget.session.profile.username).label}\n'
                    '点击开始后自动执行范围内检查，结果脱敏后发送至 ${chatEndpoint(widget.store.aiEndpoint)?.host ?? "设置中的 AI 服务"} 分析（脱敏可能不完整）。',
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
                            '选择诊断类型和目标，点击开始诊断。Agent 会自动执行基础检查，并根据输出继续排查，直到形成报告。\n\n磁盘：容量、inode 和目录占用；服务：systemd 状态和最近日志。执行过程可展开查看，对话保留在当前面板。',
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
                            hintText: '补充任务或继续追问（可留空）',
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
                          label: Text(agent.running ? '停止' : '开始诊断'),
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
