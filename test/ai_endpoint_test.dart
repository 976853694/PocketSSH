import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/ai_endpoint.dart';

void main() {
  test('website alone selects Chat or Responses without repeated suffixes', () {
    for (final scheme in ['http', 'https']) {
      for (final suffix in [
        '',
        '/',
        '/v1',
        '/v1/',
        '/v1/chat/completions',
        '/v1/responses/',
      ]) {
        final base = '$scheme://models.example.test:8080';
        expect(
          aiEndpoint('$base$suffix', AiApi.chat).toString(),
          '$base/v1/chat/completions',
        );
        expect(
          aiEndpoint('$base$suffix', AiApi.responses).toString(),
          '$base/v1/responses',
        );
        expect(aiBaseUrl('$base$suffix').toString(), base);
      }
    }
    expect(
      aiEndpoint('http://127.0.0.1:3000/proxy/v1', AiApi.responses).toString(),
      'http://127.0.0.1:3000/proxy/v1/responses',
    );
  });
  test('invalid schemes credentials queries and fragments are rejected', () {
    for (final input in [
      'ftp://host',
      'https://user:key@host',
      'https://host?key=example',
      'https://host#fragment',
      '',
    ]) {
      expect(aiBaseUrl(input), isNull);
    }
  });
  test('connection test recognizes the manually selected protocol', () {
    expect(
      aiStreamText('data: {"choices":[{"delta":{"content":"OK"}}]}'),
      'OK',
    );
    expect(
      aiStreamText(
        'data: {"type":"response.output_text.delta","delta":"OK"}',
        api: AiApi.responses,
      ),
      'OK',
    );
    expect(aiStreamText('data: [DONE]'), isNull);
  });
}
