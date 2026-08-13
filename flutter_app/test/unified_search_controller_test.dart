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
}
