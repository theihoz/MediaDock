import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_control/main.dart';

class LibraryUxApi extends Api {
  LibraryUxApi() : super(const LocalConfig());

  int subtitleDeleteCalls = 0;

  @override
  Future<dynamic> gateway(String path,
      {String method = 'GET', Object? body}) async {
    if (path == '/v1/library' && method == 'GET') {
      return [
        {
          'mediaId': 1,
          'jellyfinId': 'watched id',
          'title': 'Watched',
          'year': 2024,
          'poster': 'https://example.invalid/watched.jpg',
          'watched': true,
          'playbackPositionTicks': 0,
          'videoCodec': 'H264',
          'audioCodec': 'AAC',
          'subtitleCount': 2,
        },
        {
          'mediaId': 2,
          'jellyfinId': 'resume-id',
          'title': 'Resume',
          'year': 2023,
          'poster': 'https://example.invalid/resume.jpg',
          'watched': false,
          'playbackPositionTicks': 42,
          'videoCodec': 'HEVC',
          'audioCodec': 'EAC3',
          'subtitleCount': 1,
        },
        {
          'mediaId': 3,
          'jellyfinId': null,
          'title': 'Fresh',
          'year': 2022,
          'poster': null,
          'watched': false,
          'playbackPositionTicks': 0,
          'videoCodec': 'AV1',
          'audioCodec': 'AAC',
          'subtitleCount': 0,
        },
      ];
    }
    if (path == '/v1/library/2/subtitles' && method == 'GET') {
      return [
        {'id': 'sub-1', 'name': 'Vietnamese.srt', 'language': 'vi'}
      ];
    }
    if (path == '/v1/library/2/subtitles/sub-1' && method == 'DELETE') {
      subtitleDeleteCalls++;
      return {};
    }
    throw StateError('Unexpected request: $method $path');
  }
}

void main() {
  test('builds exact Jellyfin details links for default and override bases',
      () {
    expect(
      jellyfinDetailsUrl(
          const LocalConfig().jellyfinBaseUrl, 'movie id/with slash'),
      'http://localhost:8096/web/#/details?id=movie%20id%2Fwith%20slash',
    );
    expect(
      jellyfinDetailsUrl('http://media-pc:8096///', 'jf-11'),
      'http://media-pc:8096/web/#/details?id=jf-11',
    );
  });

  testWidgets('library renders posters and exact watched states',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: LibraryPage(api: LibraryUxApi()))));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNWidgets(2));
    expect(find.byIcon(Icons.image_not_supported_outlined), findsWidgets);
    expect(find.text('Đã xem'), findsOneWidget);
    expect(find.text('Xem tiếp'), findsOneWidget);
    expect(find.text('Chưa xem'), findsOneWidget);
    expect(find.textContaining('HEVC • EAC3 • 1 phụ đề'), findsOneWidget);
  });

  testWidgets('subtitle delete is labeled and requires confirmation',
      (tester) async {
    final api = LibraryUxApi();
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: LibraryPage(api: api))));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Resume (2023)'));
    await tester.pumpAndSettle();
    expect(find.text('Xóa'), findsOneWidget);

    await tester.tap(find.text('Xóa'));
    await tester.pumpAndSettle();
    expect(api.subtitleDeleteCalls, 0);
    expect(find.text('Xóa phụ đề?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Xóa'));
    await tester.pumpAndSettle();
    expect(api.subtitleDeleteCalls, 1);
  });
}
