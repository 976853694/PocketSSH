import 'dart:convert';
import 'dart:io';

Uri? chatEndpoint(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  if (path.isEmpty) path = '/v1';
  if (!path.endsWith('/chat/completions')) path = '$path/chat/completions';
  return uri.replace(path: path);
}

String? aiStreamText(String line) {
  if (!line.startsWith('data:')) return null;
  final data = line.substring(5).trim();
  if (data.isEmpty || data == '[DONE]') return null;
  final payload = jsonDecode(data);
  if (payload is! Map) return null;
  final choices = payload['choices'];
  if (choices is! List || choices.isEmpty || choices.first is! Map) return null;
  final delta = choices.first['delta'];
  final text = delta is Map ? delta['content'] : null;
  return text is String ? text : null;
}

Future<List<String>> checkAiEndpoint(
  Uri uri,
  String? key, {
  String? model,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final target = model == null
        ? uri.replace(
            path: uri.path.replaceFirst(
              RegExp(r'/chat/completions$'),
              '/models',
            ),
          )
        : uri;
    final request = await client.openUrl(
      model == null ? 'GET' : 'POST',
      target,
    );
    request.followRedirects = false;
    if (key != null && key.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
    }
    if (model != null) {
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'model': model,
          'stream': true,
          'messages': [
            {'role': 'user', 'content': 'Reply with OK.'},
          ],
        }),
      );
    }
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw HttpException('服务返回 HTTP ${response.statusCode}');
    }
    if (model != null) {
      await for (final line
          in response
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(const Duration(seconds: 15))) {
        if (aiStreamText(line)?.isNotEmpty == true) return const [];
        if (line.trim() == 'data: [DONE]') break;
      }
      throw const FormatException('未收到流式模型回复');
    }
    final body = StringBuffer();
    await for (final text
        in response
            .transform(utf8.decoder)
            .timeout(const Duration(seconds: 15))) {
      body.write(text);
      if (body.length > 1024 * 1024) throw const FormatException('服务响应过大');
    }
    final data = (jsonDecode(body.toString()) as Map)['data'] as List;
    return data
        .whereType<Map>()
        .map((item) => item['id'])
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();
  } finally {
    client.close(force: true);
  }
}
