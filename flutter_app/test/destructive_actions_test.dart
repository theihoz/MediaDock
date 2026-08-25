import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_control/main.dart';

class DestructiveApi extends Api {
  DestructiveApi() : super(const LocalConfig());

  int restartCalls = 0;
  int serviceStopCalls = 0;

  @override
  Future<dynamic> host(String path, {String method = 'GET'}) async {
    if (path == '/host/status') return {'state': 'running'};
    if (path == '/host/restart' && method == 'POST') {
      restartCalls++;
      return {};
    }
    if (path == '/host/services') {
      return [
        {'id': 'radarr', 'state': 'running', 'health': 'healthy'}
      ];
    }
    if (path == '/host/services/radarr/stop' && method == 'POST') {
      serviceStopCalls++;
      return {};
    }
    throw StateError('Unexpected host request: $method $path');
  }

  @override
  Future<dynamic> gateway(String path,
      {String method = 'GET', Object? body}) async {
    if (path == '/v1/sources') return [];
    throw StateError('Unexpected gateway request: $method $path');
  }
}

void main() {
  testWidgets('overview restart has a label and requires confirmation',
      (tester) async {
    final api = DestructiveApi();
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: OverviewPage(api: api))));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Khởi động lại'));
    await tester.pumpAndSettle();
    expect(api.restartCalls, 0);
    expect(find.text('Khởi động lại server?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Khởi động lại'));
    await tester.pumpAndSettle();
    expect(api.restartCalls, 1);
  });

  testWidgets('service stop has a label and requires confirmation',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = DestructiveApi();
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: ServicesPage(api: api))));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dừng'));
    await tester.pumpAndSettle();
    expect(api.serviceStopCalls, 0);
    expect(find.text('Dừng radarr?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Dừng'));
    await tester.pumpAndSettle();
    expect(api.serviceStopCalls, 1);
  });
}
