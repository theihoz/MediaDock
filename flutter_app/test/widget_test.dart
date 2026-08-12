import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_control/main.dart';

class FakeMovieApi extends Api {
  FakeMovieApi() : super(const LocalConfig());
  @override
  Future<dynamic> gateway(String path, {String method = 'GET', Object? body}) async {
    if (path.startsWith('/v1/movies/search')) {
      return [{'tmdbId': 603, 'title': 'The Matrix', 'year': 1999, 'overview': 'Test movie', 'poster': null}];
    }
    if (path == '/v1/movies/603/releases') return [];
    throw StateError('Unexpected request: $path');
  }
}

void main() {
  testWidgets('shows readable Vietnamese media navigation', (tester) async {
    await tester.pumpWidget(const MediaControlApp());

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
}
