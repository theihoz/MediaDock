import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'server_lifecycle.dart';

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());
final lifecycleProvider = Provider<ServerLifecycle>((ref) => ServerLifecycle());

final dashboardControllerProvider =
    StateNotifierProvider<DashboardController, DashboardState>((ref) {
      final controller = DashboardController(
        ref.read(apiClientProvider),
        ref.read(lifecycleProvider),
      );
      Future.microtask(controller.refresh);
      return controller;
    });

class DashboardState {
  const DashboardState({
    required this.loading,
    required this.serverOnline,
    required this.overallState,
    required this.services,
    required this.storage,
    required this.library,
    required this.downloads,
    required this.subtitles,
    required this.searchResults,
    required this.request4k,
    this.error,
  });

  factory DashboardState.initial() => const DashboardState(
    loading: true,
    serverOnline: false,
    overallState: 'checking',
    services: [],
    storage: {},
    library: [],
    downloads: [],
    subtitles: [],
    searchResults: [],
    request4k: false,
  );

  final bool loading;
  final bool serverOnline;
  final String overallState;
  final List<Map<String, dynamic>> services;
  final Map<String, dynamic> storage;
  final List<Map<String, dynamic>> library;
  final List<Map<String, dynamic>> downloads;
  final List<Map<String, dynamic>> subtitles;
  final List<Map<String, dynamic>> searchResults;
  final bool request4k;
  final String? error;

  DashboardState copyWith({
    bool? loading,
    bool? serverOnline,
    String? overallState,
    List<Map<String, dynamic>>? services,
    Map<String, dynamic>? storage,
    List<Map<String, dynamic>>? library,
    List<Map<String, dynamic>>? downloads,
    List<Map<String, dynamic>>? subtitles,
    List<Map<String, dynamic>>? searchResults,
    bool? request4k,
    String? error,
    bool clearError = false,
  }) => DashboardState(
    loading: loading ?? this.loading,
    serverOnline: serverOnline ?? this.serverOnline,
    overallState: overallState ?? this.overallState,
    services: services ?? this.services,
    storage: storage ?? this.storage,
    library: library ?? this.library,
    downloads: downloads ?? this.downloads,
    subtitles: subtitles ?? this.subtitles,
    searchResults: searchResults ?? this.searchResults,
    request4k: request4k ?? this.request4k,
    error: clearError ? null : (error ?? this.error),
  );
}

class DashboardController extends StateNotifier<DashboardState> {
  DashboardController(this._api, this._lifecycle)
    : super(DashboardState.initial());
  DashboardController.fake(super.state) : _api = null, _lifecycle = null;

  final ApiClient? _api;
  final ServerLifecycle? _lifecycle;

  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final values = await Future.wait([
        api.get('/status'),
        api.get('/services'),
        api.get('/storage'),
        api.get('/library'),
        api.get('/downloads'),
        api.get('/subtitles'),
      ]);
      state = state.copyWith(
        loading: false,
        serverOnline: true,
        overallState: values[0]['state'] as String? ?? 'degraded',
        services: _list(values[1], 'services'),
        storage: values[2],
        library: _list(values[3], 'items'),
        downloads: _list(values[4], 'jobs'),
        subtitles: _list(values[5], 'items'),
      );
    } catch (_) {
      state = state.copyWith(
        loading: false,
        serverOnline: false,
        overallState: 'offline',
        error: 'Không kết nối được media-control',
      );
    }
  }

  List<Map<String, dynamic>> _list(Map<String, dynamic> source, String key) =>
      ((source[key] as List?) ?? const []).cast<Map<String, dynamic>>();

  Future<void> startServer() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      await _lifecycle?.start();
      await Future<void>.delayed(const Duration(seconds: 2));
      await refresh();
    } catch (_) {
      state = state.copyWith(
        loading: false,
        error: 'Không thể bật MediaServer',
      );
    }
  }

  Future<void> stopServer() async {
    await _lifecycle?.stop();
    state = DashboardState.initial().copyWith(
      loading: false,
      overallState: 'offline',
    );
  }

  Future<void> updateServer() async {
    await _lifecycle?.update();
    await refresh();
  }

  void set4k(bool value) => state = state.copyWith(request4k: value);

  Future<void> search(String query) async {
    final api = _api;
    if (api == null || query.trim().isEmpty) return;
    state = state.copyWith(loading: true);
    try {
      final result = await api.get(
        '/discover/search',
        query: {'q': query.trim()},
      );
      state = state.copyWith(
        loading: false,
        searchResults: _list(result, 'items'),
      );
    } catch (_) {
      state = state.copyWith(loading: false, error: 'Tìm kiếm thất bại');
    }
  }

  Future<void> requestMedia(Map<String, dynamic> item) async {
    await _api?.post('/requests', {
      'media_type': item['media_type'],
      'external_id': item['external_id'],
      'title': item['title'],
      'quality': state.request4k ? '4k' : '1080p',
    });
  }

  Future<void> downloadAction(String id, String action) async {
    if (action == 'cancel') {
      await _api?.deleteConfirmed('/downloads/$id/cancel');
    } else {
      await _api?.post('/downloads/$id/$action');
    }
    await refresh();
  }

  Future<void> subtitleAction(String id, String action) async {
    await _api?.post('/subtitles/$id/$action');
    await refresh();
  }

  Future<void> deleteLibrary(String id) async {
    await _api?.deleteConfirmed('/library/$id');
    await refresh();
  }

  Future<void> saveAdminResource(
    String kind,
    String name,
    String implementation,
    Map<String, dynamic> settings,
  ) async {
    await _api?.post('/admin/$kind', {
      'name': name,
      'implementation': implementation,
      'enabled': true,
      'settings': settings,
    });
  }
}
