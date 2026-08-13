import 'dart:async';
import 'package:flutter/foundation.dart';

typedef UnifiedSearchRequest = Future<dynamic> Function(String query);

class UnifiedSearchController extends ChangeNotifier {
  UnifiedSearchController({required this.search});
  final UnifiedSearchRequest search;
  Timer? _timer;
  int _generation = 0;
  String query = '';
  bool loading = false;
  bool partial = false;
  List<dynamic> items = [];
  final List<String> recent = [];
  final Map<String, dynamic> _cache = {};

  void updateQuery(String value) {
    query = value.trim();
    _timer?.cancel();
    _generation++;
    if (query.length < 2) {
      loading = false;
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
    notifyListeners();
    try {
      final response = _cache[value.toLowerCase()] ?? await search(value);
      _cache[value.toLowerCase()] = response;
      if (generation != _generation) return;
      items = List<dynamic>.from(response['items'] ?? const []);
      partial = response['partial'] == true;
      remember(value);
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
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
