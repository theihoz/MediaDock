import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_control/main.dart';

void main() {
  test('LocalConfig defaults and parses the Jellyfin base URL', () {
    expect(const LocalConfig().jellyfinBaseUrl, 'http://localhost:8096');
    expect(
      LocalConfig.parse('{"jellyfinBaseUrl":"http://media-pc:8096"}')
          .jellyfinBaseUrl,
      'http://media-pc:8096',
    );
  });

  test('Api exposes stable errors without upstream response bodies', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.badGateway
        ..headers.contentType = ContentType.html
        ..write('<html>private provider exception</html>');
      await request.response.close();
    });
    final api = Api(LocalConfig(
        gateway: 'http://${server.address.address}:${server.port}'));

    await expectLater(
      api.gateway('/failure'),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'statusCode', 502)
            .having((error) => error.code, 'code', 'provider_unavailable')
            .having(
                (error) => '$error'.contains('private'), 'leaks body', false),
      ),
    );
    expect(
      vietnameseError(const ApiException(504, 'upstream_timeout')),
      'Dịch vụ nguồn phản hồi quá lâu. Hãy thử lại.',
    );
  });

  test('Api parses snapshot and error SSE events', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('text', 'event-stream')
        ..write('retry: 3000\n\n')
        ..write(': heartbeat\n\n')
        ..write('event: snapshot\n')
        ..write('data: {"items":[{"hash":"abc"}],"generatedAt":"now"}\n\n')
        ..write('event: error\n')
        ..write('data: {"error":"provider_unavailable"}\n\n');
      await request.response.close();
    });
    final api = Api(LocalConfig(
        gateway: 'http://${server.address.address}:${server.port}'));

    final events = await api.downloadEvents().toList();
    expect(events.map((event) => event.type), ['snapshot', 'error']);
    expect(events.first.data['items'].single['hash'], 'abc');
    expect(events.last.data, {'error': 'provider_unavailable'});
  });

  test('SearchHistoryStore writes at most ten unique queries atomically',
      () async {
    final directory = await Directory.systemTemp.createTemp('media-history-');
    addTearDown(() async {
      for (var attempt = 0; attempt < 5; attempt++) {
        try {
          await directory.delete(recursive: true);
          return;
        } on FileSystemException {
          if (attempt == 4) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
    });
    final path =
        '${directory.path}${Platform.pathSeparator}search-history.json';
    final store = SearchHistoryStore(path: path);

    await store.save([
      ...List.generate(12, (index) => 'query $index'),
      'QUERY 1',
    ]);
    expect(await store.load(), List.generate(10, (index) => 'query $index'));
    expect(File('$path.tmp').existsSync(), false);

    await store.save(['new query']);
    expect(jsonDecode(await File(path).readAsString()), ['new query']);
    await store.clear();
    expect(await store.load(), isEmpty);
  });
}
