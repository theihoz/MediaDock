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
    if (path.startsWith('/v1/discover/search')) {
      return {
        'items': [
          {
            'mediaType': 'movie',
            'tmdbId': 603,
            'title': 'The Matrix',
            'year': 1999,
            'matchedBy': 'title',
            'matchedText': 'The Matrix'
          }
        ],
        'partial': false
      };
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

class NyaaSourcesApi extends Api {
  NyaaSourcesApi() : super(const LocalConfig());
  @override
  Future<dynamic> host(String path, {String method = 'GET'}) async => [];
  @override
  Future<dynamic> gateway(String path,
          {String method = 'GET', Object? body}) async =>
      [
        {
          'id': 'nyaa-si',
          'name': 'Nyaa.si',
          'state': 'cloudflare_blocked',
          'scopes': ['movie', 'series'],
          'endpoint': 'https://nyaa.si/',
          'reason': 'Cloudflare challenge requires attention'
        },
        {
          'id': 'nyaa-land',
          'name': 'Nyaa.land',
          'state': 'ready',
          'scopes': ['movie', 'series'],
          'endpoint': 'https://nyaa.land/'
        }
      ];
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

class SeriesLibraryApi extends Api {
  SeriesLibraryApi() : super(const LocalConfig());

  @override
  Future<dynamic> gateway(String path,
      {String method = 'GET', Object? body}) async {
    if (path == '/v1/library' && method == 'GET') {
      return [
        {
          'mediaId': 21,
          'jellyfinId': 'jf-series',
          'title': 'Frieren',
          'year': 2023,
          'type': 'series',
          'episodeCount': 28,
          'watched': false,
          'playbackPositionTicks': 0,
        }
      ];
    }
    throw StateError('Unexpected request: $method $path');
  }
}

class GroupedSubtitleApi extends Api {
  GroupedSubtitleApi() : super(const LocalConfig());
  int seasonCalls = 0;
  int seasonSearchCalls = 0;
  bool seasonComplete = false;

  @override
  Future<dynamic> gateway(String path,
      {String method = 'GET', Object? body}) async {
    if (path == '/v1/library/subtitle-media') {
      return [
        {
          'mediaId': 21,
          'title': 'Frieren',
          'year': 2023,
          'type': 'series',
          'episodeCount': 2,
          'viAvailable': seasonComplete ? 2 : 1,
          'viMissing': seasonComplete ? 0 : 1,
          'seasons': [
            {
              'seasonNumber': 1,
              'episodeCount': 2,
              'viAvailable': seasonComplete ? 2 : 1,
              'viMissing': seasonComplete ? 0 : 1,
            }
          ],
        }
      ];
    }
    if (path == '/v1/library/subtitle-media/21/seasons/1') {
      seasonCalls++;
      return [
        {
          'mediaId': 92,
          'title': 'Frieren S01E02 • Missing Vietnamese',
          'type': 'episode',
          'hasVietnamese': false,
        },
        {
          'mediaId': 91,
          'title': 'Frieren S01E01 • Has Vietnamese',
          'type': 'episode',
          'hasVietnamese': true,
        },
      ];
    }
    if (path == '/v1/library/subtitle-media/21/seasons/1/search' &&
        method == 'POST') {
      seasonSearchCalls++;
      seasonComplete = true;
      return {
        'seriesId': 21,
        'seasonNumber': 1,
        'total': 2,
        'alreadyAvailable': 1,
        'downloaded': 1,
        'unavailable': 0,
        'failed': 0,
      };
    }
    if (path.startsWith('/v1/library/92/subtitles/search?') &&
        method == 'GET') {
      return {
        'data': [
          {
            'provider': 'opensubtitlescom',
            'language': 'vi',
            'release': 'Frieren.S01E02.1080p',
            'format': 'srt',
            'score': 95,
            'fallback': false,
            'downloadToken': 'open-token',
          },
          {
            'provider': 'gestdown',
            'language': 'en',
            'release': 'Frieren.S01E02.WEB',
            'format': 'srt',
            'score': 80,
            'fallback': true,
            'downloadToken': 'gest-token',
          },
        ],
        'directEnabled': false,
      };
    }
    throw StateError('Unexpected request: $method $path');
  }
}

class SeriesApi extends Api {
  SeriesApi() : super(const LocalConfig());
  Object? downloadBody;
  Object? releaseBody;
  var releaseCalls = 0;

  @override
  Future<dynamic> gateway(String path,
      {String method = 'GET', Object? body}) async {
    if (Uri.parse(path).path == '/v1/discover/search') {
      return {
        'items': [
          {
            'mediaType': 'series',
            'tvdbId': 123,
            'title': 'Test Show',
            'year': 2024,
            'overview': 'Overview',
            'poster': null,
            'seasons': [
              {'seasonNumber': 1}
            ],
          }
        ],
        'partial': false,
      };
    }
    if (path == '/v1/series/123/releases' && method == 'POST') {
      releaseCalls++;
      releaseBody = body;
      return {
        'items': [
          {
            'downloadToken': 'opaque-token',
            'title': 'Test Show S01 1080p',
            'quality': 'WEBDL-1080p',
            'codec': 'H.264',
            'size': 1000,
            'seeders': 5,
            'peers': 8,
            'source': 'YTS Official',
            'downloadable': true,
          }
        ],
        'partial': false,
        'sources': {
          'sonarr': {'state': 'ready', 'itemCount': 1}
        },
        'prepared': true,
      };
    }
    if (path == '/v1/series/123/download' && method == 'POST') {
      downloadBody = body;
      return {};
    }
    throw StateError('Unexpected request: $method $path');
  }
}

Future<void> _chooseSubtitleCatalog(WidgetTester tester, String title) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(title).last);
  await tester.pumpAndSettle();
}

void main() {
  test('hides raw qBittorrent upstream errors from download users', () {
    expect(
        friendlyDownloadError(Exception(
            '{"error":"upstream_failed","message":"Failed to connect to qBittorrent"}')),
        'qBittorrent chưa nhận bản tải. Hãy kiểm tra Downloads rồi thử lại.');
  });

  test('groups only actionable releases into selectable download sources', () {
    final sources = actionableReleaseSources([
      {'source': 'YTS', 'downloadable': true},
      {'source': 'YTS', 'downloadable': false},
      {'source': 'EZTV', 'downloadable': true},
      {'source': 'Internet Archive', 'downloadable': false},
    ]);

    expect(sources, ['YTS', 'EZTV']);
  });

  testWidgets('shows readable Vietnamese media navigation', (tester) async {
    await tester.pumpWidget(MediaControlApp(
      api: FakeMovieApi(),
      bootstrapper:
          FakeBootstrapper(Future.value(ControllerStartupResult.ready)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Media Control'), findsOneWidget);
    expect(find.text('Nội dung'), findsOneWidget);
    expect(find.text('Hệ thống'), findsOneWidget);
    expect(find.text('Tổng quan'), findsWidgets);
    expect(find.text('Services'), findsOneWidget);
    expect(find.text('Cài đặt'), findsOneWidget);
    await tester.tap(find.text('Nội dung'));
    await tester.pump();
    expect(find.text('Khám phá'), findsOneWidget);
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('Vietsub'), findsOneWidget);
    expect(find.text('Thư viện'), findsOneWidget);
    await tester.tap(find.text('Vietsub').first);
    await tester.pump();
    expect(find.text('1. Nội dung'), findsOneWidget);
    expect(find.text('Cho phép YIFY Direct fallback'), findsNothing);
    expect(find.text('Tìm trực tiếp YIFY'), findsNothing);
  });

  testWidgets('Nyaa source states are readable and show safe endpoints',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ServicesPage(api: NyaaSourcesApi()))));
    await tester.pumpAndSettle();

    expect(find.text('Nyaa.si'), findsOneWidget);
    expect(find.text('Nyaa.land'), findsOneWidget);
    expect(find.textContaining('Bị Cloudflare chặn'), findsOneWidget);
    expect(find.textContaining('Sẵn sàng'), findsOneWidget);
    expect(find.textContaining('https://nyaa.si/'), findsOneWidget);
    expect(find.textContaining('https://nyaa.land/'), findsOneWidget);
    expect(find.textContaining('<html>'), findsNothing);
  });

  testWidgets(
      'discovery does not show unavailable source filters before selecting a release',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: DiscoveryPage(api: FakeMovieApi()))));
    await tester.pumpAndSettle();
    expect(find.text('Free & Public Domain'), findsNothing);

    await tester.tap(find.byKey(const Key('discover-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TV Show').last);
    await tester.pumpAndSettle();
    expect(find.text('Free & Public Domain'), findsNothing);
  });

  testWidgets('opens a unified movie suggestion directly', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: DiscoveryPage(api: FakeMovieApi()))));

    await tester.enterText(find.byType(TextField).first, 'matrix');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The Matrix (1999)').first);
    await tester.pumpAndSettle();

    expect(find.text('Chi tiết phim'), findsOneWidget);
    expect(find.text('The Matrix (1999)'), findsOneWidget);
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

    await tester.scrollUntilVisible(find.text('Xóa cache & log'), 250,
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
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: LibraryPage(api: api))));
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

  testWidgets('library shows imported TV series without calling movie APIs',
      (tester) async {
    final api = SeriesLibraryApi();
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: LibraryPage(api: api))));
    await tester.pumpAndSettle();

    expect(find.text('Frieren (2023)'), findsOneWidget);
    expect(find.textContaining('TV Show'), findsOneWidget);
    await tester.tap(find.text('Frieren (2023)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('28 tập'), findsOneWidget);
    expect(find.textContaining('Phụ đề'), findsOneWidget);
  });

  testWidgets('subtitle tab groups TV episodes under a Vietsub season summary',
      (tester) async {
    final api = GroupedSubtitleApi();
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: SubtitlesPage(api: api))));
    await tester.pumpAndSettle();

    await _chooseSubtitleCatalog(tester, 'TV • Frieren (2023)');
    expect(find.textContaining('Frieren'), findsOneWidget);
    expect(find.text('Season 1 • Vietsub 1/2'), findsOneWidget);
    expect(find.textContaining('S01E01'), findsNothing);
    expect(api.seasonCalls, 0);

    await tester.tap(find.text('Season 1 • Vietsub 1/2'));
    await tester.pumpAndSettle();
    expect(api.seasonCalls, 1);
    expect(find.text('Tập phim'), findsOneWidget);
    expect(find.textContaining('S01E02'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    expect(find.textContaining('S01E02'), findsOneWidget);
    await tester.tap(find.textContaining('S01E02'));
    await tester.pumpAndSettle();
    expect(find.text('Thiếu Vietsub'), findsOneWidget);
  });

  testWidgets('searches Vietsub for the selected season in one action',
      (tester) async {
    final api = GroupedSubtitleApi();
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: SubtitlesPage(api: api))));
    await tester.pumpAndSettle();

    await _chooseSubtitleCatalog(tester, 'TV • Frieren (2023)');
    await tester.tap(find.textContaining('Season 1').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tìm Vietsub cho Season 1'));
    await tester.pumpAndSettle();

    expect(api.seasonSearchCalls, 1);
    // Keep the assertion below user-visible: the aggregate status must render.
    expect(find.textContaining('Đã tải 1'), findsOneWidget);
    expect(find.text('Season 1 • Vietsub 2/2'), findsOneWidget);
  });

  testWidgets('shows every subtitle provider group and English fallback',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = GroupedSubtitleApi();
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: SubtitlesPage(api: api))));
    await tester.pumpAndSettle();
    await _chooseSubtitleCatalog(tester, 'TV • Frieren (2023)');
    await tester.tap(find.textContaining('Season 1').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Frieren S01E02 • Missing Vietnamese').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tìm riêng tập đang chọn'));
    await tester.pumpAndSettle();

    expect(find.text('OpenSubtitles.com • 1'), findsOneWidget);
    expect(find.text('Gestdown • 1'), findsOneWidget);
    expect(find.text('YIFY Subtitles • 0'), findsOneWidget);
    expect(find.text('Không có kết quả'), findsOneWidget);
    expect(find.textContaining('English fallback'), findsOneWidget);
  });

  testWidgets('discovers a TV show and downloads an explicit season pack',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = SeriesApi();
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: DiscoveryPage(api: api))));
    await tester.enterText(find.byKey(const Key('discover-query')), 'Test');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.releaseCalls, 0);

    await tester.tap(find.byKey(const ValueKey('discover-suggestion-123')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Chi tiết TV Show'), findsOneWidget);
    expect(find.text('Tìm bản tải'), findsOneWidget);
    expect(api.releaseCalls, 0);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsWidgets);

    await tester.tap(find.byKey(const Key('prepare-season-releases')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.releaseCalls, 1);
    expect(api.releaseBody, {'seasonNumber': 1});
    expect(find.text('Test Show S01 1080p'), findsOneWidget);

    await tester.tap(find.text('Tải'));
    await tester.pumpAndSettle();
    expect(
        api.downloadBody, {'downloadToken': 'opaque-token', 'seasonNumber': 1});
  });
}
