import 'dart:convert';
import 'dart:io';
import 'ai_headers.dart';

enum AiApi { chat, responses }

Uri? aiBaseUrl(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  path = path.replaceFirst(RegExp(r'/(chat/completions|responses)$'), '');
  path = path.replaceFirst(RegExp(r'/v1$'), '');
  return uri.replace(path: path);
}

Uri? aiEndpoint(String input, AiApi api) {
  final base = aiBaseUrl(input);
  if (base == null) return null;
  return base.replace(
    path:
        '${base.path}/v1/${api == AiApi.chat ? 'chat/completions' : 'responses'}',
  );
}

Uri? chatEndpoint(String input) => aiEndpoint(input, AiApi.chat);

String? aiStreamText(String line, {AiApi api = AiApi.chat}) {
  if (!line.startsWith('data:')) return null;
  final data = line.substring(5).trim();
  if (data.isEmpty || data == '[DONE]') return null;
  final payload = jsonDecode(data);
  if (payload is! Map) return null;
  if (payload['error'] != null || payload['type'] == 'response.failed') {
    throw const FormatException('模型返回错误');
  }
  if (api == AiApi.responses) {
    return payload['type'] == 'response.output_text.delta'
        ? payload['delta'] as String?
        : null;
  }
  final choices = payload['choices'];
  if (choices is! List || choices.isEmpty || choices.first is! Map) return null;
  final delta = choices.first['delta'];
  return delta is Map && delta['content'] is String
      ? delta['content'] as String
      : null;
}

Future<List<String>> checkAiEndpoint(
  Uri uri,
  String? key, {
  String? model,
  AiApi api = AiApi.chat,
  Map<String, String> customHeaders = const {},
}) async {
  final headers = validateAiHeaders(customHeaders);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final base = aiBaseUrl(uri.toString())!;
    final target = model == null
        ? base.replace(path: '${base.path}/v1/models')
        : uri;
    final request = await client.openUrl(
      model == null ? 'GET' : 'POST',
      target,
    );
    request.followRedirects = false;
    if (model != null) request.headers.contentType = ContentType.json;
    applyAiHeaders(request.headers, key, headers);
    if (model != null) {
      request.write(
        jsonEncode({
          'model': model,
          'stream': true,
          if (api == AiApi.chat)
            'messages': [
              {'role': 'user', 'content': 'Reply with OK.'},
            ]
          else ...{
            'input': 'Reply with OK.',
            'store': false,
          },
        }),
      );
    }
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw HttpException('服务返回 HTTP ${response.statusCode}');
    }
    if (model != null) {
      var size = 0;
      await for (final line
          in response
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(const Duration(seconds: 20))) {
        size += line.length;
        if (size > 2 * 1024 * 1024) throw const FormatException('连接测试响应过大');
        if (aiStreamText(line, api: api)?.isNotEmpty == true) return const [];
      }
      throw const FormatException('未收到所选协议的流式模型回复');
    }
    final body = StringBuffer();
    await for (final text
        in response
            .transform(utf8.decoder)
            .timeout(const Duration(seconds: 15))) {
      body.write(text);
      if (body.length > 1024 * 1024) throw const FormatException('模型列表过大');
    }
    final data = (jsonDecode(body.toString()) as Map)['data'] as List;
    return data
        .whereType<Map>()
        .map((item) => item['id'])
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();
  } catch (error, stack) {
    final message = redactAiHeaderValues(error.toString(), headers);
    if (message != error.toString()) {
      Error.throwWithStackTrace(StateError(message), stack);
    }
    rethrow;
  } finally {
    client.close(force: true);
  }
}
