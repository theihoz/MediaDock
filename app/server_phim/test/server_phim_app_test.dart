import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:server_phim/app.dart';
import 'package:server_phim/core/dashboard_controller.dart';

class FakeDashboardController extends DashboardController {
  FakeDashboardController({required bool online})
    : super.fake(
        DashboardState.initial().copyWith(
          loading: false,
          serverOnline: online,
          overallState: online ? 'healthy' : 'offline',
        ),
      );
}

Widget testApp({bool online = true}) => ProviderScope(
  overrides: [
    dashboardControllerProvider.overrideWith(
      (ref) => FakeDashboardController(online: online),
    ),
  ],
  child: const ServerPhimApp(),
);

void main() {
  testWidgets('shows the six approved destinations', (tester) async {
    await tester.pumpWidget(testApp());
    for (final label in [
      'Tổng quan',
      'Khám phá',
      'Thư viện',
      'Tải xuống',
      'Phụ đề',
      'Quản trị',
    ]) {
      expect(find.text(label), findsWidgets);
    }
  });

  testWidgets('shows manual start when the server is offline', (tester) async {
    await tester.pumpWidget(testApp(online: false));
    expect(find.text('Bật server'), findsOneWidget);
    expect(find.text('Server đang tắt'), findsOneWidget);
  });

  testWidgets('discover defaults to 1080p and offers per-title 4K', (
    tester,
  ) async {
    await tester.pumpWidget(testApp());
    await tester.tap(find.text('Khám phá').first);
    await tester.pumpAndSettle();
    expect(find.text('1080p mặc định'), findsOneWidget);
    expect(find.text('Yêu cầu 4K cho nội dung này'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('pipeline signal strip is visible on every screen', (
    tester,
  ) async {
    await tester.pumpWidget(testApp());
    expect(find.text('YÊU CẦU'), findsOneWidget);
    expect(find.text('TẢI XUỐNG'), findsOneWidget);
    expect(find.text('PHỤ ĐỀ'), findsOneWidget);
    expect(find.text('SẴN SÀNG'), findsOneWidget);
  });

  testWidgets('admin opens one in-app configuration form', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.tap(find.text('Quản trị').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Indexer'));
    await tester.pumpAndSettle();
    expect(find.text('Cấu hình Indexer'), findsOneWidget);
    expect(find.text('Tên hiển thị'), findsOneWidget);
    expect(find.text('Implementation'), findsOneWidget);
    expect(find.text('Thiết lập JSON'), findsOneWidget);
  });
}
