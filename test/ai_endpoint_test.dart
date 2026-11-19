import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/ai_endpoint.dart';

void main() {
  test('normalizes compatible base URLs and full chat endpoints', () {
    const expected = 'https://models.example.test/v1/chat/completions';
    for (final input in [
      'https://models.example.test',
      'https://models.example.test/v1/',
      expected,
    ]) {
      expect(chatEndpoint(input).toString(), expected);
    }
    expect(
      chatEndpoint('https://models.example.test/gateway/v2').toString(),
      'https://models.example.test/gateway/v2/chat/completions',
    );
  });

  test('rejects plain HTTP, embedded credentials and query parameters', () {
    for (final input in [
      'http://models.example.test/v1',
      'https://user:example@models.example.test',
      'https://models.example.test/v1?key=example',
    ]) {
      expect(chatEndpoint(input), isNull);
    }
  });

  test('recognizes only chat stream text', () {
    expect(
      aiStreamText('data: {"choices":[{"delta":{"content":"OK"}}]}'),
      'OK',
    );
    expect(
      aiStreamText('data: {"choices":[{"delta":{"role":"assistant"}}]}'),
      isNull,
    );
    expect(aiStreamText('data: [DONE]'), isNull);
  });
}
