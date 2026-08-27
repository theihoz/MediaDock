import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_control/unified_search_controller.dart';

void main() {
  test('debounces for 400ms and ignores queries shorter than two characters',
      () async {
    final calls = <String>[];
    final controller = UnifiedSearchController(search: (query) async {
      calls.add(query);
      return {'items': []};
    });
    controller.updateQuery('a');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(calls, isEmpty);
    controller.updateQuery('matrix');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(calls, ['matrix']);
  });

  test(
      'ignores stale responses and limits recent history to ten unique queries',
      () async {
    final pending = <String, Completer<dynamic>>{};
    final controller = UnifiedSearchController(
        search: (query) => (pending[query] = Completer<dynamic>()).future);
    controller.updateQuery('matrix');
    await Future<void>.delayed(const Duration(milliseconds: 410));
    controller.updateQuery('doctor');
    await Future<void>.delayed(const Duration(milliseconds: 410));
    pending['doctor']!.complete({
      'items': [
        {'title': 'Doctor'}
      ]
    });
    await Future<void>.delayed(Duration.zero);
    pending['matrix']!.complete({
      'items': [
        {'title': 'Matrix'}
      ]
    });
    await Future<void>.delayed(Duration.zero);
    expect(controller.items.single['title'], 'Doctor');
    for (var i = 0; i < 12; i++) {
      controller.remember('query $i');
    }
    expect(controller.recent.length, 10);
    controller.dispose();
  });

  test('restores, clears, and persists bounded recent searches', () {
    final persisted = <List<String>>[];
    final controller = UnifiedSearchController(
      search: (_) async => {'items': []},
      onRecentChanged: (items) => persisted.add(items),
    );

    controller.replaceRecent([
      ...List.generate(12, (index) => 'query $index'),
      'QUERY 1',
    ]);
    expect(controller.recent, List.generate(10, (index) => 'query $index'));
    expect(persisted, isEmpty);

    controller.remember('new query');
    expect(persisted.single.first, 'new query');
    controller.clearRecent();
    expect(controller.recent, isEmpty);
    expect(persisted.last, isEmpty);
    controller.dispose();
  });

  test('clearing the query cache refetches the same search', () async {
    var calls = 0;
    final controller = UnifiedSearchController(search: (query) async {
      calls++;
      return {
        'items': [
          {'title': 'old'}
        ]
      };
    });
    controller.updateQuery('matrix');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(controller.items, isNotEmpty);
    controller.clearCache();
    expect(controller.items, isEmpty);
    controller.updateQuery('matrix');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(calls, 2);
    controller.dispose();
  });

  test('clearing cache invalidates an in-flight response', () async {
    final first = Completer<dynamic>();
    var calls = 0;
    final controller = UnifiedSearchController(search: (_) {
      calls++;
      return calls == 1
          ? first.future
          : Future.value({
              'items': [
                {'title': 'fresh'}
              ]
            });
    });

    controller.updateQuery('matrix');
    await Future<void>.delayed(const Duration(milliseconds: 410));
    controller.clearCache();
    first.complete({
      'items': [
        {'title': 'stale'}
      ]
    });
    await Future<void>.delayed(Duration.zero);
    controller.updateQuery('matrix');
    await Future<void>.delayed(const Duration(milliseconds: 450));

    expect(calls, 2);
    expect(controller.items.single['title'], 'fresh');
    controller.dispose();
  });

  test('captures search failures without leaking an async error', () async {
    final failure = StateError('private upstream detail');
    final controller =
        UnifiedSearchController(search: (_) async => throw failure);

    controller.updateQuery('matrix');
    await Future<void>.delayed(const Duration(milliseconds: 450));

    expect(controller.error, same(failure));
    expect(controller.loading, false);
    expect(controller.items, isEmpty);
    controller.dispose();
  });

  test('disposing invalidates an in-flight response', () async {
    final pending = Completer<dynamic>();
    final controller = UnifiedSearchController(search: (_) => pending.future);

    controller.updateQuery('matrix');
    await Future<void>.delayed(const Duration(milliseconds: 410));
    controller.dispose();
    pending.complete({
      'items': [
        {'title': 'late'}
      ]
    });
    await Future<void>.delayed(Duration.zero);

    expect(controller.recent, isEmpty);
  });
}
