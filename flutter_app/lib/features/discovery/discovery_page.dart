part of '../../media_control.dart';

class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({super.key, required this.api, this.historyStore});
  final Api api;
  final SearchHistoryStore? historyStore;

  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends State<DiscoveryPage> {
  final searchField = TextEditingController();
  final yearField = TextEditingController();
  late final SearchHistoryStore history;
  late final UnifiedSearchController unified;
  String type = 'all';
  String library = 'all';
  bool showAll = false;
  bool busy = false;
  bool prepared = false;
  bool episodesPrepared = false;
  bool showEpisodes = false;
  bool partial = false;
  String? error;
  String? selectedReleaseSource;
  int? selectedSeason;
  int? releaseEpisodeId;
  Map<String, dynamic>? selected;
  Map<String, dynamic> sources = {};
  List<dynamic> releases = [];
  List<dynamic> episodes = [];

  @override
  void initState() {
    super.initState();
    history = widget.historyStore ?? SearchHistoryStore();
    unified = UnifiedSearchController(
      search: _search,
      onRecentChanged: (items) =>
          items.isEmpty ? history.clear() : history.save(items),
    );
    _restoreHistory();
  }

  Future<void> _restoreHistory() async {
    final values = await history.load();
    if (mounted) unified.replaceRecent(values);
  }

  Future<dynamic> _search(String query) {
    final parameters = {
      'q': query,
      'type': type,
      if (yearField.text.trim().isNotEmpty) 'year': yearField.text.trim(),
      'library': library,
      'limit': '50',
    };
    return widget.api.gateway(
        Uri(path: '/v1/discover/search', queryParameters: parameters)
            .toString());
  }

  void _filterChanged() {
    unified.clearCache();
    showAll = false;
    if (searchField.text.trim().length >= 2) {
      unified.updateQuery(searchField.text);
    }
    setState(() {});
  }

  void _showResults() {
    if (searchField.text.trim().length < 2) return;
    setState(() => showAll = true);
  }

  @override
  void dispose() {
    searchField.dispose();
    yearField.dispose();
    unified.dispose();
    super.dispose();
  }

  void openResult(dynamic item) {
    final value = Map<String, dynamic>.from(item as Map);
    final seasons = _seasonNumbers(value);
    setState(() {
      selected = value;
      selectedSeason = seasons.firstOrNull;
      episodes = [];
      episodesPrepared = false;
      showEpisodes = false;
      _resetReleases();
    });
  }

  List<int> _seasonNumbers([Map<String, dynamic>? item]) {
    final values = (item ?? selected)?['seasons'];
    if (values is! List) return [];
    final seasons = values
        .map((value) => value is Map ? value['seasonNumber'] : value)
        .whereType<int>()
        .where((value) => value > 0)
        .toSet()
        .toList()
      ..sort();
    return seasons;
  }

  void _resetReleases() {
    releases = [];
    sources = {};
    prepared = false;
    partial = false;
    selectedReleaseSource = null;
    releaseEpisodeId = null;
    error = null;
  }

  Future<Map<String, dynamic>> _mappedMovie() async {
    final current = selected!;
    if ((current['tmdbId'] as num?)?.toInt() case final id? when id > 0) {
      return current;
    }
    final matches = await widget.api.gateway(
        '/v1/movies/search?q=${Uri.encodeQueryComponent('${current['title'] ?? ''}')}');
    final exact = (matches as List)
        .where((value) => value['year'] == current['year'])
        .toList();
    if (exact.isEmpty) throw const ApiException(404, 'not_found');
    final mapped = {...current, ...Map<String, dynamic>.from(exact.first)};
    if (mounted) setState(() => selected = mapped);
    return mapped;
  }

  Future<Map<String, dynamic>> _mappedSeries() async {
    final current = selected!;
    if ((current['tvdbId'] as num?)?.toInt() case final id? when id > 0) {
      return current;
    }
    final matches = await widget.api.gateway(
        '/v1/series/search?q=${Uri.encodeQueryComponent('${current['title'] ?? ''}')}');
    final exact = (matches as List)
        .where((value) => value['year'] == current['year'])
        .toList();
    if (exact.isEmpty) throw const ApiException(404, 'not_found');
    final mapped = {
      ...current,
      ...Map<String, dynamic>.from(exact.first),
      'mediaType': 'series'
    };
    if (mounted) setState(() => selected = mapped);
    return mapped;
  }

  void _applyEnvelope(dynamic value) {
    final envelope = Map<String, dynamic>.from(value as Map);
    final items = List<dynamic>.from(envelope['items'] ?? const []);
    releases = items;
    sources = Map<String, dynamic>.from(envelope['sources'] ?? const {});
    partial = envelope['partial'] == true;
    prepared = envelope['prepared'] == true;
    selectedReleaseSource = actionableReleaseSources(items).firstOrNull;
  }

  Future<void> _prepareMovie({bool refresh = false}) async {
    setState(() {
      busy = true;
      error = null;
      showEpisodes = false;
    });
    try {
      final movie = await _mappedMovie();
      final value = await widget.api.gateway(
          '/v1/movies/${movie['tmdbId']}/releases${refresh ? '?refresh=true' : ''}',
          method: 'POST');
      if (mounted) setState(() => _applyEnvelope(value));
    } catch (exception) {
      if (mounted) setState(() => error = vietnameseError(exception));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _prepareSeries({int? episodeId, bool refresh = false}) async {
    if (episodeId == null && selectedSeason == null) return;
    setState(() {
      busy = true;
      error = null;
      showEpisodes = false;
    });
    try {
      final series = await _mappedSeries();
      final value = await widget.api.gateway(
          '/v1/series/${series['tvdbId']}/releases${refresh ? '?refresh=true' : ''}',
          method: 'POST',
          body: episodeId == null
              ? {'seasonNumber': selectedSeason}
              : {'episodeId': episodeId});
      if (mounted) {
        setState(() {
          _applyEnvelope(value);
          releaseEpisodeId = episodeId;
        });
      }
    } catch (exception) {
      if (mounted) setState(() => error = vietnameseError(exception));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _loadEpisodes() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final series = await _mappedSeries();
      final value = await widget.api
          .gateway('/v1/series/${series['tvdbId']}/episodes', method: 'POST');
      if (mounted) {
        setState(() {
          episodes = List<dynamic>.from(value['items'] ?? const []);
          episodesPrepared = value['prepared'] == true;
          showEpisodes = true;
        });
      }
    } catch (exception) {
      if (mounted) setState(() => error = vietnameseError(exception));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _download(dynamic release) async {
    try {
      final isSeries = selected!['mediaType'] == 'series';
      final id = isSeries ? selected!['tvdbId'] : selected!['tmdbId'];
      final body = isSeries
          ? {
              'downloadToken': release['downloadToken'],
              if (releaseEpisodeId != null) 'episodeId': releaseEpisodeId,
              if (releaseEpisodeId == null) 'seasonNumber': selectedSeason,
            }
          : {'guid': release['guid'], 'indexerId': release['indexerId']};
      final result = await widget.api.gateway(
          '/v1/${isSeries ? 'series' : 'movies'}/$id/download',
          method: 'POST',
          body: body);
      if (!mounted) return;
      final duplicate = result is Map && result['duplicate'] == true;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(duplicate
              ? 'Bản tải này đã có trong Downloads'
              : 'Đã gửi bản tải sang qBittorrent')));
    } catch (exception) {
      if (mounted) showError(context, friendlyDownloadError(exception));
    }
  }

  @override
  Widget build(BuildContext context) => selected == null
      ? _searchView()
      : PageFrame(
          title: selected!['mediaType'] == 'series'
              ? 'Chi tiết TV Show'
              : 'Chi tiết phim',
          child: _detailView());

  Widget _searchView() => AnimatedBuilder(
      animation: unified,
      builder: (context, _) => Column(children: [
            Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                child: Column(children: [
                  TextField(
                      key: const Key('discover-query'),
                      controller: searchField,
                      textInputAction: TextInputAction.search,
                      onChanged: (value) {
                        showAll = false;
                        unified.updateQuery(value);
                        setState(() {});
                      },
                      onSubmitted: (_) => _showResults(),
                      decoration: InputDecoration(
                          labelText: 'Khám phá nội dung',
                          hintText:
                              'Tên phim, TV Show, diễn viên, đạo diễn, studio…',
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
                                        setState(() => showAll = false);
                                      }))),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                        child: DropdownButtonFormField<String>(
                            key: const Key('discover-type'),
                            isExpanded: true,
                            initialValue: type,
                            decoration:
                                const InputDecoration(labelText: 'Loại'),
                            items: const [
                              DropdownMenuItem(
                                  value: 'all', child: Text('Tất cả')),
                              DropdownMenuItem(
                                  value: 'movie', child: Text('Phim')),
                              DropdownMenuItem(
                                  value: 'series', child: Text('TV Show')),
                            ],
                            onChanged: (value) {
                              type = value ?? 'all';
                              _filterChanged();
                            })),
                    const SizedBox(width: 10),
                    Expanded(
                        child: TextField(
                            key: const Key('discover-year'),
                            controller: yearField,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                            decoration: const InputDecoration(labelText: 'Năm'),
                            onChanged: (_) => _filterChanged())),
                    const SizedBox(width: 10),
                    Expanded(
                        child: DropdownButtonFormField<String>(
                            key: const Key('discover-library'),
                            isExpanded: true,
                            initialValue: library,
                            decoration:
                                const InputDecoration(labelText: 'Trạng thái'),
                            items: const [
                              DropdownMenuItem(
                                  value: 'all', child: Text('Tất cả')),
                              DropdownMenuItem(
                                  value: 'in', child: Text('Trong thư viện')),
                              DropdownMenuItem(
                                  value: 'out', child: Text('Ngoài thư viện')),
                            ],
                            onChanged: (value) {
                              library = value ?? 'all';
                              _filterChanged();
                            })),
                  ]),
                  if (unified.partial)
                    const Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Chip(
                                label: Text('Một số nguồn chưa phản hồi')))),
                  if (unified.error != null)
                    Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(vietnameseError(unified.error!),
                                style: const TextStyle(color: Colors.red)))),
                  if (unified.recent.isNotEmpty)
                    Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(children: [
                          Expanded(
                              child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                      children: unified.recent
                                          .map((value) => Padding(
                                              padding: const EdgeInsets.only(
                                                  right: 8),
                                              child: ActionChip(
                                                  avatar: const Icon(
                                                      Icons.history,
                                                      size: 16),
                                                  label: Text(value),
                                                  onPressed: () {
                                                    searchField.text = value;
                                                    unified.updateQuery(value);
                                                    setState(
                                                        () => showAll = false);
                                                  })))
                                          .toList()))),
                          TextButton.icon(
                              key: const Key('clear-search-history'),
                              onPressed: unified.clearRecent,
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('Xóa lịch sử'))
                        ])),
                ])),
            if (!showAll &&
                searchField.text.trim().length >= 2 &&
                unified.items.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Card(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 360),
                        child: ListView(
                            shrinkWrap: true,
                            children: unified.items.take(8).map((item) {
                              final id = item['tmdbId'] ?? item['tvdbId'] ?? '';
                              return ListTile(
                                  key: ValueKey('discover-suggestion-$id'),
                                  leading: _poster(item['poster'],
                                      width: 38, height: 54),
                                  title: Text(
                                      '${item['title']} (${item['year'] ?? ''})'),
                                  subtitle: Text(item['mediaType'] == 'series'
                                      ? 'TV Show'
                                      : 'Phim'),
                                  onTap: () => openResult(item));
                            }).toList())),
                    const Divider(height: 1),
                    ListTile(
                        key: const Key('show-all-results'),
                        leading: const Icon(Icons.grid_view),
                        title: const Text('Xem tất cả'),
                        onTap: _showResults),
                  ]))),
            Expanded(
                child: showAll
                    ? _resultGrid()
                    : Center(
                        child: Text(searchField.text.trim().length < 2
                            ? 'Nhập ít nhất 2 ký tự để khám phá nội dung'
                            : unified.loading
                                ? 'Đang tìm kiếm…'
                                : unified.items.isEmpty
                                    ? 'Không tìm thấy nội dung phù hợp'
                                    : 'Chọn gợi ý hoặc Xem tất cả')))
          ]));

  Widget _resultGrid() {
    if (unified.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (unified.items.isEmpty) {
      return const Center(child: Text('Không tìm thấy nội dung phù hợp'));
    }
    return LayoutBuilder(builder: (context, constraints) {
      final columns = (constraints.maxWidth / 210).floor().clamp(2, 7);
      return GridView.builder(
          key: const Key('discover-results-grid'),
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              childAspectRatio: .66,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12),
          itemCount: unified.items.length,
          itemBuilder: (context, index) {
            final item = Map<String, dynamic>.from(unified.items[index]);
            return Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                    onTap: () => openResult(item),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                              child: SizedBox(
                                  width: double.infinity,
                                  child: _poster(item['poster']))),
                          Padding(
                              padding: const EdgeInsets.fromLTRB(10, 9, 10, 2),
                              child: Text(
                                  '${item['title']} (${item['year'] ?? ''})',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis)),
                          Padding(
                              padding: const EdgeInsets.fromLTRB(10, 0, 10, 9),
                              child: Text(
                                  item['mediaType'] == 'series'
                                      ? 'TV Show'
                                      : 'Phim',
                                  style:
                                      Theme.of(context).textTheme.bodySmall)),
                        ])));
          });
    });
  }

  Widget _poster(dynamic url, {double? width, double? height}) => url == null ||
          '$url'.isEmpty
      ? SizedBox(
          width: width,
          height: height,
          child: const Center(child: Icon(Icons.image_not_supported_outlined)))
      : Image.network('$url',
          width: width ?? double.infinity,
          height: height,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => SizedBox(
              width: width,
              height: height,
              child: const Center(
                  child: Icon(Icons.image_not_supported_outlined))));

  Widget _detailView() {
    final isSeries = selected!['mediaType'] == 'series';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextButton.icon(
          onPressed: busy
              ? null
              : () => setState(() {
                    selected = null;
                    _resetReleases();
                  }),
          icon: const Icon(Icons.arrow_back),
          label: const Text('Quay lại kết quả')),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 130, height: 185, child: _poster(selected!['poster'])),
        const SizedBox(width: 18),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${selected!['title']} (${selected!['year'] ?? ''})',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text('${selected!['overview'] ?? 'Không có mô tả'}',
              maxLines: 6, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          if (isSeries) _seriesActions() else _movieActions(),
        ])),
      ]),
      if (busy)
        const Padding(
            padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
      if (error != null)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error))),
      if (partial)
        const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Chip(label: Text('Một số nguồn chưa phản hồi'))),
      if (sources.isNotEmpty) _sourceStates(),
      const SizedBox(height: 8),
      Expanded(child: showEpisodes ? _episodeList() : _releaseList()),
    ]);
  }

  Widget _movieActions() => Wrap(spacing: 8, children: [
        FilledButton.icon(
            key: const Key('prepare-movie-releases'),
            onPressed: busy ? null : _prepareMovie,
            icon: const Icon(Icons.search),
            label: const Text('Tìm bản tải')),
        if (prepared)
          OutlinedButton.icon(
              onPressed: busy ? null : () => _prepareMovie(refresh: true),
              icon: const Icon(Icons.refresh),
              label: const Text('Làm mới')),
      ]);

  Widget _seriesActions() {
    final seasons = _seasonNumbers();
    return Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          DropdownButton<int>(
              key: const Key('discover-season'),
              value: seasons.contains(selectedSeason) ? selectedSeason : null,
              hint: const Text('Chọn mùa'),
              items: seasons
                  .map((number) => DropdownMenuItem(
                      value: number, child: Text('Mùa $number')))
                  .toList(),
              onChanged: busy
                  ? null
                  : (value) => setState(() {
                        selectedSeason = value;
                        showEpisodes = false;
                        _resetReleases();
                      })),
          FilledButton.icon(
              key: const Key('prepare-season-releases'),
              onPressed: busy || selectedSeason == null ? null : _prepareSeries,
              icon: const Icon(Icons.search),
              label: const Text('Tìm bản tải')),
          OutlinedButton.icon(
              key: const Key('choose-episodes'),
              onPressed: busy || selectedSeason == null ? null : _loadEpisodes,
              icon: const Icon(Icons.list),
              label: const Text('Chọn theo tập')),
        ]);
  }

  Widget _sourceStates() => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
          children: sources.entries.map((entry) {
        final value = entry.value;
        final state = value is Map ? '${value['state'] ?? 'failed'}' : '$value';
        final count = value is Map ? value['itemCount'] : null;
        final stateLabel = switch (state) {
          'ready' => 'Sẵn sàng',
          'timeout' => 'Quá hạn',
          _ => 'Lỗi',
        };
        return Padding(
            padding: const EdgeInsets.only(right: 8, top: 8),
            child: Chip(
                label: Text(
                    '${entry.key} • $stateLabel${count == null ? '' : ' • $count'}')));
      }).toList()));

  Widget _releaseList() {
    if (!prepared) {
      return Center(
          child: Text(selected!['mediaType'] == 'series'
              ? 'Chọn mùa rồi nhấn Tìm bản tải'
              : 'Nhấn Tìm bản tải để chuẩn bị nguồn tải'));
    }
    if (releases.isEmpty) {
      return const Center(child: Text('Không tìm thấy bản tải phù hợp'));
    }
    return Column(children: [
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
                          title: Text('${release['title']}'),
                          subtitle: Text(
                              '${release['quality'] ?? ''} • ${release['codec'] ?? ''} • ${formatBytes(release['size'])} • seed ${release['seeders'] ?? 0}'),
                          trailing: FilledButton(
                              onPressed: () => _download(release),
                              child: const Text('Tải')))))
                  .toList()))
    ]);
  }

  Widget _episodeList() {
    final values = episodes
        .where((episode) => episode['seasonNumber'] == selectedSeason)
        .toList();
    if (episodesPrepared && values.isEmpty) {
      return const Center(child: Text('Mùa này chưa có tập'));
    }
    return ListView(
        children: values
            .map((episode) => ListTile(
                title: Text(
                    'S${episode['seasonNumber'].toString().padLeft(2, '0')}E${episode['episodeNumber'].toString().padLeft(2, '0')} • ${episode['title']}'),
                trailing: OutlinedButton(
                    key: ValueKey('prepare-episode-${episode['episodeId']}'),
                    onPressed: busy
                        ? null
                        : () => _prepareSeries(
                            episodeId: episode['episodeId'] as int),
                    child: const Text('Tìm bản tải tập'))))
            .toList());
  }
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
