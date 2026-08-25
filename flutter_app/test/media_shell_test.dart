import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_control/controller_bootstrap.dart';
import 'package:media_control/main.dart';

class _ReadyBootstrapper extends ControllerBootstrapper {
  _ReadyBootstrapper() : super(probe: () async => true, launch: () async {});

  @override
  Future<ControllerStartupResult> ensureReady() async =>
      ControllerStartupResult.ready;
}

class _ShellApi extends Api {
  _ShellApi() : super(const LocalConfig());

  final gatewayPaths = <String>[];

  @override
  Future<dynamic> host(String path, {String method = 'GET'}) async =>
      path == '/host/status' ? {'state': 'off', 'services': []} : [];

  @override
  Future<dynamic> gateway(String path,
      {String method = 'GET', Object? body}) async {
    gatewayPaths.add(path);
    if (path.endsWith('/trending')) {
      return {'items': [], 'source': 'test', 'stale': false};
    }
    if (path == '/v1/discover/search') {
      return {'items': [], 'partial': false};
    }
    return [];
  }
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required double width,
  required _ShellApi api,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MediaControlApp(
    api: api,
    bootstrapper: _ReadyBootstrapper(),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('uses the compact navigation breakpoint below 840 pixels',
      (tester) async {
    await _pumpShell(tester, width: 839, api: _ShellApi());

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(
        tester
            .widget<MaterialApp>(find.byType(MaterialApp))
            .theme!
            .useMaterial3,
        isTrue);
  });

  testWidgets('uses the rail navigation breakpoint at 840 pixels',
      (tester) async {
    await _pumpShell(tester, width: 840, api: _ShellApi());

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('groups destinations by workspace and creates pages lazily',
      (tester) async {
    final api = _ShellApi();
    await _pumpShell(tester, width: 1200, api: api);

    expect(find.text('Nội dung'), findsOneWidget);
    expect(find.text('Hệ thống'), findsOneWidget);
    expect(find.text('Tổng quan'), findsWidgets);
    expect(find.text('Services'), findsOneWidget);
    expect(find.text('Cài đặt'), findsOneWidget);
    expect(find.text('Khám phá'), findsNothing);
    expect(find.text('Downloads'), findsNothing);
    expect(find.text('Vietsub'), findsNothing);
    expect(find.text('Thư viện'), findsNothing);
    expect(api.gatewayPaths, isEmpty);

    await tester.tap(find.text('Nội dung'));
    await tester.pumpAndSettle();

    expect(find.text('Khám phá'), findsOneWidget);
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('Vietsub'), findsOneWidget);
    expect(find.text('Thư viện'), findsOneWidget);
    expect(find.text('Services'), findsNothing);
    expect(find.text('Cài đặt'), findsNothing);
    expect(api.gatewayPaths, isEmpty);
  });

  testWidgets('retains discovery input across workspace changes',
      (tester) async {
    await _pumpShell(tester, width: 1200, api: _ShellApi());
    await tester.tap(find.text('Nội dung'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'The Matrix');

    await tester.tap(find.text('Hệ thống'));
    await tester.pump();
    await tester.tap(find.text('Nội dung'));
    await tester.pump();

    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'The Matrix');
  });

  testWidgets('updates retained Downloads visibility without losing its state',
      (tester) async {
    await _pumpShell(tester, width: 1200, api: _ShellApi());
    await tester.tap(find.text('Nội dung'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Downloads'));
    await tester.pump();

    expect(tester.widget<DownloadsPage>(find.byType(DownloadsPage)).active,
        isTrue);

    await tester.tap(find.text('Khám phá'));
    await tester.pump();

    expect(
        tester
            .widget<DownloadsPage>(
                find.byType(DownloadsPage, skipOffstage: false))
            .active,
        isFalse);
  });
}
