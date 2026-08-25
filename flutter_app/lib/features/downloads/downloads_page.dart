part of '../../media_control.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.api, this.active = true});
  final Api api;
  final bool active;
  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  List<dynamic> items = [];
  Timer? refreshTimer;
  Timer? reconnectTimer;
  StreamSubscription<DownloadEvent>? eventSubscription;
  int? loadingGeneration;
  String? loadError;
  String liveStatus = 'Đang kết nối lại';
  int generation = 0;

  @override
  void initState() {
    super.initState();
    if (widget.active) _activate();
  }

  @override
  void didUpdateWidget(covariant DownloadsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      _activate();
    } else {
      _deactivate();
    }
  }

  @override
  void dispose() {
    _deactivate();
    super.dispose();
  }

  void _activate() {
    final current = ++generation;
    liveStatus = 'Đang kết nối lại';
    loadError = null;
    _connect(current);
    unawaited(_loadFallback(current));
  }

  void _deactivate() {
    generation++;
    refreshTimer?.cancel();
    refreshTimer = null;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    unawaited(eventSubscription?.cancel());
    eventSubscription = null;
  }

  bool _isCurrent(int current) =>
      mounted && widget.active && generation == current;

  void _connect(int current) {
    if (!_isCurrent(current)) return;
    try {
      eventSubscription = widget.api.downloadEvents().listen(
            (event) => _handleEvent(current, event),
            onError: (_) => _disconnect(current),
            onDone: () => _disconnect(current),
            cancelOnError: false,
          );
    } catch (_) {
      _disconnect(current);
    }
  }

  void _handleEvent(int current, DownloadEvent event) {
    if (!_isCurrent(current)) return;
    if (event.type == 'error') {
      _disconnect(current);
      return;
    }
    if (event.type != 'snapshot') return;
    final nextItems = event.data['items'];
    if (nextItems is! List) {
      _disconnect(current);
      return;
    }
    refreshTimer?.cancel();
    refreshTimer = null;
    setState(() {
      items = List<dynamic>.from(nextItems);
      liveStatus = 'Trực tiếp';
      loadError = null;
    });
  }

  void _disconnect(int current) {
    if (!_isCurrent(current)) return;
    final needsFallback =
        loadingGeneration != current && !(refreshTimer?.isActive ?? false);
    unawaited(eventSubscription?.cancel());
    eventSubscription = null;
    setState(() {
      liveStatus = 'Đang kết nối lại';
      loadError = 'Mất kết nối tạm thời. Đang thử lại…';
    });
    if (needsFallback) unawaited(_loadFallback(current));
    if (reconnectTimer?.isActive ?? false) return;
    reconnectTimer = Timer(const Duration(seconds: 3), () {
      reconnectTimer = null;
      _connect(current);
    });
  }

  Future<void> load() => _loadFallback(
        generation,
        reschedule: liveStatus != 'Trực tiếp',
        markStale: liveStatus != 'Trực tiếp',
      );

  Future<void> _loadFallback(int current,
      {bool reschedule = true, bool markStale = true}) async {
    if (loadingGeneration == current) return;
    loadingGeneration = current;
    try {
      final x = await widget.api.gateway('/v1/downloads');
      if (x is! List) throw const FormatException('Invalid downloads');
      if (_isCurrent(current) && (!markStale || liveStatus != 'Trực tiếp')) {
        setState(() {
          items = List<dynamic>.from(x);
          if (markStale) liveStatus = 'Dữ liệu cũ';
          loadError = null;
        });
      }
    } catch (_) {
      if (_isCurrent(current)) {
        setState(() => loadError = 'Mất kết nối tạm thời. Đang thử lại…');
      }
    } finally {
      if (loadingGeneration == current) loadingGeneration = null;
      if (_isCurrent(current) && reschedule && liveStatus != 'Trực tiếp') {
        refreshTimer?.cancel();
        refreshTimer = Timer(_fallbackDelay(), () {
          refreshTimer = null;
          unawaited(_loadFallback(current));
        });
      }
    }
  }

  Duration _fallbackDelay() {
    final active = items.any((item) {
      if (item is! Map) return false;
      final state = '${item['state'] ?? ''}'.toLowerCase();
      if (const {
        'paused',
        'stopped',
        'pauseddl',
        'stoppeddl',
        'error',
        'missingfiles'
      }.contains(state)) {
        return false;
      }
      final progress = item['progress'];
      return const {'active', 'downloading', 'importing'}.contains(state) ||
          (progress is num && progress < 100);
    });
    return Duration(seconds: active ? 1 : 5);
  }

  Future<void> act(String hash, String action) async {
    try {
      await widget.api.gateway(
          '/v1/downloads/$hash${action == 'delete' ? '' : '/$action'}',
          method: action == 'delete' ? 'DELETE' : 'POST');
      await load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> confirmDelete(dynamic item) async {
    final confirmed = await confirmAction(
      context,
      title: 'Xóa download?',
      message: 'Xóa ${item['name'] ?? 'download'} khỏi hàng đợi?',
      confirmLabel: 'Xóa',
    );
    if (confirmed && mounted) await act('${item['hash']}', 'delete');
  }

  String stateLabel(dynamic state) =>
      state == 'importing' ? 'Đang nhập thư viện' : '$state';

  @override
  Widget build(BuildContext context) => PageFrame(
      title: 'Downloads',
      actions: [
        IconButton(
            tooltip: 'Làm mới',
            onPressed: widget.active ? load : null,
            icon: const Icon(Icons.refresh))
      ],
      child: Column(children: [
        Align(alignment: Alignment.centerLeft, child: Text(liveStatus)),
        const SizedBox(height: 8),
        if (loadError != null)
          Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(loadError!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
        Expanded(
            child: items.isEmpty
                ? const Center(child: Text('Chưa có download'))
                : ListView(
                    children: items
                        .map((x) => Card(
                                child: Column(children: [
                              ListTile(
                                  title: Text('${x['name']}'),
                                  subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        LinearProgressIndicator(
                                            value:
                                                (((x['progress'] ?? 0) as num) /
                                                        100)
                                                    .clamp(0, 1)
                                                    .toDouble()),
                                        Text(
                                            '${x['category'] == 'series' ? 'TV Show' : 'Phim'} • ${x['progress']}% • ${stateLabel(x['state'])} • ${formatBytes(x['downloadSpeed'])}/s')
                                      ])),
                              Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 0, 12, 8),
                                  child: Wrap(
                                      alignment: WrapAlignment.end,
                                      spacing: 4,
                                      children: [
                                        TextButton.icon(
                                            onPressed: () =>
                                                act('${x['hash']}', 'pause'),
                                            icon: const Icon(Icons.pause),
                                            label: const Text('Tạm dừng')),
                                        TextButton.icon(
                                            onPressed: () =>
                                                act('${x['hash']}', 'resume'),
                                            icon: const Icon(Icons.play_arrow),
                                            label: const Text('Tiếp tục')),
                                        TextButton.icon(
                                            onPressed: () =>
                                                act('${x['hash']}', 'retry'),
                                            icon: const Icon(Icons.replay),
                                            label: const Text('Thử lại')),
                                        TextButton.icon(
                                            onPressed: () => confirmDelete(x),
                                            icon: const Icon(
                                                Icons.delete_outline),
                                            label: const Text('Xóa'))
                                      ]))
                            ])))
                        .toList())),
      ]));
}
