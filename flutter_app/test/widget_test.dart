import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_control/controller_bootstrap.dart';
import 'package:media_control/main.dart';

class FakeBootstrapper extends ControllerBootstrapper {
  FakeBootstrapper(this.result)
      : super(probe: () async => false, launch: () async {});
  final Future<ControllerStartupResult> result;
  @override
  Future<ControllerStartupResult> ensureReady() => result;
}

class FakeMovieApi extends Api {
  FakeMovieApi() : super(const LocalConfig());
  @override
  Future<dynamic> gateway(String path, {String method = 'GET', Object? body}) async {
    if (path == '/v1/movies/trending') {
      return {
        'items': [{'tmdbId': 603, 'title': 'The Matrix', 'year': 1999, 'overview': 'Trending movie', 'poster': null, 'rating': 8.2}],
        'source': 'live',
        'stale': false,
      };
    }
    if (path.startsWith('/v1/movies/search')) {
      if (path.contains('Dune')) {
        return [{'tmdbId': 438631, 'title': 'Dune', 'year': 2021, 'overview': 'Search result', 'poster': null}];
      }
      return [{'tmdbId': 603, 'title': 'The Matrix', 'year': 1999, 'overview': 'Test movie', 'poster': null}];
    }
    if (path == '/v1/movies/603/releases' || path == '/v1/movies/438631/releases') return [];
    throw StateError('Unexpected request: $path');
  }
  @override
  Future<dynamic> host(String path, {String method = 'GET'}) async => {'state': 'off', 'services': []};
}

class CountingApi extends Api {
  CountingApi() : super(const LocalConfig());
  int gatewayCalls = 0;
  @override
  Future<dynamic> host(String path, {String method = 'GET'}) async => {'state': 'off', 'services': []};
  @override
  Future<dynamic> gateway(String path, {String method = 'GET', Object? body}) async {
    gatewayCalls++;
    return [];
  }
}

void main() {
  testWidgets('shows readable Vietnamese media navigation', (tester) async {
    await tester.pumpWidget(MediaControlApp(
      api: FakeMovieApi(),
      bootstrapper: FakeBootstrapper(Future.value(ControllerStartupResult.ready)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Media Control'), findsOneWidget);
    expect(find.text('Tổng quan'), findsWidgets);
    expect(find.text('Tìm phim'), findsOneWidget);
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('Phụ đề'), findsOneWidget);
    expect(find.text('Thư viện'), findsOneWidget);
    expect(find.text('Services'), findsOneWidget);
    expect(find.text('Cài đặt'), findsOneWidget);
    await tester.tap(find.text('Phụ đề').first);
    await tester.pump();
    expect(find.text('Cho phép YIFY Direct fallback'), findsOneWidget);
    expect(find.text('Tìm qua Bazarr'), findsOneWidget);
    expect(find.text('Tìm trực tiếp YIFY'), findsOneWidget);
  });

  testWidgets('clicking a movie always opens its detail even with no releases', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MovieSearchPage(api: FakeMovieApi()))));
    await tester.enterText(find.byType(TextField), 'Matrix');
    await tester.tap(find.text('Tìm'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The Matrix (1999)'));
    await tester.pumpAndSettle();

    expect(find.text('Chi tiết phim'), findsOneWidget);
    expect(find.text('Không tìm thấy bản tải phù hợp'), findsOneWidget);
    expect(find.text('Quay lại kết quả'), findsOneWidget);
  });

  testWidgets('shows a friendly controller failure without raw socket details', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaShell(
        api: FakeMovieApi(),
        bootstrapper: FakeBootstrapper(Future.value(ControllerStartupResult.failed)),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Không thể khởi động bộ điều khiển cục bộ'), findsOneWidget);
    expect(find.text('Thử lại'), findsOneWidget);
    expect(find.textContaining('SocketException'), findsNothing);
  });

  testWidgets('does not eagerly call gateway pages while server is off', (tester) async {
    final api = CountingApi();
    await tester.pumpWidget(MaterialApp(home: MediaShell(
      api: api,
      bootstrapper: FakeBootstrapper(Future.value(ControllerStartupResult.ready)),
    )));
    await tester.pumpAndSettle();

    expect(api.gatewayCalls, 0);
    expect(find.text('Trạng thái: off'), findsOneWidget);
  });

  testWidgets('loads trending movies then retains search and restores trending', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MovieSearchPage(api: FakeMovieApi()))));
    await tester.pumpAndSettle();

    expect(find.text('Đang thịnh hành'), findsOneWidget);
    expect(find.textContaining('The Matrix'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Dune');
    await tester.tap(find.text('Tìm'));
    await tester.pumpAndSettle();
    expect(find.text('Kết quả tìm kiếm'), findsOneWidget);
    expect(find.text('Dune (2021)'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('Tìm'));
    await tester.pumpAndSettle();
    expect(find.text('Đang thịnh hành'), findsOneWidget);
    expect(find.textContaining('The Matrix'), findsOneWidget);
  });
}
