import 'dart:async';

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
  Future<dynamic> gateway(String path,
      {String method = 'GET', Object? body}) async {
    if (path == '/v1/movies/trending') {
      return {
        'items': [
          {
            'tmdbId': 603,
            'title': 'The Matrix',
            'year': 1999,
            'overview': 'Trending movie',
            'poster': null,
            'rating': 8.2
          }
        ],
        'source': 'live',
        'stale': false,
      };
    }
    if (path.startsWith('/v1/movies/search')) {
      if (path.contains('Dune')) {
        return [
          {
            'tmdbId': 438631,
            'title': 'Dune',
            'year': 2021,
            'overview': 'Search result',
            'poster': null
          }
        ];
      }
      return [
        {
          'tmdbId': 603,
          'title': 'The Matrix',
          'year': 1999,
          'overview': 'Test movie',
          'poster': null
        }
      ];
    }
    if (path == '/v1/movies/603/releases' ||
        path == '/v1/movies/438631/releases') {
      return [];
    }
    throw StateError('Unexpected request: $path');
  }

  @override
  Future<dynamic> host(String path, {String method = 'GET'}) async =>
      {'state': 'off', 'services': []};
}

class CountingApi extends Api {
  CountingApi() : super(const LocalConfig());
  int gatewayCalls = 0;
  @override
  Future<dynamic> host(String path, {String method = 'GET'}) async =>
      {'state': 'off', 'services': []};
  @override
  Future<dynamic> gateway(String path,
      {String method = 'GET', Object? body}) async {
    gatewayCalls++;
    return [];
  }
}

class DownloadPollingApi extends Api {
  DownloadPollingApi({this.neverCompletes = false})
      : super(const LocalConfig());
  final bool neverCompletes;
  int calls = 0;
  @override
  Future<dynamic> gateway(String path,
      {String method = 'GET', Object? body}) async {
    if (path != '/v1/downloads') return [];
    calls++;
    if (neverCompletes) return Completer<dynamic>().future;
    return [
      {
        'hash': 'abc',
        'name': 'Movie',
        'progress': calls.toDouble(),
        'state': 'downloading',
        'downloadSpeed': 1024
      }
    ];
  }
}

class MaintenanceApi extends Api {
  MaintenanceApi() : super(const LocalConfig());
  int cleanupCalls = 0;
  @override
  Future<dynamic> host(String path, {String method = 'GET'}) async {
    if (path == '/host/maintenance/status') {
      return {
        'lastRunAt': null,
        'nextRunAt': '2026-08-14T00:00:00Z',
        'removedFiles': 0,
        'reclaimedBytes': 0,
        'failed': []
      };
    }
    if (path == '/host/maintenance/cleanup' && method == 'POST') {
      cleanupCalls++;
      return {
        'lastRunAt': '2026-08-13T00:00:00Z',
        'nextRunAt': '2026-08-13T01:00:00Z',
        'removedFiles': 3,
        'reclaimedBytes': 2048,
        'failed': []
      };
    }
    throw StateError('Unexpected request: $method $path');
  }
}

class LibraryApi extends Api {
  LibraryApi() : super(const LocalConfig());
  int deleteCalls = 0;

  @override
  Future<dynamic> gateway(String path,
      {String method = 'GET', Object? body}) async {
    if (path == '/v1/library' && method == 'GET') {
      return [
        {
          'mediaId': 11,
          'jellyfinId': 'jf-11',
          'title': 'The Batman',
          'year': 2022,
          'watched': false,
          'playbackPositionTicks': 0,
          'videoCodec': 'H264',
          'audioCodec': 'AAC',
          'subtitleCount': 1
        }
      ];
    }
    if (path == '/v1/library/11/subtitles') return [];
    if (path == '/v1/library/11' && method == 'DELETE') {
      expect(body, {'deleteFiles': true, 'deleteTorrent': true});
      deleteCalls++;
      return {'status': 'deleted'};
    }
    throw StateError('Unexpected request: $method $path');
  }
}

void main() {
  testWidgets('shows readable Vietnamese media navigation', (tester) async {
    await tester.pumpWidget(MediaControlApp(
      api: FakeMovieApi(),
      bootstrapper:
          FakeBootstrapper(Future.value(ControllerStartupResult.ready)),
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

  testWidgets('clicking a movie always opens its detail even with no releases',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MovieSearchPage(api: FakeMovieApi()))));
    await tester.enterText(find.byType(TextField), 'Matrix');
    await tester.tap(find.text('Tìm'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The Matrix (1999)'));
    await tester.pumpAndSettle();

    expect(find.text('Chi tiết phim'), findsOneWidget);
    expect(find.text('Không tìm thấy bản tải phù hợp'), findsOneWidget);
    expect(find.text('Quay lại kết quả'), findsOneWidget);
  });

  testWidgets('shows a friendly controller failure without raw socket details',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaShell(
        api: FakeMovieApi(),
        bootstrapper:
            FakeBootstrapper(Future.value(ControllerStartupResult.failed)),
      ),
    ));
    await tester.pumpAndSettle();

    expect(
        find.text('Không thể khởi động bộ điều khiển cục bộ'), findsOneWidget);
    expect(find.text('Thử lại'), findsOneWidget);
    expect(find.textContaining('SocketException'), findsNothing);
  });

  testWidgets('does not eagerly call gateway pages while server is off',
      (tester) async {
    final api = CountingApi();
    await tester.pumpWidget(MaterialApp(
        home: MediaShell(
      api: api,
      bootstrapper:
          FakeBootstrapper(Future.value(ControllerStartupResult.ready)),
    )));
    await tester.pumpAndSettle();

    expect(api.gatewayCalls, 0);
    expect(find.text('Trạng thái: off'), findsOneWidget);
  });

  testWidgets('loads trending movies then retains search and restores trending',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MovieSearchPage(api: FakeMovieApi()))));
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

  testWidgets('refreshes downloads every second while visible', (tester) async {
    final api = DownloadPollingApi();
    await tester.pumpWidget(MaterialApp(home: DownloadsPage(api: api)));
    await tester.pump();
    expect(api.calls, 1);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(api.calls, 2);
    expect(find.textContaining('2.0%'), findsOneWidget);
  });

  testWidgets('does not overlap slow download refresh requests',
      (tester) async {
    final api = DownloadPollingApi(neverCompletes: true);
    await tester.pumpWidget(MaterialApp(home: DownloadsPage(api: api)));
    await tester.pump(const Duration(seconds: 3));
    expect(api.calls, 1);
  });

  testWidgets('settings confirms and reports cache and log cleanup',
      (tester) async {
    final api = MaintenanceApi();
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: SettingsPage(api: api))));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
        find.text('Xóa cache & log'), 250,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Xóa cache & log'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Giữ lại cache phim thịnh hành và toàn bộ cấu hình, media, database.'),
        findsOneWidget);
    await tester.tap(find.text('Xóa ngay'));
    await tester.pumpAndSettle();

    expect(api.cleanupCalls, 1);
    expect(find.textContaining('2.0 KB'), findsOneWidget);
    expect(find.textContaining('3 file'), findsOneWidget);
  });

  testWidgets('library deletion requires an uninterrupted three second hold',
      (tester) async {
    final api = LibraryApi();
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: LibraryPage(api: api))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The Batman (2022)'));
    await tester.pumpAndSettle();

    final button = find.text('Giữ 3 giây để xóa toàn bộ');
    final shortHold = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(seconds: 2));
    await shortHold.up();
    await tester.pump();
    expect(api.deleteCalls, 0);

    final fullHold = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(seconds: 3));
    await fullHold.up();
    await tester.pumpAndSettle();
    expect(api.deleteCalls, 1);
  });
}
