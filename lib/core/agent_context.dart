import 'dart:convert';

class AgentBudget {
  AgentBudget({
    this.contextTokens = 65536,
    this.maxOutputTokens = 8192,
    this.compressionThreshold = .75,
  }) {
    if (contextTokens < 4096 ||
        contextTokens > 4000000 ||
        maxOutputTokens < 256 ||
        maxOutputTokens > contextTokens ~/ 2 ||
        compressionThreshold < .5 ||
        compressionThreshold > .9) {
      throw const FormatException(
        '上下文至少 4096 tokens；最大输出为 256 至上下文的一半；压缩阈值为 50%–90%',
      );
    }
  }
  final int contextTokens, maxOutputTokens;
  final double compressionThreshold;
  int get inputLimit => contextTokens - maxOutputTokens - 512;
}

int estimateTokens(Object value) {
  final text = value is String ? value : jsonEncode(value);
  var ascii = 0, other = 0;
  for (final rune in text.runes) {
    if (rune < 128) {
      ascii++;
    } else {
      other++;
    }
  }
  return (ascii / 3 + other * 1.5).ceil() + 64;
}

class AgentCompaction {
  AgentCompaction(this.removed, this.retained);
  final List<Map<String, Object?>> removed, retained;
}

AgentCompaction splitForCompaction(
  List<Map<String, Object?>> messages,
  int retainedTokens,
) {
  final blocks = <List<Map<String, Object?>>>[];
  for (final message in messages.skip(1)) {
    if (message['role'] == 'tool' &&
        blocks.isNotEmpty &&
        blocks.last.first['tool_calls'] != null) {
      blocks.last.add(message);
    } else {
      blocks.add([message]);
    }
  }
  var count = 0, cut = blocks.length;
  for (var i = blocks.length - 1; i >= 0; i--) {
    final size = estimateTokens(blocks[i]);
    if (count + size > retainedTokens) break;
    count += size;
    cut = i;
  }
  return AgentCompaction(
    blocks.take(cut).expand((b) => b).toList(),
    blocks.skip(cut).expand((b) => b).toList(),
  );
}

String compactEvidence(List<Map<String, Object?>> messages, int maxCharacters) {
  if (messages.isEmpty) return '';
  final perMessage = (maxCharacters ~/ messages.length).clamp(80, 12000);
  final result = StringBuffer();
  for (final message in messages) {
    final text = jsonEncode(message);
    final excerpt = text.length <= perMessage
        ? text
        : '${text.substring(0, perMessage ~/ 2)}\n[中间内容省略]\n${text.substring(text.length - perMessage ~/ 2)}';
    result.writeln(excerpt);
  }
  final text = result.toString();
  return text.length <= maxCharacters
      ? text
      : '${text.substring(0, maxCharacters ~/ 2)}\n[较早证据节选]\n${text.substring(text.length - maxCharacters ~/ 2)}';
}
