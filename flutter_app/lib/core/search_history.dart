part of '../media_control.dart';

class SearchHistoryStore {
  SearchHistoryStore({String? path}) : path = path ?? _defaultPath();

  final String path;
  Future<void> _pending = Future<void>.value();

  static String _defaultPath() {
    final base = Platform.environment['LOCALAPPDATA'] ?? Directory.current.path;
    return '$base${Platform.pathSeparator}MediaControl${Platform.pathSeparator}search-history.json';
  }

  Future<List<String>> load() async {
    await _pending;
    try {
      final value = jsonDecode(await File(path).readAsString());
      return value is List
          ? value
              .whereType<String>()
              .map((item) => item.trim())
              .where((item) => item.isNotEmpty)
              .take(10)
              .toList()
          : [];
    } catch (_) {
      return [];
    }
  }

  Future<void> save(Iterable<String> queries) {
    final unique = <String>[];
    for (final value in queries) {
      final clean = value.trim();
      if (clean.isEmpty ||
          unique.any((item) => item.toLowerCase() == clean.toLowerCase())) {
        continue;
      }
      unique.add(clean);
      if (unique.length == 10) break;
    }
    _pending = _pending.then((_) async {
      try {
        final target = File(path);
        await target.parent.create(recursive: true);
        final temporary = File('$path.tmp');
        if (await temporary.exists()) await temporary.delete();
        await temporary.writeAsString(jsonEncode(unique), flush: true);
        await temporary.rename(path);
      } catch (_) {}
    });
    return _pending;
  }

  Future<void> clear() {
    _pending = _pending.then((_) async {
      for (final file in [File(path), File('$path.tmp')]) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    });
    return _pending;
  }
}
