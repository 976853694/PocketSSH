import 'agent_protocol.dart';

enum AgentTaskKind { disk, service }

class AgentPolicy {
  AgentPolicy({required this.kind, required String target})
    : target = kind == AgentTaskKind.disk
          ? AgentToolRequest.validPath(target)
          : AgentToolRequest.validService(target);

  final AgentTaskKind kind;
  final String target;
  String get identity => '${kind.name}:$target';
  String get description => kind == AgentTaskKind.disk
      ? '磁盘诊断 · $target（包含子目录）'
      : '服务诊断 · $target（状态和最近 100 条日志）';
  List<Map<String, Object>> get tools => agentTools.where((tool) {
    final name = (tool['function'] as Map)['name'];
    return name == 'diagnose' ||
        (kind == AgentTaskKind.disk
            ? name == 'directory_usage'
            : name == 'service_status' || name == 'service_logs');
  }).toList();

  List<AgentToolRequest> get initialChecks => kind == AgentTaskKind.disk
      ? [
          const AgentToolRequest('diagnose', 'disks'),
          const AgentToolRequest('diagnose', 'inodes'),
          AgentToolRequest('directory_usage', target),
        ]
      : [
          AgentToolRequest('service_status', target),
          AgentToolRequest('service_logs', target),
        ];

  void check(AgentToolRequest request) {
    if (request.name == 'diagnose' &&
        diagnosticCommands.containsKey(request.value)) {
      return;
    }
    if (kind == AgentTaskKind.disk && request.name == 'directory_usage') {
      final path = AgentToolRequest.validPath(request.value);
      if (target == '/' || path == target || path.startsWith('$target/')) {
        return;
      }
    }
    if (kind == AgentTaskKind.service &&
        (request.name == 'service_status' || request.name == 'service_logs') &&
        AgentToolRequest.validService(request.value) == target) {
      return;
    }
    throw StateError('工具超出本次任务范围：${request.description}');
  }
}
