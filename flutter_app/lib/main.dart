import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_control/controller_bootstrap.dart';

void main() => runApp(const MediaControlApp());

class MediaControlApp extends StatelessWidget {
  const MediaControlApp({super.key, this.api, this.bootstrapper});
  final Api? api;
  final ControllerBootstrapper? bootstrapper;
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Media Control',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark, useMaterial3: true),
        home: MediaShell(api: api, bootstrapper: bootstrapper),
      );
}

class LocalConfig {
  const LocalConfig({this.gateway = 'http://localhost:3000', this.controller = 'http://127.0.0.1:3210', this.token = 'media-control-local', this.controllerLauncher = ''});
  final String gateway, controller, token, controllerLauncher;
  static LocalConfig parse(String text) {
    final normalized = text.startsWith('\uFEFF') ? text.substring(1) : text;
    final data = jsonDecode(normalized);
    return LocalConfig(
      gateway: data['gateway'] ?? 'http://localhost:3000',
      controller: data['controller'] ?? 'http://127.0.0.1:3210',
      token: data['token'] ?? 'media-control-local',
      controllerLauncher: data['controllerLauncher'] ?? '',
    );
  }
  static LocalConfig load() {
    try {
      final base = Platform.environment['LOCALAPPDATA'];
      return parse(File('$base\\MediaControl\\config.json').readAsStringSync());
    } catch (_) {
      return const LocalConfig();
    }
  }
}

class Api {
  Api(this.config);
  final LocalConfig config;
  Future<dynamic> request(String base, String path, {String method = 'GET', Object? body}) async {
    final headers = <String, String>{'content-type': 'application/json'};
    if (base == config.controller) headers['authorization'] = 'Bearer ${config.token}';
    final request = http.Request(method, Uri.parse('$base$path'))..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    final response = await request.send();
    final text = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) throw Exception(text.isEmpty ? 'HTTP ${response.statusCode}' : text);
    return text.isEmpty ? null : jsonDecode(text);
  }
  Future<dynamic> gateway(String path, {String method = 'GET', Object? body}) => request(config.gateway, path, method: method, body: body);
  Future<dynamic> host(String path, {String method = 'GET'}) => request(config.controller, path, method: method);
}

class MediaShell extends StatefulWidget {
  const MediaShell({super.key, this.api, this.bootstrapper});
  final Api? api;
  final ControllerBootstrapper? bootstrapper;
  @override
  State<MediaShell> createState() => _MediaShellState();
}

class _MediaShellState extends State<MediaShell> {
  int selected = 0;
  late final Api api;
  late final ControllerBootstrapper bootstrapper;
  ControllerStartupResult? controllerState;
  static const destinations = [
    NavigationRailDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: Text('Tổng quan')),
    NavigationRailDestination(icon: Icon(Icons.search), label: Text('Tìm phim')),
    NavigationRailDestination(icon: Icon(Icons.downloading_outlined), selectedIcon: Icon(Icons.downloading), label: Text('Downloads')),
    NavigationRailDestination(icon: Icon(Icons.subtitles_outlined), selectedIcon: Icon(Icons.subtitles), label: Text('Phụ đề')),
    NavigationRailDestination(icon: Icon(Icons.video_library_outlined), selectedIcon: Icon(Icons.video_library), label: Text('Thư viện')),
    NavigationRailDestination(icon: Icon(Icons.dns_outlined), selectedIcon: Icon(Icons.dns), label: Text('Services')),
    NavigationRailDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: Text('Cài đặt')),
  ];
  @override
  void initState() {
    super.initState();
    api = widget.api ?? Api(LocalConfig.load());
    bootstrapper = widget.bootstrapper ?? ControllerBootstrapper(
      probe: () async {
        await api.host('/host/status').timeout(const Duration(seconds: 2));
        return true;
      },
      launch: () async {
        final launcher = api.config.controllerLauncher;
        if (launcher.isEmpty) throw StateError('controller launcher is not configured');
        final process = await Process.start(
          'powershell.exe',
          ['-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', launcher],
          mode: ProcessStartMode.normal,
        );
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
      },
    );
    recoverController();
  }

  Future<void> recoverController() async {
    if (mounted) setState(() => controllerState = null);
    final result = await bootstrapper.ensureReady();
    if (mounted) setState(() => controllerState = result);
  }

  Widget selectedPage() => switch (selected) {
    0 => OverviewPage(api: api),
    1 => MovieSearchPage(api: api),
    2 => DownloadsPage(api: api),
    3 => SubtitlesPage(api: api),
    4 => LibraryPage(api: api),
    5 => ServicesPage(api: api),
    _ => SettingsPage(config: api.config),
  };

  @override
  Widget build(BuildContext context) {
    if (controllerState == null) {
      return const Scaffold(body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(), SizedBox(height: 16), Text('Đang kết nối bộ điều khiển…'),
      ])));
    }
    if (controllerState == ControllerStartupResult.failed) {
      return Scaffold(body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.desktop_access_disabled, size: 52),
        const SizedBox(height: 16),
        const Text('Không thể khởi động bộ điều khiển cục bộ'),
        const SizedBox(height: 12),
        Wrap(spacing: 12, children: [
          FilledButton.icon(onPressed: recoverController, icon: const Icon(Icons.refresh), label: const Text('Thử lại')),
          OutlinedButton.icon(
            onPressed: () => showDialog<void>(context: context, builder: (_) => AlertDialog(
              title: const Text('Cài đặt cục bộ'),
              content: SelectableText(api.config.controllerLauncher.isEmpty
                  ? 'Chưa cấu hình đường dẫn bộ điều khiển.'
                  : api.config.controllerLauncher),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Đóng'))],
            )),
            icon: const Icon(Icons.settings),
            label: const Text('Cài đặt'),
          ),
        ]),
      ])));
    }
    return Scaffold(
        appBar: AppBar(title: const Text('Media Control')),
        body: Row(children: [
          NavigationRail(selectedIndex: selected, labelType: NavigationRailLabelType.all, destinations: destinations, onDestinationSelected: (v) => setState(() => selected = v)),
          const VerticalDivider(width: 1),
          Expanded(child: selectedPage()),
        ]),
      );
  }
}

class PageFrame extends StatelessWidget {
  const PageFrame({super.key, required this.title, required this.child, this.actions = const []});
  final String title;
  final Widget child;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Expanded(child: Text(title, style: Theme.of(context).textTheme.headlineMedium)), ...actions]),
          const SizedBox(height: 18), Expanded(child: child),
        ]),
      );
}

void showError(BuildContext context, Object error) {
  final message = error is SocketException || error is TimeoutException
      ? 'Dịch vụ cục bộ chưa sẵn sàng. Hãy thử lại.'
      : '$error';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key, required this.api});
  final Api api;
  @override State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  Map<String, dynamic>? status;
  bool busy = false;
  @override void initState() { super.initState(); refresh(); }
  Future<void> refresh() async {
    try { final value = await widget.api.host('/host/status'); if (mounted) setState(() => status = value); } catch (e) { if (mounted) showError(context, e); }
  }
  Future<void> action(String value) async {
    setState(() => busy = true);
    try { await widget.api.host('/host/$value', method: 'POST'); await refresh(); } catch (e) { if (mounted) showError(context, e); }
    if (mounted) setState(() => busy = false);
  }
  @override Widget build(BuildContext context) => PageFrame(
    title: 'Tổng quan', actions: [IconButton(onPressed: busy ? null : refresh, icon: const Icon(Icons.refresh))],
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 12, children: [
        FilledButton.icon(onPressed: busy ? null : () => action('start'), icon: const Icon(Icons.power_settings_new), label: const Text('Bật server')),
        OutlinedButton.icon(onPressed: busy ? null : () => action('restart'), icon: const Icon(Icons.restart_alt), label: const Text('Restart')),
        OutlinedButton.icon(onPressed: busy ? null : () => action('stop'), icon: const Icon(Icons.stop_circle_outlined), label: const Text('Tắt server')),
      ]),
      const SizedBox(height: 24), Text('Trạng thái: ${status?['state'] ?? 'đang kiểm tra'}'),
      if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
    ]),
  );
}

class MovieSearchPage extends StatefulWidget {
  const MovieSearchPage({super.key, required this.api});
  final Api api;
  @override State<MovieSearchPage> createState() => _MovieSearchPageState();
}

class _MovieSearchPageState extends State<MovieSearchPage> {
  final query = TextEditingController();
  List<dynamic> movies = [], releases = [];
  Map<String, dynamic>? selected;
  bool busy = false;
  bool showingSearch = false;
  bool stale = false;
  String? error;
  @override void initState() { super.initState(); loadTrending(); }
  Future<void> loadTrending() async {
    try {
      setState(() { busy = true; error = null; selected = null; showingSearch = false; });
      final result = await widget.api.gateway('/v1/movies/trending');
      if (!mounted) return;
      setState(() {
        movies = result is List ? result : (result['items'] ?? []);
        stale = result is Map && result['stale'] == true;
        releases = [];
      });
    } catch (_) {
      if (mounted) setState(() { movies = []; error = 'Chưa tải được phim thịnh hành'; });
    } finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> search() async {
    final term = query.text.trim();
    if (term.isEmpty) return loadTrending();
    try {
      setState(() { busy = true; error = null; selected = null; showingSearch = true; stale = false; });
      final result = await widget.api.gateway('/v1/movies/search?q=${Uri.encodeQueryComponent(term)}');
      if (!mounted) return;
      setState(() { movies = result; releases = []; });
    } catch (_) {
      if (mounted) setState(() { movies = []; error = 'Không thể tìm phim lúc này'; });
    } finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> loadReleases(Map<String, dynamic> movie) async { try { setState(() { selected = movie; busy = true; error = null; releases = []; }); final x = await widget.api.gateway('/v1/movies/${movie['tmdbId']}/releases'); if (!mounted) return; setState(() => releases = x); } catch (e) { if (mounted) setState(() => error = '$e'); } finally { if (mounted) setState(() => busy = false); } }
  Future<void> download(Map<String, dynamic> release) async { try { await widget.api.gateway('/v1/movies/${selected!['tmdbId']}/download', method: 'POST', body: {'guid': release['guid'], 'indexerId': release['indexerId']}); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã gửi bản tải sang Radarr/qBittorrent'))); } catch (e) { if (mounted) showError(context, e); } }
  @override void dispose() { query.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => PageFrame(title: selected == null ? 'Tìm phim' : 'Chi tiết phim', child: selected == null ? Column(children: [
    Row(children: [Expanded(child: TextField(
      controller: query,
      textInputAction: TextInputAction.search,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => search(),
      decoration: InputDecoration(
        labelText: 'Tên phim',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: query.text.isEmpty ? null : IconButton(onPressed: () { query.clear(); loadTrending(); }, icon: const Icon(Icons.clear)),
      ),
    )), const SizedBox(width: 12), FilledButton(onPressed: busy ? null : search, child: const Text('Tìm'))]),
    const SizedBox(height: 12), if (busy) const LinearProgressIndicator(), if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    if (!busy) Align(alignment: Alignment.centerLeft, child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Text(showingSearch ? 'Kết quả tìm kiếm' : 'Đang thịnh hành', style: Theme.of(context).textTheme.titleLarge),
        if (stale) const Padding(padding: EdgeInsets.only(left: 10), child: Chip(label: Text('Dữ liệu gần nhất'))),
      ]),
    )),
    Expanded(child: movies.isEmpty && !busy
      ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(showingSearch ? 'Không tìm thấy phim' : 'Chưa tải được phim thịnh hành'),
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: showingSearch ? search : loadTrending, icon: const Icon(Icons.refresh), label: const Text('Thử lại')),
        ]))
      : LayoutBuilder(builder: (context, constraints) {
          final columns = (constraints.maxWidth / 210).floor().clamp(2, 7);
          return GridView.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns, childAspectRatio: .64, crossAxisSpacing: 12, mainAxisSpacing: 12),
            itemCount: movies.length,
            itemBuilder: (_, index) {
              final movie = Map<String, dynamic>.from(movies[index]);
              return Card(clipBehavior: Clip.antiAlias, child: InkWell(
                onTap: () => loadReleases(movie),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: SizedBox(width: double.infinity, child: movie['poster'] != null
                    ? Image.network(movie['poster'], fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.movie, size: 48)))
                    : const Center(child: Icon(Icons.movie, size: 48)))),
                  Padding(padding: const EdgeInsets.fromLTRB(10, 9, 10, 2), child: Text('${movie['title']} (${movie['year'] ?? ''})', maxLines: 2, overflow: TextOverflow.ellipsis)),
                  Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 9), child: Text(movie['rating'] == null ? 'Nhấn để xem bản tải' : '★ ${movie['rating']}', style: Theme.of(context).textTheme.bodySmall)),
                ]),
              ));
            },
          );
        })),
  ]) : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    TextButton.icon(onPressed: busy ? null : () => setState(() { selected = null; releases = []; error = null; }), icon: const Icon(Icons.arrow_back), label: const Text('Quay lại kết quả')),
    Text('${selected!['title']} (${selected!['year'] ?? ''})', style: Theme.of(context).textTheme.headlineSmall),
    const SizedBox(height: 8), Text(selected!['overview'] ?? 'Không có mô tả', maxLines: 4, overflow: TextOverflow.ellipsis),
    const SizedBox(height: 12), if (busy) const LinearProgressIndicator(),
    if (error != null) Row(children: [Expanded(child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))), OutlinedButton.icon(onPressed: () => loadReleases(selected!), icon: const Icon(Icons.refresh), label: const Text('Thử lại'))]),
    if (!busy && error == null && releases.isEmpty) Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.search_off, size: 48), const SizedBox(height: 12), const Text('Không tìm thấy bản tải phù hợp'), const SizedBox(height: 8), const Text('Hãy kiểm tra indexer trong Prowlarr hoặc thử lại sau.'), const SizedBox(height: 12), OutlinedButton.icon(onPressed: () => loadReleases(selected!), icon: const Icon(Icons.refresh), label: const Text('Tìm lại release'))]))),
    if (releases.isNotEmpty) Expanded(child: ListView(children: releases.map((r) => Card(child: ListTile(title: Text(r['title']), subtitle: Text('${r['quality']} • ${r['codec']} • ${formatBytes(r['size'])} • seed ${r['seeders']}'), trailing: FilledButton(onPressed: r['rejected'] == true ? null : () => download(r), child: const Text('Tải'))))).toList())),
  ]));
}

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.api}); final Api api;
  @override State<DownloadsPage> createState() => _DownloadsPageState();
}
class _DownloadsPageState extends State<DownloadsPage> {
  List<dynamic> items = [];
  @override void initState() { super.initState(); load(); }
  Future<void> load() async { try { final x = await widget.api.gateway('/v1/downloads'); if (mounted) setState(() => items = x); } catch (e) { if (mounted) showError(context, e); } }
  Future<void> act(String hash, String action) async { try { await widget.api.gateway('/v1/downloads/$hash${action == 'delete' ? '' : '/$action'}', method: action == 'delete' ? 'DELETE' : 'POST'); await load(); } catch (e) { if (mounted) showError(context, e); } }
  @override Widget build(BuildContext context) => PageFrame(title: 'Downloads', actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))], child: items.isEmpty ? const Center(child: Text('Chưa có download')) : ListView(children: items.map((x) => Card(child: ListTile(title: Text(x['name']), subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [LinearProgressIndicator(value: (x['progress'] ?? 0) / 100), Text('${x['progress']}% • ${x['state']} • ${formatBytes(x['downloadSpeed'])}/s')]), trailing: Wrap(children: [IconButton(onPressed: () => act(x['hash'], 'pause'), icon: const Icon(Icons.pause)), IconButton(onPressed: () => act(x['hash'], 'resume'), icon: const Icon(Icons.play_arrow)), IconButton(onPressed: () => act(x['hash'], 'delete'), icon: const Icon(Icons.delete_outline))])))).toList()));
}

class SubtitlesPage extends StatefulWidget {
  const SubtitlesPage({super.key, required this.api}); final Api api;
  @override State<SubtitlesPage> createState() => _SubtitlesPageState();
}
class _SubtitlesPageState extends State<SubtitlesPage> {
  String language = 'vi';
  String provider = 'all';
  bool directFallback = false;
  bool directAvailable = false;
  bool busy = false;
  int? mediaId;
  List<dynamic> media = [];
  List<dynamic> results = [];
  @override void initState() { super.initState(); loadMedia(); }
  Future<void> loadMedia() async {
    try {
      final value = await widget.api.gateway('/v1/library/subtitle-media');
      if (!mounted) return;
      setState(() { media = value; if (media.isNotEmpty) mediaId ??= media.first['mediaId']; });
    } catch (e) { if (mounted) showError(context, e); }
  }
  Future<void> search({bool direct = false}) async {
    if (mediaId == null) { showError(context, 'Chưa có phim trong thư viện'); return; }
    setState(() => busy = true);
    try {
      final path = direct
          ? '/v1/library/$mediaId/subtitles/yify/search?language=$language'
          : '/v1/library/$mediaId/subtitles/search?language=$language&provider=$provider&directFallback=$directFallback';
      final value = await widget.api.gateway(path);
      if (!mounted) return;
      setState(() { results = value is List ? value : (value['data'] ?? []); directAvailable = value is Map && value['directEnabled'] == true; });
    } catch (e) { if (mounted) showError(context, e); }
    finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> choose(dynamic subtitle) async {
    try {
      await widget.api.gateway('/v1/library/$mediaId/subtitles/download', method: 'POST', body: {'downloadToken': subtitle['downloadToken']});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã tải phụ đề')));
    } catch (e) { if (mounted) showError(context, e); }
  }
  Future<void> refresh() async { if (mediaId == null) return; try { await widget.api.gateway('/v1/library/$mediaId/subtitles/refresh', method: 'POST'); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã quét lại phụ đề'))); } catch (e) { if (mounted) showError(context, e); } }
  @override Widget build(BuildContext context) => PageFrame(title: 'Phụ đề', child: Column(children: [
    Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SizedBox(width: 300, child: DropdownButtonFormField<int>(initialValue: mediaId, decoration: const InputDecoration(labelText: 'Phim trong thư viện'), items: media.map<DropdownMenuItem<int>>((m) => DropdownMenuItem(value: m['mediaId'], child: Text('${m['title']} (${m['year']})', overflow: TextOverflow.ellipsis))).toList(), onChanged: (v) => setState(() { mediaId = v; results = []; }))),
      DropdownButton(value: language, items: const [DropdownMenuItem(value: 'vi', child: Text('Tiếng Việt')), DropdownMenuItem(value: 'en', child: Text('English'))], onChanged: (v) => setState(() => language = v!)),
      DropdownButton(value: provider, items: const [DropdownMenuItem(value: 'all', child: Text('Tất cả provider')), DropdownMenuItem(value: 'bazarr', child: Text('Bazarr')), DropdownMenuItem(value: 'yifysubtitles', child: Text('YIFY qua Bazarr')), DropdownMenuItem(value: 'gestdown', child: Text('Gestdown')), DropdownMenuItem(value: 'yify-direct', child: Text('YIFY Direct'))], onChanged: (v) => setState(() => provider = v!)),
      Row(mainAxisSize: MainAxisSize.min, children: [Switch(value: directFallback, onChanged: (v) => setState(() => directFallback = v)), const Text('Cho phép YIFY Direct fallback')]),
      FilledButton(onPressed: busy ? null : () => search(), child: const Text('Tìm qua Bazarr')),
      OutlinedButton(onPressed: busy ? null : () => search(direct: true), child: const Text('Tìm trực tiếp YIFY')),
      IconButton(onPressed: refresh, tooltip: 'Quét lại', icon: const Icon(Icons.refresh)),
    ]),
    if (!directAvailable && directFallback) const Align(alignment: Alignment.centerLeft, child: Text('YIFY Direct đang tắt trong cấu hình backend.', style: TextStyle(color: Colors.amber))),
    const SizedBox(height: 12), if (busy) const LinearProgressIndicator(),
    Expanded(child: results.isEmpty ? const Center(child: Text('Chọn phim, ngôn ngữ và nguồn để tìm')) : ListView(children: results.map((s) => Card(child: ListTile(title: Text(s['release'] ?? 'Subtitle'), subtitle: Text('${s['provider'] ?? ''} • ${s['language'] ?? ''} • ${s['format'] ?? ''} • score ${s['score'] ?? ''}${s['hearingImpaired'] == true ? ' • HI' : ''}'), trailing: FilledButton(onPressed: s['downloadToken'] == null ? null : () => choose(s), child: const Text('Tải'))))).toList())),
  ]));
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.api}); final Api api;
  @override State<LibraryPage> createState() => _LibraryPageState();
}
class _LibraryPageState extends State<LibraryPage> {
  List<dynamic> items = [];
  @override void initState() { super.initState(); load(); }
  Future<void> load() async { try { final x = await widget.api.gateway('/v1/library'); if (mounted) setState(() => items = x is List ? x : (x['Items'] ?? [])); } catch (e) { if (mounted) showError(context, e); } }
  Future<void> openJellyfin() => Process.start('cmd', ['/c', 'start', '', 'http://localhost:8096'], runInShell: true);
  @override Widget build(BuildContext context) => PageFrame(title: 'Thư viện', actions: [FilledButton.icon(onPressed: openJellyfin, icon: const Icon(Icons.open_in_new), label: const Text('Mở Jellyfin')), IconButton(onPressed: load, icon: const Icon(Icons.refresh))], child: items.isEmpty ? const Center(child: Text('Thư viện đang trống')) : GridView.extent(maxCrossAxisExtent: 260, childAspectRatio: 1.5, children: items.map((x) => Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(x['Name'] ?? '', style: Theme.of(context).textTheme.titleMedium), const Spacer(), Text((x['UserData']?['PlaybackPositionTicks'] ?? 0) > 0 ? 'Đang xem' : 'Chưa xem')])))).toList()));
}

class ServicesPage extends StatefulWidget {
  const ServicesPage({super.key, required this.api}); final Api api;
  @override State<ServicesPage> createState() => _ServicesPageState();
}
class _ServicesPageState extends State<ServicesPage> {
  List<dynamic> items = [];
  @override void initState() { super.initState(); load(); }
  Future<void> load() async { try { final x = await widget.api.host('/host/services'); if (mounted) setState(() => items = x); } catch (e) { if (mounted) showError(context, e); } }
  Future<void> act(String id, String action) async { try { await widget.api.host('/host/services/$id/$action', method: 'POST'); await load(); } catch (e) { if (mounted) showError(context, e); } }
  Future<void> logs(String id) async { try { final x = await widget.api.host('/host/services/$id/logs'); if (mounted) showDialog(context: context, builder: (_) => AlertDialog(title: Text('Log: $id'), content: SizedBox(width: 760, child: SingleChildScrollView(child: SelectableText(x['logs'] ?? ''))), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Đóng'))])); } catch (e) { if (mounted) showError(context, e); } }
  @override Widget build(BuildContext context) => PageFrame(title: 'Services', actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))], child: ListView(children: items.map((x) => Card(child: ListTile(leading: Icon(Icons.circle, color: x['state'] == 'running' ? Colors.green : Colors.grey, size: 14), title: Text(x['id']), subtitle: Text('${x['state']} • ${x['health'] ?? ''}'), trailing: Wrap(children: [IconButton(onPressed: () => logs(x['id']), tooltip: 'Xem log', icon: const Icon(Icons.article_outlined)), IconButton(onPressed: () => act(x['id'], 'start'), icon: const Icon(Icons.play_arrow)), IconButton(onPressed: () => act(x['id'], 'restart'), icon: const Icon(Icons.restart_alt)), IconButton(onPressed: () => act(x['id'], 'stop'), icon: const Icon(Icons.stop))])))).toList()));
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.config}); final LocalConfig config;
  @override Widget build(BuildContext context) => PageFrame(title: 'Cài đặt', child: ListView(children: [ListTile(title: const Text('Gateway'), subtitle: Text(config.gateway)), ListTile(title: const Text('Host controller'), subtitle: Text(config.controller)), const ListTile(title: Text('Media root'), subtitle: Text('D:\\Media')), const ListTile(title: Text('Tài khoản local'), subtitle: Text('admin / •••••••••'))]));
}

String formatBytes(dynamic value) {
  final n = (value ?? 0) as num;
  if (n >= 1073741824) return '${(n / 1073741824).toStringAsFixed(1)} GB';
  if (n >= 1048576) return '${(n / 1048576).toStringAsFixed(1)} MB';
  if (n >= 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${n.toInt()} B';
}
