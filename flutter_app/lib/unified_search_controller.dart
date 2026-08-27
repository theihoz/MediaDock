import 'dart:async';
import 'package:flutter/foundation.dart';

typedef UnifiedSearchRequest = Future<dynamic> Function(String query);

class UnifiedSearchController extends ChangeNotifier {
  UnifiedSearchController({required this.search, this.onRecentChanged});
  final UnifiedSearchRequest search;
  final ValueChanged<List<String>>? onRecentChanged;
  Timer? _timer;
  int _generation = 0;
  String query = '';
  bool loading = false;
  bool partial = false;
  Object? error;
  List<dynamic> items = [];
  final List<String> recent = [];
  final Map<String, dynamic> _cache = {};

  void updateQuery(String value) {
    query = value.trim();
    _timer?.cancel();
    _generation++;
    error = null;
    if (query.length < 2) {
      loading = false;
      partial = false;
      items = [];
      notifyListeners();
      return;
    }
    final generation = _generation;
    _timer = Timer(
        const Duration(milliseconds: 400), () => _load(query, generation));
    notifyListeners();
  }

  Future<void> _load(String value, int generation) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final key = value.toLowerCase();
      final response = _cache[key] ?? await search(value);
      if (generation != _generation) return;
      _cache[key] = response;
      items = List<dynamic>.from(response['items'] ?? const []);
      partial = response['partial'] == true;
      remember(value);
    } catch (caught) {
      if (generation != _generation) return;
      error = caught;
      items = [];
      partial = false;
    } finally {
      if (generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void remember(String value) {
    final clean = value.trim();
    if (clean.isEmpty) return;
    recent.removeWhere((item) => item.toLowerCase() == clean.toLowerCase());
    recent.insert(0, clean);
    if (recent.length > 10) recent.removeRange(10, recent.length);
    onRecentChanged?.call(List.unmodifiable(recent));
    notifyListeners();
  }

  void replaceRecent(Iterable<String> values) {
    recent.clear();
    for (final value in values) {
      final clean = value.trim();
      if (clean.isEmpty ||
          recent.any((item) => item.toLowerCase() == clean.toLowerCase())) {
        continue;
      }
      recent.add(clean);
      if (recent.length == 10) break;
    }
    notifyListeners();
  }

  void clearRecent() {
    recent.clear();
    onRecentChanged?.call(const []);
    notifyListeners();
  }

  void clearCache() {
    _cache.clear();
    _timer?.cancel();
    _generation++;
    loading = false;
    partial = false;
    error = null;
    items = [];
    notifyListeners();
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    super.dispose();
  }
}
