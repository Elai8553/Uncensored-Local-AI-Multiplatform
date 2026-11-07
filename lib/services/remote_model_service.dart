import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

abstract interface class RemoteCredentialStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

class FlutterSecureRemoteCredentialStore implements RemoteCredentialStore {
  FlutterSecureRemoteCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ??
          (Platform.isMacOS
              ? FlutterSecureStorage(
                  mOptions: const MacOsOptions(
                    usesDataProtectionKeychain: false,
                  ),
                )
              : FlutterSecureStorage());

  static const _key = 'remote_model_api_key';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

class RemoteModelException implements Exception {
  const RemoteModelException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class RemoteModelService extends GetxService {
  RemoteModelService({
    http.Client? client,
    RemoteCredentialStore? credentialStore,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _credentialStore = credentialStore ?? FlutterSecureRemoteCredentialStore();

  final http.Client _client;
  final bool _ownsClient;
  final RemoteCredentialStore _credentialStore;
  Completer<void>? _activeAbort;

  Future<void> saveApiKey(String value) => _credentialStore.write(value);

  Future<void> clearApiKey() => _credentialStore.delete();

  Future<bool> hasApiKey() async =>
      (await _credentialStore.read())?.isNotEmpty ?? false;

  static Uri validateBaseUrl(String value) {
    final trimmed = value.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.isAbsolute || uri.host.isEmpty) {
      throw const FormatException('Enter a valid remote base URL.');
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw const FormatException(
        'The base URL cannot contain credentials, a query, or a fragment.',
      );
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' &&
        !(scheme == 'http' && _isLocalDevelopmentHost(uri.host))) {
      throw const FormatException(
        'Remote hosts must use HTTPS. HTTP is allowed only for localhost or a loopback address during local development.',
      );
    }

    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (path.split('/').any((segment) => segment == '.' || segment == '..')) {
      throw const FormatException('The base URL path is invalid.');
    }
    return uri.replace(path: path);
  }

  static bool _isLocalDevelopmentHost(String host) {
    final normalized = host.toLowerCase();
    if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
      return true;
    }
    return InternetAddress.tryParse(normalized)?.isLoopback ?? false;
  }

  static Uri endpointFor(String baseUrl, String endpoint) {
    final base = validateBaseUrl(baseUrl);
    final basePath = base.path.replaceFirst(RegExp(r'/+$'), '');
    final versionedPath = basePath.endsWith('/v1')
        ? basePath
        : '$basePath/v1';
    return base.replace(path: '$versionedPath/$endpoint');
  }

  static Map<String, dynamic> buildChatCompletionBody({
    required String modelId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    required double temperature,
  }) {
    final prompt = systemPrompt.trim();
    return {
      'model': modelId,
      'messages': [
        if (prompt.isNotEmpty) {'role': 'system', 'content': prompt},
        ...messages,
      ],
      'temperature': temperature,
      'stream': true,
    };
  }

  static String? parseSseDataLine(String line, {String? secret}) {
    if (!line.startsWith('data:')) return null;
    final data = line.substring(5).trim();
    if (data.isEmpty || data == '[DONE]') return null;

    final decoded = _decodeJson(data);
    if (decoded is! Map<String, dynamic>) {
      throw const RemoteModelException(
        'Remote server sent an invalid streaming response.',
      );
    }
    if (decoded['error'] != null) {
      throw RemoteModelException(
        _redactSecret(_remoteErrorText(decoded['error']), secret),
      );
    }

    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      return null;
    }
    final delta = choices.first['delta'];
    final content = delta is Map ? delta['content'] : null;
    return content is String ? content : null;
  }

  static RemoteModelException responseError(
    int statusCode,
    String body, {
    String? secret,
  }) {
    final decoded = _decodeJson(body);
    final rawError = decoded is Map<String, dynamic> ? decoded['error'] : null;
    var message = rawError == null
        ? 'Remote server returned HTTP $statusCode.'
        : _remoteErrorText(rawError);
    message = _redactSecret(message, secret);
    if (message.length > 400) message = '${message.substring(0, 397)}...';
    return RemoteModelException(message, statusCode: statusCode);
  }

  Future<List<String>> listModels(String baseUrl, {String? apiKey}) async {
    final secret = apiKey ?? await _credentialStore.read();
    final request = http.Request('GET', endpointFor(baseUrl, 'models'));
    request.headers['Accept'] = 'application/json';
    if (secret != null && secret.trim().isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${secret.trim()}';
    }

    final response = await _client.send(request);
    final result = await http.Response.fromStream(response);
    if (result.statusCode < 200 || result.statusCode >= 300) {
      throw responseError(result.statusCode, result.body, secret: secret);
    }

    final decoded = _decodeJson(result.body);
    if (decoded is Map<String, dynamic> && decoded['error'] != null) {
      throw RemoteModelException(
        _redactSecret(_remoteErrorText(decoded['error']), secret),
      );
    }
    final data = decoded is Map<String, dynamic> ? decoded['data'] : null;
    if (data is! List) {
      throw const RemoteModelException(
        'The remote server did not return a model list. Enter the model ID manually.',
      );
    }
    return data
        .whereType<Map>()
        .map((item) => item['id'])
        .whereType<String>()
        .toList(growable: false);
  }

  Stream<String> generate({
    required String baseUrl,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    required double temperature,
  }) async* {
    if (modelId.trim().isEmpty) {
      throw const FormatException('Enter a remote model ID in Settings.');
    }
    final endpoint = endpointFor(baseUrl, 'chat/completions');
    final abort = Completer<void>();
    _activeAbort = abort;

    try {
      final secret = await _credentialStore.read();
      if (abort.isCompleted) return;
      final request = http.AbortableRequest(
        'POST',
        endpoint,
        abortTrigger: abort.future,
      );
      request.headers.addAll({
        'Accept': 'text/event-stream, application/json',
        'Content-Type': 'application/json',
      });
      if (secret != null && secret.trim().isNotEmpty) {
        request.headers['Authorization'] = 'Bearer ${secret.trim()}';
      }
      request.body = jsonEncode(
        buildChatCompletionBody(
          modelId: modelId.trim(),
          messages: messages,
          systemPrompt: systemPrompt,
          temperature: temperature,
        ),
      );

      final response = await _client.send(request);
      if (abort.isCompleted) return;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errorResponse = await http.Response.fromStream(response);
        throw responseError(
          errorResponse.statusCode,
          errorResponse.body,
          secret: secret,
        );
      }

      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      if (contentType.contains('application/json')) {
        final result = await http.Response.fromStream(response);
        final decoded = _decodeJson(result.body);
        if (decoded is Map<String, dynamic> && decoded['error'] != null) {
          throw RemoteModelException(
            _redactSecret(_remoteErrorText(decoded['error']), secret),
            statusCode: result.statusCode,
          );
        }
        final choices = decoded is Map<String, dynamic>
            ? decoded['choices']
            : null;
        final choice = choices is List && choices.isNotEmpty
            ? choices.first
            : null;
        final message = choice is Map ? choice['message'] : null;
        final content = message is Map ? message['content'] : null;
        if (content is String && content.isNotEmpty) yield content;
        return;
      }

      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (abort.isCompleted) break;
        final token = parseSseDataLine(line, secret: secret);
        if (token != null && token.isNotEmpty) yield token;
        if (line.trim() == 'data: [DONE]') break;
      }
    } on http.RequestAbortedException {
      if (!abort.isCompleted) rethrow;
    } finally {
      if (identical(_activeAbort, abort)) _activeAbort = null;
    }
  }

  void cancelGeneration() {
    final abort = _activeAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  @override
  void onClose() {
    cancelGeneration();
    if (_ownsClient) _client.close();
    super.onClose();
  }
}

Object? _decodeJson(String value) {
  try {
    return jsonDecode(value);
  } on FormatException {
    return null;
  }
}

String _redactSecret(String message, String? secret) {
  if (secret == null || secret.isEmpty) return message;
  return message.replaceAll(secret, '[redacted]');
}

String _remoteErrorText(Object? error) {
  if (error is Map) {
    final message = error['message'];
    if (message is String && message.trim().isNotEmpty) return message.trim();
  }
  if (error is String && error.trim().isNotEmpty) return error.trim();
  return 'The remote server returned an error.';
}
