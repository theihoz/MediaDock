import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class ApiClient {
  ApiClient({
    http.Client? client,
    FlutterSecureStorage? storage,
    this.baseUrl = 'http://127.0.0.1:11444/v1',
  }) : _client = client ?? http.Client(),
       _storage = storage ?? const FlutterSecureStorage();

  final http.Client _client;
  final FlutterSecureStorage _storage;
  final String baseUrl;
  static const _tokenKey = 'media_control_token';

  Future<String> _token() async {
    final saved = await _storage.read(key: _tokenKey);
    if (saved != null && saved.isNotEmpty) return saved;
    final result = await Process.run('wsl.exe', [
      '-d',
      'MediaServer',
      '--',
      'cat',
      '/srv/media-stack/secrets/media-control.token',
    ]);
    if (result.exitCode != 0) {
      throw const SocketException('MediaServer chưa chạy');
    }
    final token = result.stdout.toString().trim();
    if (token.isEmpty) throw const FormatException('Control token trống');
    await _storage.write(key: _tokenKey, value: token);
    return token;
  }

  Future<Map<String, String>> _headers() async => {
    'Authorization': 'Bearer ${await _token()}',
    'Content-Type': 'application/json',
  };

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    return _decode(await _client.get(uri, headers: await _headers()));
  }

  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    return _decode(
      await _client.post(
        Uri.parse('$baseUrl$path'),
        headers: await _headers(),
        body: jsonEncode(body ?? const <String, dynamic>{}),
      ),
    );
  }

  Future<Map<String, dynamic>> deleteConfirmed(String path) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = await _headers();
    final challenge = await _client.delete(uri, headers: headers);
    if (challenge.statusCode != 409) return _decode(challenge);
    final data = jsonDecode(challenge.body) as Map<String, dynamic>;
    final confirmation =
        (data['detail'] as Map<String, dynamic>)['confirmation_token']
            as String;
    return _decode(
      await _client.delete(
        uri,
        headers: {...headers, 'X-Confirmation-Token': confirmation},
      ),
    );
  }

  Map<String, dynamic> _decode(http.Response response) {
    final value = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Backend HTTP ${response.statusCode}');
    }
    return value;
  }
}
