import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_control/controller_bootstrap.dart';
import 'package:media_control/unified_search_controller.dart';

List<String> actionableReleaseSources(List<dynamic> releases) {
  final sources = <String>[];
  for (final value in releases) {
    if (value is! Map || value['downloadable'] == false) continue;
    final source = '${value['source'] ?? 'Prowlarr'}';
    if (!sources.contains(source)) sources.add(source);
  }
  return sources;
}

void main() => runApp(const MediaControlApp());

class MediaControlApp extends StatelessWidget {
  const MediaControlApp({super.key, this.api, this.bootstrapper});
  final Api? api;
  final ControllerBootstrapper? bootstrapper;
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Media Control',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          colorScheme: ColorScheme.dark(
            primary: Color(0xFF0066CC),
            secondary: Color(0xFF00A859),
            surface: Color(0xFF121212),
            onSurface: Color(0xFFE0E0E0),
            surfaceVariant: Color(0xFF1E1E1E),
            onSurfaceVariant: Color(0xFFBBBBBB),
          ),
          textTheme: const TextTheme(
            bodyLarge: TextStyle(fontSize: 16, color: Colors.white70),
            labelLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              textStyle: TextStyle(fontSize: 16),
              backgroundColor: Color(0xFF0066CC),
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
          iconTheme: const IconThemeData(color: Colors.white70),
        ),
        home: MediaShell(api: api, bootstrapper: bootstrapper),
      );
}

class LocalConfig {
  const LocalConfig(
      {this.gateway = 'http://localhost:3000',
      this.controller = 'http://127.0.0.1:3210',
      this.token = 'media-control-local',
      this.controllerLauncher = ''});
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
  Future<dynamic> request(String base, String path,
      {String method = 'GET', Object? body}) async {
    final headers = <String, String>{'content-type': 'application/json'};
    if (base == config.controller) {
      headers['authorization'] = 'Bearer ${config.token}';
    }
    final request = http.Request(method, Uri.parse('$base$path'))
      ..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    final response = await request.send();
    final text = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(text.isEmpty ? 'HTTP ${response.statusCode}' : text);
    }
    return text.isEmpty ? null : jsonDecode(text);
  }

  Future<dynamic> gateway(String path, {String method = 'GET', Object? body}) =>
      request(config.gateway, path, method: method, body: body);
  Future<dynamic> host(String path, {String method = 'GET'}) =>
      request(config.controller, path, method: method);
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
    NavigationRailDestination(
        icon: Icon(Icons.dashboard_outlined),
        selectedIcon: Icon(Icons.dashboard),
        label: Text('Tổng quan')),
    NavigationRailDestination(
        icon: Icon(Icons.search), label: Text('Khám phá')),
    NavigationRailDestination(
        icon: Icon(Icons.downloading_outlined),
        selectedIcon: Icon(Icons.downloading),
        label: Text('Downloads')),
    NavigationRailDestination(
        icon: Icon(Icons.subtitles_outlined),
        selectedIcon: Icon(Icons.subtitles),
        label: Text('Phụ đề')),
    NavigationRailDestination(
        icon: Icon(Icons.video_library_outlined),
        selectedIcon: Icon(Icons.video_library),
        label: Text('Thư viện')),
    NavigationRailDestination(
        icon: Icon(Icons.dns_outlined),
        selectedIcon: Icon(Icons.dns),
        label: Text('Services')),
    NavigationRailDestination(
        icon: Icon(Icons.settings_outlined),
        selectedIcon: Icon(Icons.settings),
        label: Text('Cài đặt')),
  ];
  @override
  void initState() {
    super.initState();
    api = widget.api ?? Api(LocalConfig.load());
    bootstrapper = widget.bootstrapper ??
        ControllerBootstrapper(
          probe: () async {
            await api.host('/host/status').timeout(const Duration(seconds: 2));
            return true;
          },
          launch: () async {
            final launcher = api.config.controllerLauncher;
            if (launcher.isEmpty) {
              throw StateError('controller launcher is not configured');
            }
            final process = await Process.start(
              'powershell.exe',
              [
                '-NoProfile',
                '-WindowStyle',
                'Hidden',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                launcher
              ],
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
        1 => DiscoveryPage(api: api),
        2 => DownloadsPage(api: api),
        3 => SubtitlesPage(api: api),
        4 => LibraryPage(api: api),
        5 => ServicesPage(api: api),
        _ => SettingsPage(api: api),
      };

  @override
  Widget build(BuildContext context) {
    if (controllerState == null) {
      return const Scaffold(
          body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('Đang kết nối bộ điều khiển…'),
      ])));
    }
    if (controllerState == ControllerStartupResult.failed) {
      return Scaffold(
          body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.desktop_access_disabled, size: 52),
        const SizedBox(height: 16),
        const Text('Không thể khởi động bộ điều khiển cục bộ'),
        const SizedBox(height: 12),
        Wrap(spacing: 12, children: [
          FilledButton.icon(
              onPressed: recoverController,
              icon: const Icon(Icons.refresh),
              label: const Text('Thử lại')),
          OutlinedButton.icon(
            onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                      title: const Text('Cài đặt cục bộ'),
                      content: SelectableText(
                          api.config.controllerLauncher.isEmpty
                              ? 'Chưa cấu hình đường dẫn bộ điều khiển.'
                              : api.config.controllerLauncher),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Đóng'))
                      ],
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
        NavigationRail(
            selectedIndex: selected,
            labelType: NavigationRailLabelType.all,
            destinations: destinations,
            onDestinationSelected: (v) => setState(() => selected = v)),
        const VerticalDivider(width: 1),
        Expanded(child: selectedPage()),
      ]),
    );
  }
}

class PageFrame extends StatelessWidget {
  const PageFrame(
      {super.key,
      required this.title,
      required this.child,
      this.actions = const []});
  final String title;
  final Widget child;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(title,
                    style: Theme.of(context).textTheme.headlineMedium)),
            ...actions
          ]),
          const SizedBox(height: 18),
          Expanded(child: child),
        ]),
      );
}

void showError(BuildContext context, Object error) {
  final message = error is SocketException || error is TimeoutException
      ? 'Dịch vụ cục bộ chưa sẵn sàng. Hãy thử lại.'
      : '$error';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

String friendlyDownloadError(Object error) {
  final value = '$error'.toLowerCase();
  if (value.contains('qbittorrent') ||
      value.contains('download_client_rejected')) {
    return 'qBittorrent chưa nhận bản tải. Hãy kiểm tra Downloads rồi thử lại.';
  }
  return 'Không thể gửi bản tải lúc này. Hãy thử lại.';
}

class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key, required this.api});
  final Api api;
  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  Map<String, dynamic>? status;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final value = await widget.api.host('/host/status');
      if (mounted) setState(() => status = value);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> action(String value) async {
    setState(() => busy = true);
    try {
      await widget.api.host('/host/$value', method: 'POST');
      await refresh();
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => PageFrame(
        title: 'Tổng quan',
        actions: [
          IconButton(
              onPressed: busy ? null : refresh, icon: const Icon(Icons.refresh))
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 12, children: [
            FilledButton.icon(
                onPressed: busy ? null : () => action('start'),
                icon: const Icon(Icons.power_settings_new),
                label: const Text('Bật server')),
            OutlinedButton.icon(
                onPressed: busy ? null : () => action('restart'),
                icon: const Icon(Icons.restart_alt),
                label: const Text('Restart')),
            OutlinedButton.icon(
                onPressed: busy ? null : () => action('stop'),
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Tắt server')),
          ]),
          const SizedBox(height: 24),
          Text('Trạng thái: ${status?['state'] ?? 'đang kiểm tra'}'),
          if (busy)
            const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator()),
        ]),
      );
}

class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({super.key, required this.api});
  final Api api;
  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends State<DiscoveryPage> {
  int tab = 0;
  final searchField = TextEditingController();
  final movieKey = GlobalKey<_MovieSearchPageState>();
  final seriesKey = GlobalKey<_SeriesSearchPageState>();
  late final UnifiedSearchController unified = UnifiedSearchController(
      search: (query) => widget.api.gateway(
          '/v1/discover/search?q=${Uri.encodeQueryComponent(query)}&limit=8'));

  @override
  void dispose() {
    searchField.dispose();
    unified.dispose();
    super.dispose();
  }

  void openResult(dynamic item) {
    final isSeries = item['mediaType'] == 'series';
    final selectedItem = Map<String, dynamic>.from(item as Map);
    searchField.clear();
    unified.updateQuery('');
    setState(() => tab = isSeries ? 1 : 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isSeries) {
        seriesKey.currentState?.openFromUnified(selectedItem);
      } else {
        movieKey.currentState?.openFromUnified(selectedItem);
      }
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: unified,
      builder: (context, _) => Column(children: [
            Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: Column(children: [
                  TextField(
                      controller: searchField,
                      onChanged: unified.updateQuery,
                      onSubmitted: (_) {
                        if (unified.items.isNotEmpty) {
                          openResult(unified.items.first);
                        }
                      },
                      decoration: InputDecoration(
                          hintText:
                              'Tìm phim, TV Show, tên khác, diễn viên, đạo diễn, studio…',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: unified.loading
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2)))
                              : searchField.text.isEmpty
                                  ? null
                                  : IconButton(
                                      icon: const Icon(Icons.clear),
                                      onPressed: () {
                                        searchField.clear();
                                        unified.updateQuery('');
                                        setState(() {});
                                      }))),
                  if (unified.partial)
                    const Align(
                        alignment: Alignment.centerLeft,
                        child: Chip(label: Text('Một số nguồn chưa phản hồi'))),
                  if (searchField.text.isEmpty && unified.recent.isNotEmpty)
                    Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                            spacing: 8,
                            children: unified.recent
                                .map((value) => ActionChip(
                                    avatar: const Icon(Icons.history, size: 16),
                                    label: Text(value),
                                    onPressed: () {
                                      searchField.text = value;
                                      unified.updateQuery(value);
                                      setState(() {});
                                    }))
                                .toList())),
                  if (searchField.text.length >= 2 && unified.items.isNotEmpty)
                    Card(
                        child: Column(
                            children: unified.items
                                .take(8)
                                .map((item) => ListTile(
                                    leading: item['poster'] == null
                                        ? const Icon(
                                            Icons.image_not_supported_outlined)
                                        : Image.network(item['poster'],
                                            width: 38,
                                            height: 54,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) =>
                                                const Icon(Icons
                                                    .image_not_supported_outlined)),
                                    title: Text(
                                        '${item['title']} (${item['year'] ?? ''})'),
                                    subtitle: Text(
                                        '${item['mediaType'] == 'series' ? 'TV Show' : 'Phim'} • Khớp ${item['matchedBy'] ?? 'tiêu đề'}: ${item['matchedText'] ?? item['title']}'),
                                    onTap: () => openResult(item)))
                                .toList()))
                ])),
            Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(
                          value: 0,
                          label: Text('Phim'),
                          icon: Icon(Icons.movie)),
                      ButtonSegment(
                          value: 1,
                          label: Text('TV Show'),
                          icon: Icon(Icons.tv))
                    ],
                    selected: {
                      tab
                    },
                    onSelectionChanged: (value) =>
                        setState(() => tab = value.first))),
            Expanded(
                child: tab == 0
                    ? MovieSearchPage(key: movieKey, api: widget.api)
                    : SeriesSearchPage(key: seriesKey, api: widget.api))
          ]));
}

class _ReleaseSourceSelector extends StatelessWidget {
  const _ReleaseSourceSelector({
    required this.releases,
    required this.selected,
    required this.onSelected,
  });

  final List<dynamic> releases;
  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final sources = actionableReleaseSources(releases);
    return Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
                children: sources
                    .map((source) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                            label: Text(
                                '$source (${releases.where((r) => r['source'] == source && r['downloadable'] != false).length})'),
                            selected: selected == source,
                            onSelected: (_) => onSelected(source))))
                    .toList())));
  }
}

class MovieSearchPage extends StatefulWidget {
  const MovieSearchPage({super.key, required this.api});
  final Api api;
  @override
  State<MovieSearchPage> createState() => _MovieSearchPageState();
}

class _MovieSearchPageState extends State<MovieSearchPage> {
  final query = TextEditingController();
  List<dynamic> movies = [], releases = [];
  Map<String, dynamic>? selected;
  bool busy = false;
  bool showingSearch = false;
  bool stale = false;
  String? selectedReleaseSource;
  String trendingSource = 'unavailable';
  String? error;
  @override
  void initState() {
    super.initState();
    loadTrending();
  }

  Future<void> loadTrending() async {
    try {
      setState(() {
        busy = true;
        error = null;
        selected = null;
        showingSearch = false;
      });
      final result = await widget.api.gateway('/v1/movies/trending');
      if (!mounted) return;
      setState(() {
        movies = result is List ? result : (result['items'] ?? []);
        stale = result is Map && result['stale'] == true;
        trendingSource =
            result is Map ? '${result['source'] ?? 'unavailable'}' : 'seerr';
        releases = [];
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          movies = [];
          error = 'Chưa tải được phim thịnh hành';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> search() async {
    final term = query.text.trim();
    if (term.isEmpty) return loadTrending();
    try {
      setState(() {
        busy = true;
        error = null;
        selected = null;
        showingSearch = true;
        stale = false;
      });
      final result = await widget.api
          .gateway('/v1/movies/search?q=${Uri.encodeQueryComponent(term)}');
      if (!mounted) return;
      setState(() {
        movies = result;
        releases = [];
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          movies = [];
          error = 'Không thể tìm phim lúc này';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void searchFor(String value) {
    query.text = value;
    search();
  }

  void openFromUnified(Map<String, dynamic> movie) {
    query.text = '${movie['title'] ?? ''}';
    loadReleases(movie);
  }

  Future<void> loadReleases(Map<String, dynamic> movie,
      {bool refresh = false}) async {
    try {
      setState(() {
        selected = movie;
        busy = true;
        error = null;
        releases = [];
      });
      var target = movie;
      if ((movie['tmdbId'] ?? 0) == 0) {
        final matches = await widget.api.gateway(
            '/v1/movies/search?q=${Uri.encodeQueryComponent(movie['title'])}');
        final exact = (matches as List)
            .where((item) => item['year'] == movie['year'])
            .toList();
        if (exact.isEmpty) {
          throw Exception('Không ánh xạ được phim YTS sang Radarr');
        }
        target = Map<String, dynamic>.from(exact.first);
        if (mounted) setState(() => selected = target);
      }
      final x = await widget.api.gateway(
          '/v1/movies/${target['tmdbId']}/releases${refresh ? '?refresh=true' : ''}');
      if (!mounted) return;
      setState(() {
        releases = x;
        selectedReleaseSource = actionableReleaseSources(x).firstOrNull;
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> download(Map<String, dynamic> release) async {
    try {
      final result = await widget.api.gateway(
          '/v1/movies/${selected!['tmdbId']}/download',
          method: 'POST',
          body: {'guid': release['guid'], 'indexerId': release['indexerId']});
      if (mounted) {
        final duplicate = result is Map && result['duplicate'] == true;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(duplicate
                ? 'Bản tải này đã có trong Downloads'
                : 'Đã gửi bản tải sang Radarr/qBittorrent')));
      }
    } catch (e) {
      if (mounted) showError(context, friendlyDownloadError(e));
    }
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageFrame(
      title: selected == null ? 'Tìm phim' : 'Chi tiết phim',
      child: selected == null
          ? Column(children: [
              Row(children: [
                Expanded(
                    child: TextField(
                  controller: query,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => search(),
                  decoration: InputDecoration(
                    labelText: 'Tên phim',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: query.text.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              query.clear();
                              loadTrending();
                            },
                            icon: const Icon(Icons.clear)),
                  ),
                )),
                const SizedBox(width: 12),
                FilledButton(
                    onPressed: busy ? null : search, child: const Text('Tìm'))
              ]),
              const SizedBox(height: 12),
              if (busy) const LinearProgressIndicator(),
              if (error != null)
                Text(error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              if (!busy)
                Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(children: [
                        Text(
                            showingSearch
                                ? 'Kết quả tìm kiếm'
                                : 'Đang thịnh hành',
                            style: Theme.of(context).textTheme.titleLarge),
                        if (stale)
                          const Padding(
                              padding: EdgeInsets.only(left: 10),
                              child: Chip(label: Text('Dữ liệu gần nhất'))),
                        if (!stale && trendingSource == 'yts')
                          const Padding(
                              padding: EdgeInsets.only(left: 10),
                              child: Chip(label: Text('Phổ biến trên YTS'))),
                      ]),
                    )),
              Expanded(
                  child: movies.isEmpty && !busy
                      ? Center(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(showingSearch
                              ? 'Không tìm thấy phim'
                              : 'Chưa tải được phim thịnh hành'),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                              onPressed: showingSearch ? search : loadTrending,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Thử lại')),
                        ]))
                      : LayoutBuilder(builder: (context, constraints) {
                          final columns =
                              (constraints.maxWidth / 210).floor().clamp(2, 7);
                          return GridView.builder(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    childAspectRatio: .64,
                                    crossAxisSpacing: 12,
                                    mainAxisSpacing: 12),
                            itemCount: movies.length,
                            itemBuilder: (_, index) {
                              final movie =
                                  Map<String, dynamic>.from(movies[index]);
                              return Card(
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: () => loadReleases(movie),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                              child: SizedBox(
                                                  width: double.infinity,
                                                  child: movie['poster'] != null
                                                      ? Image.network(
                                                          movie['poster'],
                                                          fit: BoxFit.cover,
                                                          errorBuilder: (_, __, ___) =>
                                                              const Center(
                                                                  child: Icon(
                                                                      Icons
                                                                          .movie,
                                                                      size:
                                                                          48)))
                                                      : const Center(
                                                          child: Icon(
                                                              Icons.movie,
                                                              size: 48)))),
                                          Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                      10, 9, 10, 2),
                                              child: Text(
                                                  '${movie['title']} (${movie['year'] ?? ''})',
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis)),
                                          Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                      10, 0, 10, 9),
                                              child: Text(
                                                  movie['rating'] == null
                                                      ? 'Nhấn để xem bản tải'
                                                      : '★ ${movie['rating']}',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall)),
                                        ]),
                                  ));
                            },
                          );
                        })),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextButton.icon(
                  onPressed: busy
                      ? null
                      : () => setState(() {
                            selected = null;
                            releases = [];
                            error = null;
                          }),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Quay lại kết quả')),
              Text('${selected!['title']} (${selected!['year'] ?? ''})',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(selected!['overview'] ?? 'Không có mô tả',
                  maxLines: 4, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 12),
              if (busy) const LinearProgressIndicator(),
              if (error != null)
                Row(children: [
                  Expanded(
                      child: Text(error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
                  OutlinedButton.icon(
                      onPressed: () => loadReleases(selected!, refresh: true),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Thử lại'))
                ]),
              if (!busy && error == null && releases.isEmpty)
                Expanded(
                    child: Center(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.search_off, size: 48),
                  const SizedBox(height: 12),
                  const Text('Không tìm thấy bản tải phù hợp'),
                  const SizedBox(height: 8),
                  const Text(
                      'Nguồn đang bật chưa có bản tải cho đúng nội dung này.'),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                      onPressed: () => loadReleases(selected!, refresh: true),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Tìm lại release'))
                ]))),
              if (releases.isNotEmpty)
                Expanded(
                    child: Column(children: [
                  _ReleaseSourceSelector(
                      releases: releases,
                      selected: selectedReleaseSource,
                      onSelected: (source) =>
                          setState(() => selectedReleaseSource = source)),
                  Expanded(
                      child: ListView(
                          children: releases
                              .where((r) =>
                                  r['downloadable'] != false &&
                                  r['source'] == selectedReleaseSource)
                              .map((r) => Card(
                                  child: ListTile(
                                      title: Text(r['title']),
                                      subtitle: Text(
                                          '${r['quality']} • ${r['codec']} • ${formatBytes(r['size'])} • seed ${r['seeders']}'),
                                      trailing: FilledButton(
                                          onPressed: r['downloadable'] == false
                                              ? null
                                              : () => download(r),
                                          child: const Text('Tải')))))
                              .toList()))
                ])),
            ]));
}

class SeriesSearchPage extends StatefulWidget {
  const SeriesSearchPage({super.key, required this.api});
  final Api api;
  @override
  State<SeriesSearchPage> createState() => _SeriesSearchPageState();
}

class _SeriesSearchPageState extends State<SeriesSearchPage> {
  final query = TextEditingController();
  List<dynamic> series = [], trending = [], episodes = [], releases = [];
  Map<String, dynamic>? selected;
  int? selectedSeason;
  int? releaseEpisodeId;
  bool busy = false;
  bool showingEpisodes = false;
  bool showingSearch = false;
  bool trendingStale = false;
  String? selectedReleaseSource;
  String trendingSource = 'unavailable';
  String? error;

  @override
  void initState() {
    super.initState();
    loadTrending();
  }

  Future<void> loadTrending() async {
    setState(() {
      busy = true;
      error = null;
      showingSearch = false;
    });
    try {
      final result = await widget.api.gateway('/v1/series/trending');
      if (!mounted) return;
      setState(() {
        trending = result is List ? result : (result['items'] ?? []);
        trendingStale = result is Map && result['stale'] == true;
        trendingSource = result is Map
            ? '${result['source'] ?? 'unavailable'}'
            : 'unavailable';
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          trending = [];
          error = 'Chưa tải được TV Show thịnh hành';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> search() async {
    final term = query.text.trim();
    if (term.isEmpty) return loadTrending();
    setState(() {
      busy = true;
      error = null;
      selected = null;
      showingSearch = true;
    });
    try {
      final value = await widget.api
          .gateway('/v1/series/search?q=${Uri.encodeQueryComponent(term)}');
      if (mounted) setState(() => series = value);
    } catch (_) {
      if (mounted) setState(() => error = 'Không thể tìm TV show lúc này');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void searchFor(String value) {
    query.text = value;
    search();
  }

  void openFromUnified(Map<String, dynamic> item) {
    query.text = '${item['title'] ?? ''}';
    openSeries(item);
  }

  Future<void> openSeries(Map<String, dynamic> item) async {
    setState(() {
      selected = item;
      busy = true;
      error = null;
      releases = [];
    });
    try {
      var target = item;
      if ((item['tvdbId'] ?? 0) == 0) {
        final matches = await widget.api.gateway(
            '/v1/series/search?q=${Uri.encodeQueryComponent(item['title'])}');
        final exact = (matches as List)
            .where((candidate) => candidate['year'] == item['year'])
            .toList();
        if (exact.isEmpty) {
          throw Exception('Không ánh xạ được TV Show sang Sonarr');
        }
        target = Map<String, dynamic>.from(exact.first);
        if (mounted) setState(() => selected = target);
      }
      final value =
          await widget.api.gateway('/v1/series/${target['tvdbId']}/episodes');
      if (!mounted) return;
      final values = value as List;
      final seasons = values
          .map((episode) => episode['seasonNumber'] as int)
          .where((number) => number > 0)
          .toSet()
          .toList()
        ..sort();
      setState(() {
        episodes = values;
        selectedSeason = seasons.isEmpty ? null : seasons.first;
      });
      if (selectedSeason != null) await findReleases();
    } catch (_) {
      if (mounted) setState(() => error = 'Không tải được danh sách tập');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> findReleases({int? episodeId, bool refresh = false}) async {
    if (episodeId == null && selectedSeason == null) return;
    setState(() {
      busy = true;
      error = null;
      releases = [];
      releaseEpisodeId = episodeId;
      showingEpisodes = false;
    });
    final scope = episodeId == null
        ? 'seasonNumber=$selectedSeason'
        : 'episodeId=$episodeId';
    try {
      final value = await widget.api.gateway(
          '/v1/series/${selected!['tvdbId']}/releases?$scope${refresh ? '&refresh=true' : ''}');
      if (mounted) {
        setState(() {
          releases = value;
          selectedReleaseSource = actionableReleaseSources(value).firstOrNull;
        });
      }
    } catch (exception) {
      if (mounted) {
        setState(() {
          if (episodeId == null) showingEpisodes = true;
          error = '$exception'.contains('tv_release_unavailable') ||
                  '$exception'.contains('yts_tv_release_unavailable') ||
                  '$exception'.contains('season_pack_unavailable')
              ? 'Không có season pack. Hãy chọn từng tập bên dưới.'
              : '$exception'.contains('tv_provider_unavailable') ||
                      '$exception'.contains('release_sources_unavailable') ||
                      '$exception'.contains('yts_tv_provider_unavailable')
                  ? 'Các nguồn TV đang tạm thời không kết nối được. Hãy thử lại.'
                  : 'Không tìm thấy bản tải phù hợp';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> download(dynamic release) async {
    try {
      final result = await widget.api.gateway(
          '/v1/series/${selected!['tvdbId']}/download',
          method: 'POST',
          body: {
            'downloadToken': release['downloadToken'],
            if (releaseEpisodeId != null) 'episodeId': releaseEpisodeId,
            if (releaseEpisodeId == null && selectedSeason != null)
              'seasonNumber': selectedSeason,
          });
      if (mounted) {
        final duplicate = result is Map && result['duplicate'] == true;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(duplicate
                ? 'Bản tải này đã có trong Downloads'
                : 'Đã gửi sang Sonarr/qBittorrent')));
      }
    } catch (exception) {
      if (mounted) showError(context, friendlyDownloadError(exception));
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
      title: selected == null ? 'Tìm TV Show' : 'Chi tiết TV Show',
      child: selected == null ? searchView() : detailView());

  Widget searchView() => Column(children: [
        Row(children: [
          Expanded(
              child: TextField(
                  controller: query,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => search(),
                  decoration: InputDecoration(
                      labelText: 'Tên TV show',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: query.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                query.clear();
                                loadTrending();
                              },
                              icon: const Icon(Icons.clear))))),
          const SizedBox(width: 12),
          FilledButton(
              onPressed: busy ? null : search, child: const Text('Tìm'))
        ]),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Text(error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (!busy)
          Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(children: [
                    Text(showingSearch ? 'Kết quả tìm kiếm' : 'Đang thịnh hành',
                        style: Theme.of(context).textTheme.titleLarge),
                    if (trendingStale && !showingSearch)
                      const Padding(
                          padding: EdgeInsets.only(left: 10),
                          child: Chip(label: Text('Dữ liệu gần nhất'))),
                    if (!trendingStale &&
                        !showingSearch &&
                        trendingSource == 'popular')
                      const Padding(
                          padding: EdgeInsets.only(left: 10),
                          child:
                              Chip(label: Text('Phổ biến trên YTS Official'))),
                  ]))),
        Expanded(
            child: (showingSearch ? series : trending).isEmpty
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(showingSearch
                        ? 'Không tìm thấy TV Show'
                        : 'Chưa tải được TV Show thịnh hành'),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                        onPressed: showingSearch ? search : loadTrending,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Thử lại')),
                  ]))
                : LayoutBuilder(builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 1100
                        ? 6
                        : constraints.maxWidth >= 760
                            ? 4
                            : constraints.maxWidth >= 480
                                ? 3
                                : 2;
                    final items = showingSearch ? series : trending;
                    return GridView.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            childAspectRatio: .62,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12),
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final item = items[index];
                          return Card(
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                  onTap: () => openSeries(
                                      Map<String, dynamic>.from(item)),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                            child:
                                                _seriesPoster(item['poster'])),
                                        Padding(
                                            padding: const EdgeInsets.all(10),
                                            child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                      '${item['title']} (${item['year'] ?? ''})',
                                                      maxLines: 2,
                                                      overflow: TextOverflow
                                                          .ellipsis),
                                                  if (item['rating'] != null)
                                                    Text('★ ${item['rating']}',
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .bodySmall),
                                                  if (item['inLibrary'] == true)
                                                    const Text(
                                                        'Trong thư viện'),
                                                ])),
                                      ])));
                        });
                  }))
      ]);

  Widget _seriesPoster(dynamic url) => url == null || '$url'.isEmpty
      ? const Center(child: Icon(Icons.image_not_supported_outlined, size: 44))
      : Image.network('$url',
          width: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.image_not_supported_outlined, size: 44)));

  Widget detailView() {
    final seasonNumbers = episodes
        .map((episode) => episode['seasonNumber'] as int)
        .where((number) => number > 0)
        .toSet()
        .toList()
      ..sort();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextButton.icon(
          onPressed: () => setState(() {
                selected = null;
                releases = [];
              }),
          icon: const Icon(Icons.arrow_back),
          label: const Text('Quay lại kết quả')),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 150, height: 210, child: _seriesPoster(selected!['poster'])),
        const SizedBox(width: 18),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${selected!['title']} (${selected!['year'] ?? ''})',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text('${selected!['overview'] ?? ''}',
              maxLines: 6, overflow: TextOverflow.ellipsis),
        ])),
      ]),
      const SizedBox(height: 8),
      Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<int>(
                value: selectedSeason,
                items: seasonNumbers
                    .map((number) => DropdownMenuItem(
                        value: number, child: Text('Season $number')))
                    .toList(),
                onChanged: (value) {
                  setState(() {
                    selectedSeason = value;
                    releases = [];
                    showingEpisodes = false;
                  });
                  if (value != null) findReleases();
                }),
          ]),
      if (busy) const LinearProgressIndicator(),
      if (error != null)
        Row(children: [
          Expanded(
              child: Text(error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
          OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () =>
                      findReleases(episodeId: releaseEpisodeId, refresh: true),
              icon: const Icon(Icons.refresh),
              label: const Text('Thử lại')),
        ]),
      Expanded(
          child: releases.isNotEmpty && !showingEpisodes
              ? Column(children: [
                  _ReleaseSourceSelector(
                      releases: releases,
                      selected: selectedReleaseSource,
                      onSelected: (source) =>
                          setState(() => selectedReleaseSource = source)),
                  Expanded(
                      child: ListView(
                          children: releases
                              .where((release) =>
                                  release['downloadable'] != false &&
                                  release['source'] == selectedReleaseSource)
                              .map((release) => Card(
                                  child: ListTile(
                                      title: Row(children: [
                                        Expanded(child: Text(release['title'])),
                                        Chip(
                                            label: Text(
                                                '${release['source'] ?? 'Prowlarr'}')),
                                      ]),
                                      subtitle: Text(
                                          '${release['quality']} • ${release['codec']} • ${formatBytes(release['size'])} • seed ${release['seeders']} • peer ${release['peers'] ?? 0}${release['rejections'] is List && release['rejections'].isNotEmpty ? ' • ${release['rejections'].join(', ')}' : ''}'),
                                      trailing: FilledButton(
                                          onPressed:
                                              release['downloadable'] == false
                                                  ? null
                                                  : () => download(release),
                                          child: const Text('Tải')))))
                              .toList()))
                ])
              : ListView(
                  children: episodes
                      .where((episode) =>
                          episode['seasonNumber'] == selectedSeason)
                      .map((episode) => ListTile(
                          title: Text(
                              'S${episode['seasonNumber'].toString().padLeft(2, '0')}E${episode['episodeNumber'].toString().padLeft(2, '0')} • ${episode['title']}'),
                          trailing: OutlinedButton(
                              onPressed: () =>
                                  findReleases(episodeId: episode['episodeId']),
                              child: const Text('Chọn bản tải'))))
                      .toList()))
    ]);
  }
}

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.api});
  final Api api;
  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  List<dynamic> items = [];
  Timer? refreshTimer;
  bool loading = false;
  String? loadError;
  @override
  void initState() {
    super.initState();
    unawaited(load());
    refreshTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => unawaited(load()));
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (loading) return;
    loading = true;
    try {
      final x = await widget.api.gateway('/v1/downloads');
      if (mounted) {
        setState(() {
          items = x;
          loadError = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => loadError = 'Mất kết nối tạm thời. Đang thử lại…');
      }
    } finally {
      loading = false;
    }
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

  String stateLabel(dynamic state) =>
      state == 'importing' ? 'Đang nhập thư viện' : '$state';

  @override
  Widget build(BuildContext context) => PageFrame(
      title: 'Downloads',
      actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))],
      child: Column(children: [
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
                            child: ListTile(
                                title: Text(x['name']),
                                subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      LinearProgressIndicator(
                                          value: (x['progress'] ?? 0) / 100),
                                      Text(
                                          '${x['category'] == 'series' ? 'TV Show' : 'Phim'} • ${x['progress']}% • ${stateLabel(x['state'])} • ${formatBytes(x['downloadSpeed'])}/s')
                                    ]),
                                trailing: Wrap(children: [
                                  IconButton(
                                      onPressed: () => act(x['hash'], 'pause'),
                                      icon: const Icon(Icons.pause)),
                                  IconButton(
                                      onPressed: () => act(x['hash'], 'resume'),
                                      icon: const Icon(Icons.play_arrow)),
                                  IconButton(
                                      onPressed: () => act(x['hash'], 'delete'),
                                      icon: const Icon(Icons.delete_outline))
                                ]))))
                        .toList())),
      ]));
}

class SubtitlesPage extends StatefulWidget {
  const SubtitlesPage({super.key, required this.api});
  final Api api;
  @override
  State<SubtitlesPage> createState() => _SubtitlesPageState();
}

class _SubtitlesPageState extends State<SubtitlesPage> {
  String language = 'vi';
  String provider = 'all';
  bool directFallback = false;
  bool directAvailable = false;
  bool busy = false;
  int? mediaId;
  String mediaType = 'movie';
  String? catalogSelection;
  dynamic selectedSeries;
  int? selectedSeason;
  List<dynamic> media = [];
  List<dynamic> episodes = [];
  List<dynamic> results = [];
  String? seasonSearchMessage;
  @override
  void initState() {
    super.initState();
    loadMedia();
  }

  Future<void> loadMedia() async {
    try {
      final value = await widget.api.gateway('/v1/library/subtitle-media');
      if (!mounted) return;
      setState(() {
        media = value;
        if (media.isNotEmpty) {
          final first = media.first;
          catalogSelection ??= '${first['type'] ?? 'movie'}:${first['mediaId']}';
          if (first['type'] == 'series') {
            selectedSeries = first;
            mediaId = null;
            mediaType = 'series';
          } else {
            mediaId ??= first['mediaId'];
            mediaType = '${first['type'] ?? 'movie'}';
          }
        }
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void selectCatalog(String? value) {
    if (value == null) return;
    final selected = media.firstWhere(
        (item) => '${item['type'] ?? 'movie'}:${item['mediaId']}' == value);
    setState(() {
      catalogSelection = value;
      selectedSeason = null;
      episodes = [];
      results = [];
      if (selected['type'] == 'series') {
        selectedSeries = selected;
        mediaId = null;
        mediaType = 'series';
      } else {
        selectedSeries = null;
        mediaId = selected['mediaId'];
        mediaType = 'movie';
      }
      if (mediaType != 'movie' && provider == 'yify-direct') provider = 'all';
    });
  }

  Future<void> loadSeason(int seasonNumber) async {
    final series = selectedSeries;
    if (series == null) return;
    setState(() {
      busy = true;
      selectedSeason = seasonNumber;
      episodes = [];
      results = [];
    });
    try {
      final value = await widget.api.gateway(
          '/v1/library/subtitle-media/${series['mediaId']}/seasons/$seasonNumber');
      if (!mounted) return;
      final rows = value is List ? value : <dynamic>[];
      setState(() {
        episodes = rows;
        if (rows.isNotEmpty) {
          mediaId = rows.first['mediaId'];
          mediaType = 'episode';
        } else {
          mediaId = null;
          mediaType = 'series';
        }
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> search({bool direct = false}) async {
    if (mediaId == null) {
      showError(context, 'Chưa có phim trong thư viện');
      return;
    }
    setState(() => busy = true);
    try {
      if (mediaType == 'episode' && direct) return;
      final path = direct
          ? '/v1/library/$mediaId/subtitles/yify/search?language=$language'
          : '/v1/library/$mediaId/subtitles/search?language=$language&provider=$provider&directFallback=${mediaType == 'movie' && directFallback}&mediaType=$mediaType';
      final value = await widget.api.gateway(path);
      if (!mounted) return;
      setState(() {
        results = value is List ? value : (value['data'] ?? []);
        directAvailable = value is Map && value['directEnabled'] == true;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> searchSeason() async {
    final series = selectedSeries;
    final seasonNumber = selectedSeason;
    if (series == null || seasonNumber == null) return;
    final seriesId = series['mediaId'];
    setState(() {
      busy = true;
      seasonSearchMessage = null;
      results = [];
    });
    try {
      final result = await widget.api.gateway(
          '/v1/library/subtitle-media/$seriesId/seasons/$seasonNumber/search',
          method: 'POST');
      final catalog = await widget.api.gateway('/v1/library/subtitle-media');
      if (!mounted) return;
      final List<dynamic> rows =
          catalog is List ? List<dynamic>.from(catalog) : <dynamic>[];
      final refreshedSeries = rows.firstWhere(
          (item) => item['type'] == 'series' && item['mediaId'] == seriesId,
          orElse: () => series);
      setState(() {
        media = rows;
        selectedSeries = refreshedSeries;
        seasonSearchMessage =
            'Đã có ${result['alreadyAvailable'] ?? 0} • Đã tải ${result['downloaded'] ?? 0} • Không tìm thấy ${result['unavailable'] ?? 0} • Lỗi ${result['failed'] ?? 0}';
      });
      await loadSeason(seasonNumber);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> choose(dynamic subtitle) async {
    try {
      await widget.api.gateway('/v1/library/$mediaId/subtitles/download',
          method: 'POST', body: {'downloadToken': subtitle['downloadToken']});
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Đã tải phụ đề')));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> refresh() async {
    if (mediaId == null) return;
    try {
      await widget.api.gateway(
          '/v1/library/$mediaId/subtitles/refresh${mediaType == 'episode' ? '?mediaType=episode' : ''}',
          method: 'POST');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Đã quét lại phụ đề')));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget subtitleResultTile(dynamic subtitle) => Card(
      child: ListTile(
          title: Text(subtitle['release'] ?? 'Subtitle'),
          subtitle: Text(
              '${subtitle['provider'] ?? ''} • ${subtitle['language'] ?? ''} • ${subtitle['format'] ?? ''} • score ${subtitle['score'] ?? ''}${subtitle['fallback'] == true ? ' • English fallback' : ''}${subtitle['hearingImpaired'] == true ? ' • HI' : ''}'),
          trailing: FilledButton(
              onPressed: subtitle['downloadToken'] == null
                  ? null
                  : () => choose(subtitle),
              child: const Text('Tải'))));

  List<Widget> allProviderResultGroups() {
    const providers = [
      ('opensubtitlescom', 'OpenSubtitles.com'),
      ('gestdown', 'Gestdown'),
      ('yifysubtitles', 'YIFY Subtitles'),
    ];
    return providers.expand((entry) {
      final providerResults = results
          .where((item) => '${item['provider'] ?? ''}'.toLowerCase() == entry.$1)
          .toList()
        ..sort((left, right) {
          final fallbackOrder = (left['fallback'] == true ? 1 : 0)
              .compareTo(right['fallback'] == true ? 1 : 0);
          if (fallbackOrder != 0) return fallbackOrder;
          return (right['score'] as num? ?? 0)
              .compareTo(left['score'] as num? ?? 0);
        });
      return <Widget>[
        Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
            child: Text('${entry.$2} • ${providerResults.length}',
                style: Theme.of(context).textTheme.titleMedium)),
        if (providerResults.isEmpty)
          const Padding(
              padding: EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: Text('Không có kết quả'))
        else
          ...providerResults.map(subtitleResultTile),
      ];
    }).toList();
  }

  @override
  Widget build(BuildContext context) => PageFrame(
      title: 'Phụ đề',
      child: Column(children: [
        Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                  width: 300,
                  child: DropdownButtonFormField<String>(
                      key: ValueKey(catalogSelection),
                      isExpanded: true,
                      initialValue: catalogSelection,
                      decoration: const InputDecoration(
                          labelText: 'Phim / TV Show trong thư viện'),
                      items: media
                          .map<DropdownMenuItem<String>>((m) => DropdownMenuItem(
                              value: '${m['type'] ?? 'movie'}:${m['mediaId']}',
                              child: Text(
                                  '${m['type'] == 'series' ? 'TV • ' : ''}${m['title']} (${m['year'] == 0 ? '' : m['year']})',
                                  overflow: TextOverflow.ellipsis)))
                          .toList(),
                      onChanged: selectCatalog)),
              if (selectedSeries != null)
                ...((selectedSeries['seasons'] ?? []) as List).map((season) =>
                    ChoiceChip(
                        label: Text(
                            'Season ${season['seasonNumber']} • Vietsub ${season['viAvailable']}/${season['episodeCount']}'),
                        selected: selectedSeason == season['seasonNumber'],
                        onSelected: busy
                            ? null
                            : (_) => loadSeason(season['seasonNumber']))),
              if (episodes.isNotEmpty)
                SizedBox(
                    width: 380,
                    child: DropdownButtonFormField<int>(
                        key: ValueKey('$selectedSeason:$mediaId'),
                        isExpanded: true,
                        initialValue: mediaId,
                        decoration: const InputDecoration(labelText: 'Tập phim'),
                        items: episodes
                            .map<DropdownMenuItem<int>>((episode) => DropdownMenuItem(
                                value: episode['mediaId'],
                                child: Text(episode['title'], overflow: TextOverflow.ellipsis)))
                            .toList(),
                        onChanged: (value) => setState(() {
                              mediaId = value;
                              mediaType = 'episode';
                              results = [];
                            }))),
              if (episodes.isNotEmpty &&
                  episodes.firstWhere((item) => item['mediaId'] == mediaId)['hasVietnamese'] != true)
                const Chip(label: Text('Thiếu Vietsub')),
              DropdownButton(
                  value: language,
                  items: const [
                    DropdownMenuItem(value: 'vi', child: Text('Tiếng Việt')),
                    DropdownMenuItem(value: 'en', child: Text('English'))
                  ],
                  onChanged: (v) => setState(() => language = v!)),
              DropdownButton(
                  value: provider,
                  items: [
                    const DropdownMenuItem(
                        value: 'all', child: Text('Tất cả provider')),
                    const DropdownMenuItem(
                        value: 'bazarr', child: Text('Bazarr')),
                    const DropdownMenuItem(
                        value: 'yifysubtitles', child: Text('YIFY qua Bazarr')),
                    const DropdownMenuItem(
                        value: 'gestdown', child: Text('Gestdown')),
                    const DropdownMenuItem(
                        value: 'opensubtitlescom',
                        child: Text('OpenSubtitles.com')),
                    DropdownMenuItem(
                        value: 'yify-direct',
                        enabled: mediaType == 'movie',
                        child: const Text('YIFY Direct'))
                  ],
                  onChanged: (v) => setState(() => provider = v!)),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Switch(
                    value: directFallback,
                    onChanged: mediaType == 'episode'
                        ? null
                        : (v) => setState(() => directFallback = v)),
                const Text('Cho phép YIFY Direct fallback')
              ]),
              FilledButton(
                  onPressed: busy
                      ? null
                      : selectedSeries != null && selectedSeason != null
                          ? searchSeason
                          : () => search(),
                  child: Text(selectedSeries != null && selectedSeason != null
                      ? 'Tìm Vietsub cho Season $selectedSeason'
                      : 'Tìm qua Bazarr')),
              if (mediaType == 'episode')
                OutlinedButton(
                    onPressed: busy ? null : () => search(),
                    child: const Text('Tìm riêng tập đang chọn')),
              OutlinedButton(
                  onPressed: busy || mediaType == 'episode'
                      ? null
                      : () => search(direct: true),
                  child: const Text('Tìm trực tiếp YIFY')),
              IconButton(
                  onPressed: refresh,
                  tooltip: 'Quét lại',
                  icon: const Icon(Icons.refresh)),
            ]),
        if (!directAvailable && directFallback)
          const Align(
              alignment: Alignment.centerLeft,
              child: Text('YIFY Direct đang tắt trong cấu hình backend.',
                  style: TextStyle(color: Colors.amber))),
        if (seasonSearchMessage != null)
          Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(seasonSearchMessage!))),
        const SizedBox(height: 12),
        if (busy) const LinearProgressIndicator(),
        Expanded(
            child: results.isEmpty
                ? const Center(
                    child: Text('Chọn phim, ngôn ngữ và nguồn để tìm'))
                : ListView(
                    children: provider == 'all'
                        ? allProviderResultGroups()
                        : results.map(subtitleResultTile).toList())),
      ]));
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.api});
  final Api api;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<dynamic> items = [];
  dynamic selected;
  List<dynamic> subtitles = [];
  bool refreshing = false;
  Timer? deleteTimer;
  double deleteProgress = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    deleteTimer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final x = await widget.api.gateway('/v1/library');
      if (mounted) setState(() => items = x is List ? x : []);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> selectMovie(dynamic movie) async {
    setState(() => selected = movie);
    if (movie['type'] == 'series') {
      setState(() => subtitles = []);
      return;
    }
    await loadSubtitles();
  }

  Future<void> loadSubtitles() async {
    if (selected == null) return;
    try {
      final value = await widget.api
          .gateway('/v1/library/${selected['mediaId']}/subtitles');
      if (mounted) setState(() => subtitles = value is List ? value : []);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> refreshLibrary() async {
    setState(() => refreshing = true);
    try {
      await widget.api.gateway('/v1/library/refresh', method: 'POST');
      for (var attempt = 0; attempt < 15 && mounted; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        await load();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  Future<String?> pickSubtitleFile() async {
    if (!Platform.isWindows) return null;
    const script =
        r"Add-Type -AssemblyName System.Windows.Forms; $d=New-Object System.Windows.Forms.OpenFileDialog; $d.Filter='Subtitle files (*.srt;*.ass;*.ssa;*.vtt)|*.srt;*.ass;*.ssa;*.vtt'; if($d.ShowDialog() -eq 'OK'){$d.FileName}";
    final result =
        await Process.run('powershell.exe', ['-NoProfile', '-Command', script]);
    final value = '${result.stdout}'.trim();
    return value.isEmpty ? null : value;
  }

  Future<void> uploadSubtitle() async {
    final filePath = await pickSubtitleFile();
    if (filePath == null || !mounted) return;
    var language = 'vi';
    var forced = false;
    var hearingImpaired = false;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: const Text('Gắn phụ đề local'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    DropdownButton<String>(
                        value: language,
                        items: const [
                          DropdownMenuItem(
                              value: 'vi', child: Text('Tiếng Việt')),
                          DropdownMenuItem(value: 'en', child: Text('English'))
                        ],
                        onChanged: (value) => update(() => language = value!)),
                    CheckboxListTile(
                        value: forced,
                        onChanged: (value) => update(() => forced = value!),
                        title: const Text('Forced')),
                    CheckboxListTile(
                        value: hearingImpaired,
                        onChanged: (value) =>
                            update(() => hearingImpaired = value!),
                        title: const Text('Hearing impaired')),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Hủy')),
                    FilledButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: const Text('Gắn'))
                  ],
                )));
    if (accepted != true) return;
    try {
      final file = File(filePath);
      await widget.api.gateway(
          '/v1/library/${selected['mediaId']}/subtitles/upload',
          method: 'POST',
          body: {
            'fileName': file.uri.pathSegments.last,
            'contentBase64': base64Encode(await file.readAsBytes()),
            'language': language,
            'forced': forced,
            'hearingImpaired': hearingImpaired,
          });
      await loadSubtitles();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> deleteSubtitle(dynamic subtitle) async {
    try {
      await widget.api.gateway(
          '/v1/library/${selected['mediaId']}/subtitles/${subtitle['id']}',
          method: 'DELETE');
      await loadSubtitles();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void startDeleteHold() {
    deleteTimer?.cancel();
    setState(() => deleteProgress = 0);
    var ticks = 0;
    deleteTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      ticks++;
      if (mounted) setState(() => deleteProgress = ticks / 30);
      if (ticks >= 30) {
        timer.cancel();
        unawaited(deleteMovie());
      }
    });
  }

  void cancelDeleteHold() {
    deleteTimer?.cancel();
    if (mounted && deleteProgress < 1) setState(() => deleteProgress = 0);
  }

  Future<void> deleteMovie() async {
    try {
      final result = await widget.api.gateway(
          '/v1/library/${selected['mediaId']}',
          method: 'DELETE',
          body: {'deleteFiles': true, 'deleteTorrent': true});
      if (!mounted) return;
      setState(() {
        selected = null;
        subtitles = [];
        deleteProgress = 0;
      });
      await load();
      if (result is Map && result['status'] == 'partial_failure' && mounted) {
        showError(
            context, 'Đã xóa phim nhưng chưa dọn được torrent. Hãy thử lại.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => deleteProgress = 0);
        showError(context, e);
      }
    }
  }

  Future<void> openJellyfin() =>
      Process.start('cmd', ['/c', 'start', '', 'http://localhost:8096'],
          runInShell: true);

  @override
  Widget build(BuildContext context) => PageFrame(
      title: 'Thư viện',
      actions: [
        FilledButton.icon(
            onPressed: openJellyfin,
            icon: const Icon(Icons.open_in_new),
            label: const Text('Mở Jellyfin')),
        FilledButton.icon(
            onPressed: refreshing ? null : refreshLibrary,
            icon: refreshing
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            label: const Text('Quét Jellyfin')),
        IconButton(onPressed: load, icon: const Icon(Icons.refresh))
      ],
      child: selected != null
          ? movieDetail()
          : items.isEmpty
              ? const Center(child: Text('Thư viện đang trống'))
              : GridView.extent(
                  maxCrossAxisExtent: 260,
                  childAspectRatio: 1.5,
                  children: items
                      .map((x) => Card(
                          child: InkWell(
                              onTap: () => selectMovie(x),
                              child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                            '${x['title'] ?? ''}${(x['year'] ?? 0) > 0 ? ' (${x['year']})' : ''}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                        const Spacer(),
                                        Text(x['type'] == 'series'
                                            ? 'TV Show • ${x['episodeCount'] ?? 0} tập'
                                            : x['watched'] == true
                                                ? 'Đã xem'
                                                : (x['playbackPositionTicks'] ?? 0) > 0
                                                    ? 'Đang xem'
                                                    : 'Chưa xem'),
                                        if (x['type'] != 'series')
                                          Text(
                                              '${x['videoCodec'] ?? ''} • ${x['audioCodec'] ?? ''} • ${x['subtitleCount'] ?? 0} phụ đề')
                                      ])))))
                      .toList()));

  Widget movieDetail() {
    if (selected['type'] == 'series') {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextButton.icon(
            onPressed: () => setState(() => selected = null),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Quay lại thư viện')),
        Text('${selected['title']} (${selected['year']})',
            style: Theme.of(context).textTheme.headlineSmall),
        Text('TV Show • ${selected['episodeCount'] ?? 0} tập'),
        const SizedBox(height: 12),
        FilledButton.icon(
            onPressed: openJellyfin,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Mở trong Jellyfin')),
        const SizedBox(height: 16),
        const Text('Phụ đề từng tập được quản lý trong tab Phụ đề.'),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextButton.icon(
            onPressed: () => setState(() => selected = null),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Quay lại thư viện')),
        Text('${selected['title']} (${selected['year']})',
            style: Theme.of(context).textTheme.headlineSmall),
        Text(
            '${selected['videoCodec'] ?? ''} • ${selected['audioCodec'] ?? ''}'),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 10, children: [
          FilledButton.icon(
              onPressed: openJellyfin,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Mở trong Jellyfin')),
          OutlinedButton.icon(
              onPressed: uploadSubtitle,
              icon: const Icon(Icons.upload_file),
              label: const Text('Gắn phụ đề')),
          OutlinedButton.icon(
              onPressed: loadSubtitles,
              icon: const Icon(Icons.subtitles),
              label: const Text('Quét phụ đề')),
        ]),
        const SizedBox(height: 12),
        Text('Phụ đề', style: Theme.of(context).textTheme.titleMedium),
        Expanded(
            child: ListView(children: [
          ...subtitles.map((subtitle) => ListTile(
              title: Text(subtitle['name'] ?? 'Subtitle'),
              subtitle: Text(subtitle['language'] ?? ''),
              trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => deleteSubtitle(subtitle)))),
          const Divider(),
          Listener(
              onPointerDown: (_) => startDeleteHold(),
              onPointerUp: (_) => cancelDeleteHold(),
              onPointerCancel: (_) => cancelDeleteHold(),
              child: SizedBox(
                  width: 320,
                  child: FilledButton.icon(
                      style:
                          FilledButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: () {},
                      icon: const Icon(Icons.delete_forever),
                      label: Text(deleteProgress > 0
                          ? 'Giữ... ${(deleteProgress * 3).clamp(0, 3).toStringAsFixed(1)}s / 3s'
                          : 'Giữ 3 giây để xóa toàn bộ')))),
          if (deleteProgress > 0)
            SizedBox(
                width: 320,
                child:
                    LinearProgressIndicator(value: deleteProgress.clamp(0, 1))),
        ]))
      ]);
  }
}

class ServicesPage extends StatefulWidget {
  const ServicesPage({super.key, required this.api});
  final Api api;
  @override
  State<ServicesPage> createState() => _ServicesPageState();
}

String sourceStateLabel(String? state) => switch (state) {
      'ready' => 'Sẵn sàng',
      'cloudflare_blocked' => 'Bị Cloudflare chặn',
      'degraded' => 'Tạm thời gián đoạn',
      'needs_manual_configuration' => 'Cần cấu hình thủ công',
      'needs_manual_feed' => 'Cần feed thủ công',
      'disabled' => 'Đã tắt',
      _ => state ?? 'Không rõ',
    };

class _ServicesPageState extends State<ServicesPage> {
  List<dynamic> items = [];
  List<dynamic> sources = [];
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final x = await widget.api.host('/host/services');
      final configuredSources = await widget.api.gateway('/v1/sources');
      if (mounted) {
        setState(() {
          items = x;
          sources = configuredSources;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> act(String id, String action) async {
    try {
      await widget.api.host('/host/services/$id/$action', method: 'POST');
      await load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> logs(String id) async {
    try {
      final x = await widget.api.host('/host/services/$id/logs');
      if (mounted) {
        showDialog(
            context: context,
            builder: (_) => AlertDialog(
                    title: Text('Log: $id'),
                    content: SizedBox(
                        width: 760,
                        child: SingleChildScrollView(
                            child: SelectableText(x['logs'] ?? ''))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Đóng'))
                    ]));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
      title: 'Services',
      actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))],
      child: ListView(children: [
        if (sources.isNotEmpty)
          const Padding(
              padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
              child: Text('Nguồn tải', style: TextStyle(fontSize: 18))),
        ...sources.map((source) => Card(
            child: ListTile(
                leading: const Icon(Icons.public),
                title: Text(source['name']),
                subtitle: Text(
                    '${sourceStateLabel(source['state'])} • ${(source['scopes'] as List).join(', ')}${source['endpoint'] == null ? '' : ' • ${source['endpoint']}'}${source['reason'] == null ? '' : ' • ${source['reason']}'}')))),
        if (sources.isNotEmpty)
          const Padding(
              padding: EdgeInsets.fromLTRB(4, 18, 4, 8),
              child: Text('Dịch vụ', style: TextStyle(fontSize: 18))),
        ...items.map((x) => Card(
            child: ListTile(
                leading: Icon(Icons.circle,
                    color: x['state'] == 'running' ? Colors.green : Colors.grey,
                    size: 14),
                title: Text(x['id']),
                subtitle: Text('${x['state']} • ${x['health'] ?? ''}'),
                trailing: Wrap(children: [
                  IconButton(
                      onPressed: () => logs(x['id']),
                      tooltip: 'Xem log',
                      icon: const Icon(Icons.article_outlined)),
                  IconButton(
                      onPressed: () => act(x['id'], 'start'),
                      icon: const Icon(Icons.play_arrow)),
                  IconButton(
                      onPressed: () => act(x['id'], 'restart'),
                      icon: const Icon(Icons.restart_alt)),
                  IconButton(
                      onPressed: () => act(x['id'], 'stop'),
                      icon: const Icon(Icons.stop))
                ]))))
      ]));
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.api});
  final Api api;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic>? maintenance;
  Map<String, dynamic>? tv;
  bool cleaning = false;
  String? error;
  @override
  void initState() {
    super.initState();
    unawaited(loadMaintenance());
    unawaited(loadTv());
  }

  Future<void> loadTv() async {
    try {
      final value = await widget.api.host('/host/tv/status');
      if (mounted) setState(() => tv = Map<String, dynamic>.from(value));
    } catch (_) {}
  }

  Future<void> loadMaintenance() async {
    try {
      final value = await widget.api.host('/host/maintenance/status');
      if (mounted) {
        setState(() {
          maintenance = Map<String, dynamic>.from(value);
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = 'Không đọc được trạng thái dọn dẹp');
    }
  }

  Future<void> cleanup() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Xóa cache & log?'),
              content: const Text(
                  'Giữ lại cache phim thịnh hành và toàn bộ cấu hình, media, database.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Hủy')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Xóa ngay'))
              ],
            ));
    if (confirmed != true || !mounted) return;
    setState(() {
      cleaning = true;
      error = null;
    });
    try {
      final value =
          await widget.api.host('/host/maintenance/cleanup', method: 'POST');
      if (mounted) {
        setState(() => maintenance = Map<String, dynamic>.from(value));
      }
    } catch (_) {
      if (mounted) setState(() => error = 'Không thể dọn cache và log');
    } finally {
      if (mounted) setState(() => cleaning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.api.config;
    final removed = maintenance?['removedFiles'] ?? 0;
    final reclaimed = maintenance?['reclaimedBytes'] ?? 0;
    final lastRun = maintenance?['lastRunAt'];
    return PageFrame(
        title: 'Cài đặt',
        child: ListView(children: [
          ListTile(
              title: const Text('Gateway'), subtitle: Text(config.gateway)),
          ListTile(
              title: const Text('Host controller'),
              subtitle: Text(config.controller)),
          const ListTile(
              title: Text('Media root'), subtitle: Text('D:\\Media')),
          const ListTile(
              title: Text('Tài khoản local'),
              subtitle: Text('admin / •••••••••')),
          const Divider(),
          ListTile(
              leading: const Icon(Icons.tv),
              title: const Text('Samsung TV trong mạng LAN'),
              subtitle: Text(
                  tv?['url'] ?? 'Không tìm thấy địa chỉ LAN riêng của máy'),
              trailing: tv?['url'] == null
                  ? null
                  : IconButton(
                      tooltip: 'Sao chép URL',
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: tv!['url'])),
                      icon: const Icon(Icons.copy))),
          ListTile(
              title: const Text('Trạng thái Jellyfin TV'),
              subtitle: Text(tv?['reachable'] == true
                  ? 'Sẵn sàng • TCP 8096 • discovery UDP 7359'
                  : 'Chưa chạy. Nhấn Start server rồi thử lại.'),
              trailing: IconButton(
                  onPressed: loadTv, icon: const Icon(Icons.refresh))),
          const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                  'Trên TV Samsung: cài Jellyfin Tizen bằng Developer Mode/Tizen Studio, sau đó thêm máy chủ bằng URL ở trên. Không bật chuyển tiếp cổng Internet.')),
          const Divider(),
          ListTile(
              title: const Text('Dọn dẹp tự động'),
              subtitle: Text(lastRun == null
                  ? 'Chưa chạy • tự xóa file quá 24 giờ'
                  : 'Lần gần nhất: $lastRun • $removed file • ${formatBytes(reclaimed)}')),
          if (error != null)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                      onPressed: cleaning ? null : cleanup,
                      icon: cleaning
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.cleaning_services),
                      label: const Text('Xóa cache & log')))),
        ]));
  }
}

String formatBytes(dynamic value) {
  final n = (value ?? 0) as num;
  if (n >= 1073741824) return '${(n / 1073741824).toStringAsFixed(1)} GB';
  if (n >= 1048576) return '${(n / 1048576).toStringAsFixed(1)} MB';
  if (n >= 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${n.toInt()} B';
}
