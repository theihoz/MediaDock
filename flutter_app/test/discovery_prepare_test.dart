import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_control/main.dart';

class DiscoveryApi extends Api {
  DiscoveryApi() : super(const LocalConfig());

  final calls = <({String path, String method, Object? body})>[];

  @override
  Future<dynamic> gateway(String path,
      {String method = 'GET', Object? body}) async {
    calls.add((path: path, method: method, body: body));
    final uri = Uri.parse(path);
    if (uri.path == '/v1/discover/search') {
      final series = {
        'mediaType': 'series',
        'tvdbId': 123,
        'title': 'Test Show',
        'year': 2024,
        'overview': 'Series metadata',
        'poster': null,
        'seasons': [
          {'seasonNumber': 1},
          {'seasonNumber': 2},
        ],
      };
      return {
        'items': [
          if (uri.queryParameters['q'] == 'show') series,
          ...List.generate(
              9,
              (index) => {
                    'mediaType': 'movie',
                    'tmdbId': 603 + index,
                    'title': index == 0 ? 'The Matrix' : 'Movie $index',
                    'year': 1999,
                    'overview': 'Movie metadata',
                    'poster': null,
                  }),
          if (uri.queryParameters['q'] != 'show') series,
        ],
        'partial': false,
        'sources': {
          'movie': 'ready',
          'series': 'ready',
        },
      };
    }
    if (path == '/v1/movies/603/releases' && method == 'POST') {
      return {
        'items': [
          {
            'title': 'The Matrix 1080p',
            'quality': '1080p',
            'codec': 'H.264',
            'size': 1000,
            'seeders': 8,
            'source': 'YTS',
            'guid': 'movie-guid',
            'indexerId': 2,
          }
        ],
        'partial': true,
        'sources': {
          'radarr': {'state': 'ready', 'itemCount': 1},
          'yts': {'state': 'timeout', 'itemCount': 0},
        },
        'prepared': true,
      };
    }
    if (path == '/v1/series/123/releases' && method == 'POST') {
      final episode = body is Map && body['episodeId'] == 91;
      return {
        'items': [
          {
            'title': episode ? 'Test Show S01E02' : 'Test Show S01',
            'quality': '1080p',
            'codec': 'H.264',
            'size': 1000,
            'seeders': 5,
            'source': 'EZTV',
            'downloadToken': 'series-token',
          }
        ],
        'partial': false,
        'sources': {
          'sonarr': {'state': 'ready', 'itemCount': 1},
        },
        'prepared': true,
      };
    }
    if (path == '/v1/series/123/episodes' && method == 'POST') {
      return {
        'items': [
          {
            'episodeId': 91,
            'seasonNumber': 1,
            'episodeNumber': 2,
            'title': 'Episode Two',
          }
        ],
        'prepared': true,
      };
    }
    if (path.endsWith('/download') && method == 'POST') return {};
    throw StateError('Unexpected request: $method $path');
  }
}

class MemoryHistoryStore extends SearchHistoryStore {
  MemoryHistoryStore([this.values = const []]) : super(path: 'unused');

  List<String> values;

  @override
  Future<List<String>> load() async => List.of(values);

  @override
  Future<void> save(Iterable<String> queries) async {
    values = queries.take(10).toList();
  }

  @override
  Future<void> clear() async => values = [];
}

class FailingDiscoveryApi extends Api {
  FailingDiscoveryApi() : super(const LocalConfig());

  @override
  Future<dynamic> gateway(String path,
          {String method = 'GET', Object? body}) async =>
      throw const ApiException(502, 'provider_unavailable');
}

Future<void> enterDiscoveryQuery(WidgetTester tester, String value) async {
  await tester.enterText(find.byKey(const Key('discover-query')), value);
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('translates discovery search failures without an async leak',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiscoveryPage(api: FailingDiscoveryApi()))));
    await enterDiscoveryQuery(tester, 'matrix');

    expect(find.text('Dịch vụ nguồn tạm thời không khả dụng. Hãy thử lại.'),
        findsOneWidget);
    expect(find.textContaining('provider_unavailable'), findsNothing);
  });

  testWidgets('filters discovery, caps suggestions, and Enter shows the grid',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryHistoryStore(['matrix']);
    final api = DiscoveryApi();

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiscoveryPage(api: api, historyStore: store))));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('matrix'), findsOneWidget);

    await tester.tap(find.byKey(const Key('discover-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Phim').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discover-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trong thư viện').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('discover-year')), '1999');
    await enterDiscoveryQuery(tester, 'matrix');

    expect(
        find.byKey(const ValueKey('discover-suggestion-603')), findsOneWidget);
    expect(find.byKey(const ValueKey('discover-suggestion-611')), findsNothing);
    expect(find.text('Chi tiết phim'), findsNothing);

    await tester.tap(find.byKey(const Key('show-all-results')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('discover-results-grid')), findsOneWidget);
    expect(find.text('Chi tiết phim'), findsNothing);

    await enterDiscoveryQuery(tester, 'matrix ');
    expect(find.byKey(const Key('show-all-results')), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('discover-results-grid')), findsOneWidget);
    expect(find.text('Chi tiết phim'), findsNothing);
    expect(
        api.calls.last.path,
        allOf(
          contains('type=movie'),
          contains('year=1999'),
          contains('library=in'),
          contains('limit=50'),
        ));

    await tester.tap(find.byKey(const Key('clear-search-history')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(store.values, isEmpty);
  });

  testWidgets('movie metadata stays read-only until explicit release prepare',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = DiscoveryApi();

    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: DiscoveryPage(api: api))));
    await enterDiscoveryQuery(tester, 'matrix');
    await tester.tap(find.byKey(const ValueKey('discover-suggestion-603')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Chi tiết phim'), findsOneWidget);
    expect(find.text('Tìm bản tải'), findsOneWidget);
    expect(find.text('Không tìm thấy bản tải phù hợp'), findsNothing);
    expect(api.calls.where((call) => call.path.contains('/releases')), isEmpty);

    await tester.tap(find.byKey(const Key('prepare-movie-releases')));
    await tester.pump(const Duration(milliseconds: 100));
    final prepare =
        api.calls.singleWhere((call) => call.path == '/v1/movies/603/releases');
    expect(prepare.method, 'POST');
    expect(find.text('The Matrix 1080p'), findsOneWidget);
    expect(find.textContaining('radarr'), findsOneWidget);
    expect(find.textContaining('Một số nguồn'), findsOneWidget);
  });

  testWidgets('TV prepares a season, then loads episodes only on demand',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = DiscoveryApi();

    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: DiscoveryPage(api: api))));
    await enterDiscoveryQuery(tester, 'show');
    await tester.tap(find.byKey(const ValueKey('discover-suggestion-123')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Chi tiết TV Show'), findsOneWidget);
    expect(find.text('Mùa 1'), findsWidgets);
    expect(api.calls.where((call) => call.path.contains('/episodes')), isEmpty);
    expect(api.calls.where((call) => call.path.contains('/releases')), isEmpty);

    await tester.tap(find.byKey(const Key('prepare-season-releases')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
        api.calls
            .singleWhere((call) => call.path == '/v1/series/123/releases')
            .body,
        {'seasonNumber': 1});

    await tester.tap(find.byKey(const Key('choose-episodes')));
    await tester.pump(const Duration(milliseconds: 100));
    final episodes =
        api.calls.singleWhere((call) => call.path == '/v1/series/123/episodes');
    expect(episodes.method, 'POST');
    expect(find.textContaining('S01E02'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('prepare-episode-91')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
        api.calls
            .where((call) => call.path == '/v1/series/123/releases')
            .last
            .body,
        {'episodeId': 91});
    expect(find.text('Test Show S01E02'), findsOneWidget);
  });
}
