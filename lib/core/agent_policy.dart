enum AgentMode { review, dangerous }

class AgentPolicy {
  const AgentPolicy({this.mode = AgentMode.review});
  final AgentMode mode;
  bool get requiresApproval => mode == AgentMode.review;
  String get label => requiresApproval ? '审查模式' : '危险模式';
}
