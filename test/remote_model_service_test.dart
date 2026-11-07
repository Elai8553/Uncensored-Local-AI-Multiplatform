import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../lib/services/remote_model_service.dart';

class _MemoryCredentialStore implements RemoteCredentialStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    this.value = value;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}

class _FakeClient extends http.BaseClient {
  _FakeClient(this.respond);

  final Future<http.StreamedResponse> Function(http.BaseRequest request) respond;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => respond(request);
}

http.StreamedResponse _streamedResponse(
  String body, {
  int statusCode = 200,
  String contentType = 'application/json',
}) => http.StreamedResponse(
  Stream<List<int>>.value(utf8.encode(body)),
  statusCode,
  headers: {'content-type': contentType},
);

void main() {
  group('remote endpoint validation', () {
    test('accepts HTTPS hosts and appends the v1 path once', () {
      expect(
        RemoteModelService.endpointFor(
          'https://models.example.test/api/v1/',
          'chat/completions',
        ).toString(),
        'https://models.example.test/api/v1/chat/completions',
      );
      expect(
        RemoteModelService.endpointFor(
          'https://models.example.test',
          'models',
        ).toString(),
        'https://models.example.test/v1/models',
      );
    });

    test('allows HTTP only for localhost and loopback development hosts', () {
      expect(
        RemoteModelService.validateBaseUrl('http://localhost:8080/v1').host,
        'localhost',
      );
      expect(
        RemoteModelService.validateBaseUrl('http://127.0.0.1:8080/v1').host,
        '127.0.0.1',
      );
      expect(
        () => RemoteModelService.validateBaseUrl('http://192.168.1.20:8080/v1'),
        throwsFormatException,
      );
      expect(
        () => RemoteModelService.validateBaseUrl('http://models.example.test'),
        throwsFormatException,
      );
    });

    test('rejects credentials and query parameters in the base URL', () {
      expect(
        () => RemoteModelService.validateBaseUrl(
          'https://user:password@models.example.test/v1',
        ),
        throwsFormatException,
      );
      expect(
        () => RemoteModelService.validateBaseUrl(
          'https://models.example.test/v1?token=secret',
        ),
        throwsFormatException,
      );
    });
  });

  test('formats the OpenAI-compatible request with conversation history', () {
    final body = RemoteModelService.buildChatCompletionBody(
      modelId: 'my-vps-model',
      systemPrompt: '  Follow the existing conversation.  ',
      temperature: 0.4,
      messages: [
        {'role': 'user', 'content': 'Earlier question'},
        {'role': 'assistant', 'content': 'Earlier answer'},
        {'role': 'user', 'content': 'Current question'},
      ],
    );

    expect(body['model'], 'my-vps-model');
    expect(body['temperature'], 0.4);
    expect(body['stream'], isTrue);
    expect(body['messages'], [
      {'role': 'system', 'content': 'Follow the existing conversation.'},
      {'role': 'user', 'content': 'Earlier question'},
      {'role': 'assistant', 'content': 'Earlier answer'},
      {'role': 'user', 'content': 'Current question'},
    ]);
  });

  test('streams SSE deltas and sends the bearer key only in the header', () async {
    final credentials = _MemoryCredentialStore()..value = 'test-secret';
    http.BaseRequest? capturedRequest;
    final client = _FakeClient((request) async {
      capturedRequest = request;
      return _streamedResponse(
        'data: {"choices":[{"delta":{"content":"Hello"}}]}\n'
        'data: {"choices":[{"delta":{"content":" world"}}]}\n'
        'data: [DONE]\n',
        contentType: 'text/event-stream',
      );
    });
    final service = RemoteModelService(
      client: client,
      credentialStore: credentials,
    );

    final tokens = await service
        .generate(
          baseUrl: 'https://models.example.test/v1',
          modelId: 'my-vps-model',
          messages: [
            {'role': 'user', 'content': 'Hi'},
          ],
          systemPrompt: '',
          temperature: 0.7,
        )
        .toList();

    expect(tokens.join(), 'Hello world');
    expect(capturedRequest, isA<http.Request>());
    final request = capturedRequest! as http.Request;
    expect(request.url.path, '/v1/chat/completions');
    expect(request.headers['Authorization'], 'Bearer test-secret');
    expect(request.body, isNot(contains('test-secret')));
    expect(jsonDecode(request.body)['model'], 'my-vps-model');
  });

  test('tests the configured model without changing chat history or prompt', () async {
    const secret = 'test-secret';
    final credentials = _MemoryCredentialStore()..value = secret;
    http.BaseRequest? capturedRequest;
    final service = RemoteModelService(
      client: _FakeClient((request) async {
        capturedRequest = request;
        return _streamedResponse(
          jsonEncode({
            'choices': [
              {'message': {'role': 'assistant', 'content': 'O'}},
            ],
          }),
        );
      }),
      credentialStore: credentials,
    );

    await service.testConnection(
      baseUrl: 'https://models.example.test',
      modelId: 'my-vps-model',
    );

    final request = capturedRequest! as http.Request;
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect(request.method, 'POST');
    expect(request.url.path, '/v1/chat/completions');
    expect(request.headers['Authorization'], 'Bearer $secret');
    expect(body['model'], 'my-vps-model');
    expect(body['max_tokens'], 1);
    expect(body['stream'], isFalse);
    expect(body['messages'], [
      {'role': 'user', 'content': 'Connection test. Reply with OK.'},
    ]);
    expect(request.body, isNot(contains(secret)));
    expect(credentials.value, secret);
  });

  test('surfaces remote HTTP errors without exposing the saved key', () async {
    const secret = 'test-secret';
    final service = RemoteModelService(
      client: _FakeClient((_) async => _streamedResponse(
        jsonEncode({'error': {'message': 'Invalid key: $secret'}}),
        statusCode: 401,
      )),
      credentialStore: _MemoryCredentialStore()..value = secret,
    );

    await expectLater(
      service
          .generate(
            baseUrl: 'https://models.example.test/v1',
            modelId: 'my-vps-model',
            messages: const [],
            systemPrompt: '',
            temperature: 0.7,
          )
          .toList(),
      throwsA(
        isA<RemoteModelException>()
            .having((error) => error.statusCode, 'statusCode', 401)
            .having((error) => error.message, 'message', contains('HTTP 401'))
            .having((error) => error.message, 'message', contains('[redacted]'))
            .having((error) => error.message, 'message', isNot(contains(secret))),
      ),
    );
  });
}
