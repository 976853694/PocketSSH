import 'dart:io';

Map<String, String> validateAiHeaders(Map<String, String> input) {
  final headers = <String, String>{};
  final names = <String>{};
  const managed = {
    'host',
    'content-length',
    'transfer-encoding',
    'connection',
    'upgrade',
    'expect',
    'trailer',
    'te',
  };
  final validName = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
  for (final entry in input.entries) {
    final name = entry.key.trim();
    if (!validName.hasMatch(name)) {
      throw const FormatException('请求头名称只能包含 HTTP 字段名允许的字符');
    }
    if (managed.contains(name.toLowerCase())) {
      throw const FormatException('Host、连接及报文长度类请求头由程序管理');
    }
    if (!names.add(name.toLowerCase())) {
      throw const FormatException('请求头名称不能重复（不区分大小写）');
    }
    if (entry.value.codeUnits.any(
      (unit) => unit < 32 || unit > 255 || unit == 127,
    )) {
      throw const FormatException('请求头值不能包含换行、控制字符或非 Latin-1 字符');
    }
    headers[name] = entry.value;
  }
  return headers;
}

void applyAiHeaders(
  HttpHeaders headers,
  String? apiKey,
  Map<String, String> customHeaders,
) {
  final validated = validateAiHeaders(customHeaders);
  if (apiKey?.isNotEmpty == true) {
    headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
  }
  for (final entry in validated.entries) {
    headers.set(entry.key, entry.value);
  }
}

String redactAiHeaderValues(String text, Map<String, String> headers) {
  final values = headers.values.where((value) => value.isNotEmpty).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final value in values) {
    text = text.replaceAll(value, '[请求头值已隐藏]');
  }
  return text;
}
