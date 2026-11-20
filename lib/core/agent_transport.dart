import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_controller.dart';
import 'agent_protocol.dart';
import 'ai_endpoint.dart';
import 'ai_headers.dart';

class AgentTransport {
  const AgentTransport({
    required this.endpoint,
    required this.model,
    required this.apiKey,
    this.api = AiApi.chat,
    this.tools = agentTools,
    this.maxOutputTokens = 8192,
    this.customHeaders = const {},
  });
  final Uri endpoint;
  final String model;
  final String? apiKey;
  final AiApi api;
  final List<Map<String, Object>> tools;
  final int maxOutputTokens;
  final Map<String, String> customHeaders;

  static List<Map<String, Object?>> responsesInput(
    List<Map<String, Object?>> messages,
  ) {
    final input = <Map<String, Object?>>[];
    for (final message in messages) {
      if (message['role'] == 'system') continue;
      if (message['role'] == 'tool') {
        input.add({
          'type': 'function_call_output',
          'call_id': message['tool_call_id'],
          'output': message['content'],
        });
      } else if (message['_responses'] case final List items) {
        input.addAll(
          items.map((item) => Map<String, Object?>.from(item as Map)),
        );
      } else {
        if ((message['content'] as String?)?.isNotEmpty == true) {
          input.add({'role': message['role'], 'content': message['content']});
        }
        for (final item in message['tool_calls'] as List? ?? []) {
          final call = item as Map;
          input.add({
            'type': 'function_call',
            'call_id': call['id'],
            'name': (call['function'] as Map)['name'],
            'arguments': (call['function'] as Map)['arguments'],
          });
        }
      }
    }
    return input;
  }

  Future<AgentReply> request(
    List<Map<String, Object?>> messages,
    AgentCancellation cancellation,
    void Function(String) onText, {
    bool toolsEnabled = true,
    int? outputTokens,
  }) async {
    cancellation.check();
    final headers = validateAiHeaders(customHeaders);
    final output = outputTokens ?? maxOutputTokens;
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    final unregister = cancellation.onCancel(() => http.close(force: true));
    final timer = Timer(
      const Duration(minutes: 5),
      () => http.close(force: true),
    );
    try {
      final request = await cancellation.wait(http.postUrl(endpoint));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      applyAiHeaders(request.headers, apiKey, headers);
      final useTools = toolsEnabled && tools.isNotEmpty;
      request.write(
        jsonEncode({
          'model': model,
          'stream': true,
          'store': false,
          if (api == AiApi.chat) ...{
            'messages': messages
                .map(
                  (m) => Map.fromEntries(
                    m.entries.where((e) => !e.key.startsWith('_')),
                  ),
                )
                .toList(),
            'max_completion_tokens': output,
            'stream_options': {'include_usage': true},
            if (useTools) 'tools': tools,
          } else ...{
            'instructions': messages
                .where((m) => m['role'] == 'system')
                .map((m) => m['content'])
                .join('\n\n'),
            'input': responsesInput(messages),
            'max_output_tokens': output,
            'include': ['reasoning.encrypted_content'],
            if (useTools)
              'tools': tools
                  .map(
                    (tool) => {
                      'type': 'function',
                      ...Map<String, Object>.from(tool['function'] as Map),
                      'strict': true,
                    },
                  )
                  .toList(),
          },
          if (useTools) 'tool_choice': 'auto',
          if (useTools) 'parallel_tool_calls': false,
        }),
      );
      final response = await cancellation.wait(
        request.close().timeout(const Duration(seconds: 60)),
      );
      if (response.statusCode != 200) {
        final error = StringBuffer();
        await for (final chunk
            in response
                .transform(utf8.decoder)
                .timeout(const Duration(seconds: 10))) {
          error.write(chunk);
          if (error.length > 16000) break;
        }
        throw HttpException(
          '模型 HTTP ${response.statusCode}: ${error.toString().substring(0, error.length.clamp(0, 16000))}',
        );
      }
      final maxCharacters = (output * 24).clamp(1024 * 1024, 16 * 1024 * 1024);
      final chat = AgentStreamParser(maxTextCharacters: maxCharacters);
      final responses = ResponsesStreamParser(maxTextCharacters: maxCharacters);
      final event = <String>[];
      var eventSize = 0, bytes = 0;
      void dispatch() {
        if (event.isEmpty) return;
        final data = event.join('\n');
        event.clear();
        eventSize = 0;
        final text = api == AiApi.chat ? chat.add(data) : responses.add(data);
        if (text.isNotEmpty) onText(text);
      }

      final lines = response
          .map<List<int>>((chunk) {
            bytes += chunk.length;
            if (bytes >
                (output * 256).clamp(8 * 1024 * 1024, 64 * 1024 * 1024)) {
              throw const FormatException('协议数据超过输出预算保护上限');
            }
            cancellation.check();
            return chunk;
          })
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 90));
      await for (final line in lines) {
        cancellation.check();
        if (line.isEmpty) {
          dispatch();
          if (api == AiApi.chat ? chat.done : responses.done) break;
        } else if (line.startsWith('data:')) {
          final value = line.substring(5).replaceFirst(RegExp(r'^ '), '');
          eventSize += value.length;
          if (eventSize > maxCharacters * 2) {
            throw const FormatException('单个模型事件过大');
          }
          event.add(value);
        }
      }
      if (event.isNotEmpty) dispatch();
      cancellation.check();
      return api == AiApi.chat ? chat.complete() : responses.complete();
    } catch (error, stack) {
      final message = redactAiHeaderValues(error.toString(), headers);
      if (message != error.toString()) {
        Error.throwWithStackTrace(StateError(message), stack);
      }
      rethrow;
    } finally {
      timer.cancel();
      unregister();
      http.close(force: true);
    }
  }
}

class ResponsesStreamParser {
  ResponsesStreamParser({this.maxTextCharacters = 1024 * 1024});
  final int maxTextCharacters;
  final _text = StringBuffer();
  Map? _response;
  bool done = false;
  String add(String data) {
    if (data.trim() == '[DONE]') return '';
    final event = jsonDecode(data);
    if (event is! Map) throw const FormatException('Responses 事件无效');
    switch (event['type']) {
      case 'response.output_text.delta':
        final delta = event['delta'];
        if (delta is! String) throw const FormatException('Responses 文本事件无效');
        _text.write(delta);
        if (_text.length > maxTextCharacters) {
          throw const FormatException('回复超过所配置输出预算的保护上限');
        }
        return delta;
      case 'error':
      case 'response.failed':
        throw StateError(
          'Responses 请求失败：${event['message'] ?? event['response'] ?? event['error']}',
        );
      case 'response.completed':
      case 'response.incomplete':
        if (event['response'] is! Map) {
          throw const FormatException('Responses 结束事件无效');
        }
        _response = event['response'] as Map;
        done = true;
    }
    return '';
  }

  AgentReply complete() {
    final response = _response;
    if (!done || response == null) {
      throw const FormatException('Responses 连接提前结束，未执行命令');
    }
    final truncated = response['status'] == 'incomplete';
    if (response['status'] != 'completed' && !truncated) {
      throw const FormatException('Responses 未正常完成');
    }
    final items = (response['output'] as List? ?? [])
        .map((i) => Map<String, Object?>.from(i as Map))
        .toList();
    final calls = <AgentToolCall>[];
    final finalText = StringBuffer();
    for (final item in items) {
      if (item['type'] == 'function_call') {
        if (truncated ||
            (item['status'] != null && item['status'] != 'completed') ||
            item['name'] is! String ||
            item['arguments'] is! String ||
            item['call_id'] is! String) {
          throw const FormatException('Responses 工具调用不完整，未执行命令');
        }
        calls.add(
          AgentToolCall(
            id: item['call_id'] as String,
            name: item['name'] as String,
            arguments: item['arguments'] as String,
          ),
        );
      } else if (item['type'] == 'message') {
        for (final content in item['content'] as List? ?? []) {
          if (content['type'] == 'output_text') {
            finalText.write(content['text']);
          }
          if (content['type'] == 'refusal') finalText.write(content['refusal']);
        }
      }
    }
    if (calls.length > 16 ||
        calls.map((c) => c.id).toSet().length != calls.length) {
      throw const FormatException('Responses 工具 ID 无效');
    }
    final text = finalText.isEmpty ? _text.toString() : finalText.toString();
    if (text.isEmpty && calls.isEmpty) {
      throw const FormatException('模型没有返回正文，请检查模型与输出预算');
    }
    if (text.length > maxTextCharacters) {
      throw const FormatException('回复超过所配置输出预算的保护上限');
    }
    final usage = response['usage'] as Map?;
    return AgentReply(
      text,
      calls,
      inputTokens: usage?['input_tokens'] as int?,
      outputTokens: usage?['output_tokens'] as int?,
      truncated: truncated,
      responseItems: items,
    );
  }
}
