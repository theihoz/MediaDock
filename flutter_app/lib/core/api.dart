part of '../media_control.dart';

class LocalConfig {
  const LocalConfig(
      {this.gateway = 'http://localhost:3000',
      this.controller = 'http://127.0.0.1:3210',
      this.token = 'media-control-local',
      this.controllerLauncher = '',
      this.jellyfinBaseUrl = 'http://localhost:8096'});
  final String gateway, controller, token, controllerLauncher, jellyfinBaseUrl;
  static LocalConfig parse(String text) {
    final normalized = text.startsWith('\uFEFF') ? text.substring(1) : text;
    final data = jsonDecode(normalized);
    return LocalConfig(
      gateway: data['gateway'] ?? 'http://localhost:3000',
      controller: data['controller'] ?? 'http://127.0.0.1:3210',
      token: data['token'] ?? 'media-control-local',
      controllerLauncher: data['controllerLauncher'] ?? '',
      jellyfinBaseUrl: data['jellyfinBaseUrl'] ?? 'http://localhost:8096',
    );
  }

  static LocalConfig load() {
    try {
      final base = Platform.environment['LOCALAPPDATA'];
      return parse(File('$base\\MediaControl\\config.json').readAsStringSync());
    } catch (_) {
      return const LocalConfig();
    }
  }
}

class ApiException implements Exception {
  const ApiException(this.statusCode, this.code);
  final int statusCode;
  final String code;

  @override
  String toString() => code;
}

class DownloadEvent {
  const DownloadEvent(this.type, this.data);
  final String type;
  final Map<String, dynamic> data;
}

class Api {
  Api(this.config);
  final LocalConfig config;
  Future<dynamic> request(String base, String path,
      {String method = 'GET', Object? body}) async {
    final headers = <String, String>{'content-type': 'application/json'};
    if (base == config.controller) {
      headers['authorization'] = 'Bearer ${config.token}';
    }
    final request = http.Request(method, Uri.parse('$base$path'))
      ..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    final response = await request.send();
    final text = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
          response.statusCode, _responseError(response.statusCode, text));
    }
    return text.isEmpty ? null : jsonDecode(text);
  }

  Future<dynamic> gateway(String path, {String method = 'GET', Object? body}) =>
      request(config.gateway, path, method: method, body: body);
  Future<dynamic> host(String path, {String method = 'GET'}) =>
      request(config.controller, path, method: method);

  Stream<DownloadEvent> downloadEvents() async* {
    final client = http.Client();
    try {
      final request = http.Request(
          'GET', Uri.parse('${config.gateway}/v1/downloads/events'))
        ..headers['accept'] = 'text/event-stream';
      final response =
          await client.send(request).timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final text = await response.stream.bytesToString();
        throw ApiException(
            response.statusCode, _responseError(response.statusCode, text));
      }
      String? event;
      final data = <String>[];
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (line.isEmpty) {
          final parsed = _downloadEvent(event, data);
          if (parsed != null) yield parsed;
          event = null;
          data.clear();
        } else if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          data.add(line.substring(5).trimLeft());
        }
      }
      final parsed = _downloadEvent(event, data);
      if (parsed != null) yield parsed;
    } finally {
      client.close();
    }
  }
}

String _responseError(int statusCode, String text) {
  const stableCodes = {
    'invalid_request',
    'request_too_large',
    'not_found',
    'conflict',
    'provider_unavailable',
    'upstream_timeout',
  };
  try {
    final value = jsonDecode(text);
    if (value is Map && stableCodes.contains(value['error'])) {
      return value['error'];
    }
  } catch (_) {}
  return switch (statusCode) {
    400 => 'invalid_request',
    404 => 'not_found',
    409 => 'conflict',
    413 => 'request_too_large',
    504 => 'upstream_timeout',
    _ => 'provider_unavailable',
  };
}

DownloadEvent? _downloadEvent(String? event, List<String> lines) {
  if (event == null || lines.isEmpty) return null;
  final value = jsonDecode(lines.join('\n'));
  if (value is! Map) throw const FormatException('Invalid SSE payload');
  return DownloadEvent(event, Map<String, dynamic>.from(value));
}
