import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_control/main.dart';

class ProgressiveSubtitleApi extends Api {
  ProgressiveSubtitleApi({this.directEnabled = true})
      : super(const LocalConfig());

  final bool directEnabled;

  @override
  Future<dynamic> gateway(String path,
      {String method = 'GET', Object? body}) async {
    if (path == '/v1/library/subtitle-media') {
      return [
        {
          'mediaId': 11,
          'type': 'movie',
          'title': 'The Batman',
          'year': 2022,
        },
        {
          'mediaId': 21,
          'type': 'series',
          'title': 'Frieren',
          'year': 2023,
          'seasons': [
            {
              'seasonNumber': 1,
              'viAvailable': 1,
              'episodeCount': 2,
            }
          ],
        },
      ];
    }
    if (path == '/v1/library/subtitle-media/21/seasons/1') {
      return [
        {
          'mediaId': 91,
          'title': 'S01E01 • Pilot',
          'hasVietnamese': true,
        },
        {
          'mediaId': 92,
          'title': 'S01E02 • Journey',
          'hasVietnamese': false,
        },
      ];
    }
    if (path == '/v1/library/11/subtitles/yify/search?language=vi') {
      return {
        'data': directEnabled
            ? [
                {
                  'provider': 'YIFY Direct',
                  'language': 'vi',
                  'release': 'The.Batman.2022.1080p',
                  'format': 'srt',
                  'score': 90,
                  'downloadToken': 'direct-token',
                }
              ]
            : [],
        'directEnabled': directEnabled,
      };
    }
    throw StateError('Unexpected request: $method $path');
  }
}

Future<void> chooseCatalog(WidgetTester tester, String title) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(title).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('reveals content, selection, and sources progressively',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SubtitlesPage(api: ProgressiveSubtitleApi()))));
    await tester.pumpAndSettle();

    expect(find.text('1. Nội dung'), findsOneWidget);
    expect(find.text('2. Mùa/tập'), findsNothing);
    expect(find.text('3. Nguồn/kết quả'), findsNothing);
    expect(find.text('Cho phép YIFY Direct fallback'), findsNothing);

    await chooseCatalog(tester, 'The Batman (2022)');
    expect(find.text('2. Mùa/tập'), findsOneWidget);
    expect(find.text('3. Nguồn/kết quả'), findsOneWidget);
    expect(find.text('Nâng cao'), findsOneWidget);
    expect(find.text('Cho phép YIFY Direct fallback'), findsNothing);

    await tester.tap(find.text('Nâng cao'));
    await tester.pumpAndSettle();
    expect(find.text('Cho phép YIFY Direct fallback'), findsOneWidget);
    expect(find.text('Tìm trực tiếp YIFY'), findsOneWidget);

    await tester.tap(find.text('Tìm trực tiếp YIFY'));
    await tester.pumpAndSettle();
    expect(find.text('YIFY Direct • 1'), findsOneWidget);
    await tester
        .ensureVisible(find.text('The.Batman.2022.1080p', skipOffstage: false));
    await tester.pumpAndSettle();
    expect(find.text('The.Batman.2022.1080p'), findsOneWidget);
  });

  testWidgets('series loads a season before exposing episode selection',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SubtitlesPage(api: ProgressiveSubtitleApi()))));
    await tester.pumpAndSettle();

    await chooseCatalog(tester, 'TV • Frieren (2023)');
    expect(find.text('Season 1 • Vietsub 1/2'), findsOneWidget);
    expect(find.text('3. Nguồn/kết quả'), findsNothing);

    await tester.tap(find.text('Season 1 • Vietsub 1/2'));
    await tester.pumpAndSettle();
    expect(find.text('3. Nguồn/kết quả'), findsOneWidget);
    expect(find.text('Tập phim'), findsOneWidget);
    expect(find.text('Tìm Vietsub cho Season 1'), findsOneWidget);
    expect(find.text('Tìm trực tiếp YIFY'), findsNothing);
  });

  testWidgets('direct YIFY reports when the backend provider is disabled',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SubtitlesPage(
                api: ProgressiveSubtitleApi(directEnabled: false)))));
    await tester.pumpAndSettle();

    await chooseCatalog(tester, 'The Batman (2022)');
    await tester.tap(find.text('Nâng cao'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tìm trực tiếp YIFY'));
    await tester.pumpAndSettle();

    expect(find.text('YIFY Direct đang tắt trong cấu hình backend.'),
        findsOneWidget);
  });
}
