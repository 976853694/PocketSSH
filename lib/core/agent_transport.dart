import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_controller.dart';
import 'agent_protocol.dart';

class AgentTransport {
  const AgentTransport({
    required this.endpoint,
    required this.model,
    required this.apiKey,
  });
  final Uri endpoint;
  final String model;
  final String? apiKey;

  Future<AgentReply> request(
    List<Map<String, Object?>> messages,
    AgentCancellation cancellation,
    void Function(String) onText,
  ) async {
    cancellation.check();
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    final unregister = cancellation.onCancel(() => http.close(force: true));
    final timer = Timer(
      const Duration(seconds: 90),
      () => http.close(force: true),
    );
    try {
      final request = await cancellation.wait(http.postUrl(endpoint));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      if (apiKey?.isNotEmpty == true) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      }
      request.write(
        jsonEncode({
          'model': model,
          'stream': true,
          'tools': agentTools,
          'tool_choice': 'auto',
          'messages': messages,
        }),
      );
      final response = await cancellation.wait(
        request.close().timeout(const Duration(seconds: 30)),
      );
      if (response.statusCode != 200) {
        throw StateError('模型请求失败（HTTP ${response.statusCode}），请检查地址、密钥和工具调用支持');
      }
      final parser = AgentStreamParser();
      final eventLines = <String>[];
      var size = 0;
      var eventSize = 0;
      void dispatch() {
        if (eventLines.isEmpty) return;
        final data = eventLines.join('\n');
        eventLines.clear();
        eventSize = 0;
        final text = parser.add(data);
        if (text.isNotEmpty) onText(text);
      }

      final lines = response
          .map<List<int>>((chunk) {
            size += chunk.length;
            if (size > 256 * 1024) throw const FormatException('模型响应过大');
            cancellation.check();
            return chunk;
          })
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 40));
      await for (final line in lines) {
        cancellation.check();
        if (line.isEmpty) {
          dispatch();
          if (parser.done) break;
          continue;
        }
        if (!line.startsWith('data:')) continue;
        final value = line.substring(5).replaceFirst(RegExp(r'^ '), '');
        eventSize += value.length;
        if (eventSize > 32768) throw const FormatException('模型流事件过大');
        eventLines.add(value);
      }
      if (!parser.done) dispatch();
      return parser.complete();
    } finally {
      timer.cancel();
      unregister();
      http.close(force: true);
    }
  }
}
