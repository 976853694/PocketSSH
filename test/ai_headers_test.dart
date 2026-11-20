import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/agent_controller.dart';
import 'package:pocket_ssh/core/agent_transport.dart';
import 'package:pocket_ssh/core/ai_endpoint.dart';
import 'package:pocket_ssh/core/ai_headers.dart';

void main() {
  test('header names are validated without including values in errors', () {
    expect(
      validateAiHeaders({
        ' X-Channel ': 'fixture-value',
        'Authorization': 'Custom fixture-auth',
      }),
      {'X-Channel': 'fixture-value', 'Authorization': 'Custom fixture-auth'},
    );
    for (final headers in [
      {'': 'fixture-value'},
      {'Bad Name': 'fixture-value'},
      {'X-Test': 'one', 'x-test': 'two'},
      {'X-Test': 'fixture-value\r\nInjected: yes'},
      {'Host': 'fixture-value'},
      {'Content-Length': '999'},
    ]) {
      try {
        validateAiHeaders(headers);
        fail('Expected invalid headers');
      } on FormatException catch (error) {
        expect(error.toString(), isNot(contains('fixture-value')));
      }
    }
  });

  for (final api in AiApi.values) {
    test(
      '${api.name} applies custom headers to chat, summaries, connection tests and models',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final received = <String>[];
        final subscription = server.listen((request) async {
          expect(request.headers.value('x-channel'), 'fixture-route');
          expect(request.headers.value('authorization'), 'Custom fixture-auth');
          expect(request.headers.value('user-agent'), 'PocketSSH-fixture');
          received.add('${request.method} ${request.uri.path}');
          if (request.method == 'GET') {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'data': [
                  {'id': 'fixture-model'},
                ],
              }),
            );
          } else {
            final body =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            expect(body['model'], 'fixture-model');
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            );
            void event(Map payload) =>
                request.response.write('data: ${jsonEncode(payload)}\n\n');
            if (api == AiApi.chat) {
              event({
                'choices': [
                  {
                    'delta': {'content': 'OK'},
                    'finish_reason': 'stop',
                  },
                ],
              });
              request.response.write('data: [DONE]\n\n');
            } else {
              event({'type': 'response.output_text.delta', 'delta': 'OK'});
              event({
                'type': 'response.completed',
                'response': {
                  'status': 'completed',
                  'output': [
                    {
                      'type': 'message',
                      'role': 'assistant',
                      'content': [
                        {'type': 'output_text', 'text': 'OK'},
                      ],
                    },
                  ],
                },
              });
            }
          }
          await request.response.close();
        });
        addTearDown(subscription.cancel);
        final website = 'http://127.0.0.1:${server.port}';
        final endpoint = aiEndpoint(website, api)!;
        const headers = {
          'X-Channel': 'fixture-route',
          'Authorization': 'Custom fixture-auth',
          'User-Agent': 'PocketSSH-fixture',
        };
        final transport = AgentTransport(
          endpoint: endpoint,
          model: 'fixture-model',
          apiKey: 'default-fixture-key',
          api: api,
          customHeaders: headers,
        );
        final result = await transport.request(
          [
            {'role': 'user', 'content': 'hello'},
          ],
          AgentCancellation(),
          (_) {},
        );
        expect(result.text, 'OK');
        await transport.request(
          [
            {'role': 'user', 'content': 'summarize'},
          ],
          AgentCancellation(),
          (_) {},
          toolsEnabled: false,
        );
        await checkAiEndpoint(
          endpoint,
          'default-fixture-key',
          api: api,
          model: 'fixture-model',
          customHeaders: headers,
        );
        expect(
          await checkAiEndpoint(
            endpoint,
            'default-fixture-key',
            api: api,
            customHeaders: headers,
          ),
          ['fixture-model'],
        );
        expect(received.length, 4);
        expect(received.last, 'GET /v1/models');
      },
    );
  }

  test(
    'default bearer remains when custom headers do not override it',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final subscription = server.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer fixture-key');
        expect(request.headers.value('x-channel'), 'fixture-route');
        request.response.write('{"data":[]}');
        await request.response.close();
      });
      addTearDown(subscription.cancel);
      await checkAiEndpoint(
        aiEndpoint('http://127.0.0.1:${server.port}', AiApi.chat)!,
        'fixture-key',
        customHeaders: {'X-Channel': 'fixture-route'},
      );
    },
  );

  test('server errors do not expose configured custom header values', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final subscription = server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 403;
      request.response.write('Rejected fixture-sensitive-header');
      await request.response.close();
    });
    addTearDown(subscription.cancel);
    final transport = AgentTransport(
      endpoint: aiEndpoint('http://127.0.0.1:${server.port}', AiApi.chat)!,
      model: 'fixture',
      apiKey: null,
      customHeaders: {'X-Api-Key': 'fixture-sensitive-header'},
    );
    try {
      await transport.request(
        [
          {'role': 'user', 'content': 'hello'},
        ],
        AgentCancellation(),
        (_) {},
      );
      fail('Expected HTTP failure');
    } catch (error) {
      expect(error.toString(), contains('403'));
      expect(error.toString(), isNot(contains('fixture-sensitive-header')));
      expect(error.toString(), contains('请求头值已隐藏'));
    }
  });
}
