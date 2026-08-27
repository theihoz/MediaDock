import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_control/main.dart';

class DownloadsTestApi extends Api {
  DownloadsTestApi({
    List<StreamController<DownloadEvent>>? streams,
    this.fallbackItems = const [],
    this.pendingFallback,
  })  : streams = streams ?? [StreamController<DownloadEvent>()],
        super(const LocalConfig());

  final List<StreamController<DownloadEvent>> streams;
  List<dynamic> fallbackItems;
  final Completer<dynamic>? pendingFallback;
  int streamCalls = 0;
  int getCalls = 0;
  final actions = <String>[];

  @override
  Stream<DownloadEvent> downloadEvents() {
    final index = streamCalls++;
    return index < streams.length
        ? streams[index].stream
        : const Stream<DownloadEvent>.empty();
  }

  @override
  Future<dynamic> gateway(String path,
      {String method = 'GET', Object? body}) async {
    if (path == '/v1/downloads' && method == 'GET') {
      getCalls++;
      if (pendingFallback != null) return pendingFallback!.future;
      return fallbackItems;
    }
    actions.add('$method $path');
    return {};
  }

  void close() {
    for (final stream in streams) {
      if (!stream.isClosed) unawaited(stream.close());
    }
  }
}

Map<String, dynamic> download({
  String state = 'downloading',
  double progress = 42,
}) =>
    {
      'hash': 'abc',
      'name': 'Movie',
      'category': 'movie',
      'progress': progress,
      'state': state,
      'downloadSpeed': 1024,
    };

Future<void> mountDownloads(WidgetTester tester, DownloadsTestApi api,
    {bool active = true}) async {
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: DownloadsPage(api: api, active: active))));
  await tester.pump();
}

Future<void> unmountDownloads(WidgetTester tester, DownloadsTestApi api) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  api.close();
}

void main() {
  testWidgets('SSE snapshot renders downloads and marks data live',
      (tester) async {
    final api = DownloadsTestApi();
    await mountDownloads(tester, api);
    expect(api.streamCalls, 1);
    expect(api.streams.single.hasListener, isTrue);

    api.streams.single.add(DownloadEvent('snapshot', {
      'items': [download()],
      'generatedAt': '2026-08-25T00:00:00.000Z',
    }));
    await tester.pump();
    await tester.pump();

    expect(find.text('Trực tiếp'), findsOneWidget);
    expect(find.text('Movie'), findsOneWidget);
    expect(find.textContaining('42.0%'), findsOneWidget);
    await unmountDownloads(tester, api);
  });

  testWidgets('SSE error reconnects after 3 seconds and fallback becomes stale',
      (tester) async {
    final fallback = Completer<dynamic>();
    final api = DownloadsTestApi(
      streams: [
        StreamController<DownloadEvent>(),
        StreamController<DownloadEvent>(),
      ],
      pendingFallback: fallback,
    );
    await mountDownloads(tester, api);

    api.streams.first.add(const DownloadEvent(
        'error', {'error': '<html>private upstream failure</html>'}));
    await tester.pump();
    await tester.pump();

    expect(find.text('Đang kết nối lại'), findsOneWidget);
    expect(find.textContaining('private upstream'), findsNothing);
    expect(find.text('Mất kết nối tạm thời. Đang thử lại…'), findsOneWidget);

    fallback.complete([download(state: 'paused', progress: 75)]);
    await tester.pump();
    await tester.pump();
    expect(find.text('Dữ liệu cũ'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2999));
    expect(api.streamCalls, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(api.streamCalls, 2);
    await unmountDownloads(tester, api);
  });

  testWidgets('fallback polls active downloads every second', (tester) async {
    final api = DownloadsTestApi(fallbackItems: [download()]);
    await mountDownloads(tester, api);
    expect(api.getCalls, 1);

    await tester.pump(const Duration(milliseconds: 999));
    expect(api.getCalls, 1);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(api.getCalls, 2);
    await unmountDownloads(tester, api);
  });

  testWidgets('fallback polls idle downloads every five seconds',
      (tester) async {
    final api = DownloadsTestApi(
        fallbackItems: [download(state: 'completed', progress: 100)]);
    await mountDownloads(tester, api);
    expect(api.getCalls, 1);

    await tester.pump(const Duration(milliseconds: 4999));
    expect(api.getCalls, 1);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(api.getCalls, 2);
    await unmountDownloads(tester, api);
  });

  testWidgets('paused and stopped incomplete downloads use the idle cadence',
      (tester) async {
    final api = DownloadsTestApi(fallbackItems: [
      download(state: 'pausedDL', progress: 75),
      {...download(state: 'stoppedDL', progress: 60), 'hash': 'def'},
      {...download(state: 'error', progress: 50), 'hash': 'ghi'},
      {...download(state: 'missingFiles', progress: 40), 'hash': 'jkl'},
    ]);
    await mountDownloads(tester, api);

    await tester.pump(const Duration(milliseconds: 4999));
    expect(api.getCalls, 1);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(api.getCalls, 2);
    await unmountDownloads(tester, api);
  });

  testWidgets('fallback never overlaps an unfinished request', (tester) async {
    final fallback = Completer<dynamic>();
    final api = DownloadsTestApi(pendingFallback: fallback);
    await mountDownloads(tester, api);

    await tester.pump(const Duration(seconds: 10));
    expect(api.getCalls, 1);

    fallback.complete([]);
    await tester.pump();
    await unmountDownloads(tester, api);
  });

  testWidgets(
      'hidden page cancels stream and timers then reconnects when shown',
      (tester) async {
    final api = DownloadsTestApi(streams: [
      StreamController<DownloadEvent>(),
      StreamController<DownloadEvent>(),
    ]);
    await mountDownloads(tester, api);
    expect(api.streams.first.hasListener, isTrue);
    final getCalls = api.getCalls;

    await mountDownloads(tester, api, active: false);
    expect(api.streams.first.hasListener, isFalse);
    await tester.pump(const Duration(seconds: 6));
    expect(api.streamCalls, 1);
    expect(api.getCalls, getCalls);

    await mountDownloads(tester, api);
    expect(api.streamCalls, 2);
    expect(api.streams.last.hasListener, isTrue);
    await unmountDownloads(tester, api);
  });

  testWidgets(
      'reactivation starts fallback even when the old request is pending',
      (tester) async {
    final fallback = Completer<dynamic>();
    final api = DownloadsTestApi(
      streams: [
        StreamController<DownloadEvent>(),
        StreamController<DownloadEvent>(),
      ],
      pendingFallback: fallback,
    );
    await mountDownloads(tester, api);
    expect(api.getCalls, 1);

    await mountDownloads(tester, api, active: false);
    await mountDownloads(tester, api);
    expect(api.getCalls, 2);

    fallback.complete([]);
    await tester.pump();
    await unmountDownloads(tester, api);
  });

  testWidgets('download actions are labeled and delete requires confirmation',
      (tester) async {
    final api = DownloadsTestApi();
    await mountDownloads(tester, api);
    api.streams.single.add(DownloadEvent('snapshot', {
      'items': [download()],
      'generatedAt': '2026-08-25T00:00:00.000Z',
    }));
    await tester.pump();
    await tester.pump();

    expect(find.text('Tạm dừng'), findsOneWidget);
    expect(find.text('Tiếp tục'), findsOneWidget);
    expect(find.text('Thử lại'), findsOneWidget);
    expect(find.text('Xóa'), findsOneWidget);

    await tester.tap(find.text('Xóa'));
    await tester.pumpAndSettle();
    expect(api.actions, isEmpty);
    expect(find.text('Xóa download?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Xóa'));
    await tester.pumpAndSettle();
    expect(api.actions, ['DELETE /v1/downloads/abc']);
    await unmountDownloads(tester, api);
  });
}
