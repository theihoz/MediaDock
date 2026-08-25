part of '../../media_control.dart';

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
  bool directChecked = false;
  bool directRequested = false;
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
      setState(() => media = value is List ? value : []);
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
      directAvailable = false;
      directChecked = false;
      if (selected['type'] == 'series') {
        selectedSeries = selected;
        mediaId = null;
        mediaType = 'series';
        directFallback = false;
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
        mediaId = null;
        mediaType = 'series';
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
    setState(() {
      busy = true;
      directRequested = direct;
    });
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
        directChecked = value is Map && value.containsKey('directEnabled');
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
    final providers = [
      if (results.any(
          (item) => '${item['provider'] ?? ''}'.toLowerCase() == 'yify direct'))
        ('yify direct', 'YIFY Direct'),
      ('opensubtitlescom', 'OpenSubtitles.com'),
      ('gestdown', 'Gestdown'),
      ('yifysubtitles', 'YIFY Subtitles'),
    ];
    return providers.expand((entry) {
      final providerResults = results
          .where(
              (item) => '${item['provider'] ?? ''}'.toLowerCase() == entry.$1)
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
  Widget build(BuildContext context) {
    final hasContent = catalogSelection != null;
    final hasSeason = selectedSeries != null && selectedSeason != null;
    final canSearch = selectedSeries == null ? mediaId != null : hasSeason;
    final selectedEpisode = mediaId == null
        ? null
        : episodes.where((item) => item['mediaId'] == mediaId).firstOrNull;
    return PageFrame(
        title: 'Vietsub',
        child: ListView(children: [
          Text('1. Nội dung', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SizedBox(
              width: 420,
              child: DropdownButtonFormField<String>(
                  key: ValueKey(catalogSelection),
                  isExpanded: true,
                  initialValue: catalogSelection,
                  decoration: const InputDecoration(
                      labelText: 'Phim / TV Show trong thư viện'),
                  items: media
                      .map<DropdownMenuItem<String>>((item) => DropdownMenuItem(
                          value:
                              '${item['type'] ?? 'movie'}:${item['mediaId']}',
                          child: Text(
                              '${item['type'] == 'series' ? 'TV • ' : ''}${item['title']} (${item['year'] == 0 ? '' : item['year']})',
                              overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: selectCatalog)),
          if (hasContent) ...[
            const SizedBox(height: 18),
            Text('2. Mùa/tập', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (selectedSeries == null)
              const Text('Phim lẻ • không cần chọn mùa hoặc tập')
            else
              Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: ((selectedSeries['seasons'] ?? []) as List)
                      .map((season) => ChoiceChip(
                          label: Text(
                              'Season ${season['seasonNumber']} • Vietsub ${season['viAvailable']}/${season['episodeCount']}'),
                          selected: selectedSeason == season['seasonNumber'],
                          onSelected: busy
                              ? null
                              : (_) => loadSeason(season['seasonNumber'])))
                      .toList()),
            if (episodes.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                  width: 420,
                  child: DropdownButtonFormField<int>(
                      key: ValueKey('$selectedSeason:$mediaId'),
                      isExpanded: true,
                      initialValue: mediaId,
                      decoration: const InputDecoration(labelText: 'Tập phim'),
                      hint: const Text('Chọn tập để tìm riêng'),
                      items: episodes
                          .map<DropdownMenuItem<int>>((episode) =>
                              DropdownMenuItem(
                                  value: episode['mediaId'],
                                  child: Text(episode['title'],
                                      overflow: TextOverflow.ellipsis)))
                          .toList(),
                      onChanged: (value) => setState(() {
                            mediaId = value;
                            mediaType = value == null ? 'series' : 'episode';
                            results = [];
                          }))),
              if (selectedEpisode != null &&
                  selectedEpisode['hasVietnamese'] != true)
                const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Chip(label: Text('Thiếu Vietsub'))),
            ],
          ],
          if (canSearch) ...[
            const SizedBox(height: 18),
            Text('3. Nguồn/kết quả',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (hasSeason)
                    FilledButton(
                        onPressed: busy ? null : searchSeason,
                        child: Text('Tìm Vietsub cho Season $selectedSeason')),
                  if (selectedSeries == null || mediaType == 'episode') ...[
                    DropdownButton(
                        value: language,
                        items: const [
                          DropdownMenuItem(
                              value: 'vi', child: Text('Tiếng Việt')),
                          DropdownMenuItem(value: 'en', child: Text('English'))
                        ],
                        onChanged: (value) =>
                            setState(() => language = value!)),
                    DropdownButton(
                        value: provider,
                        items: const [
                          DropdownMenuItem(
                              value: 'all', child: Text('Tất cả provider')),
                          DropdownMenuItem(
                              value: 'bazarr', child: Text('Bazarr')),
                          DropdownMenuItem(
                              value: 'yifysubtitles',
                              child: Text('YIFY qua Bazarr')),
                          DropdownMenuItem(
                              value: 'gestdown', child: Text('Gestdown')),
                          DropdownMenuItem(
                              value: 'opensubtitlescom',
                              child: Text('OpenSubtitles.com')),
                        ],
                        onChanged: (value) =>
                            setState(() => provider = value!)),
                    FilledButton(
                        onPressed: busy ? null : () => search(),
                        child: Text(mediaType == 'episode'
                            ? 'Tìm riêng tập đang chọn'
                            : 'Tìm qua Bazarr')),
                    IconButton(
                        onPressed: refresh,
                        tooltip: 'Quét lại',
                        icon: const Icon(Icons.refresh)),
                  ],
                ]),
            if (selectedSeries == null)
              ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Nâng cao'),
                  children: [
                    SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: directFallback,
                        onChanged: (value) =>
                            setState(() => directFallback = value),
                        title: const Text('Cho phép YIFY Direct fallback')),
                    Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton(
                            onPressed: busy ? null : () => search(direct: true),
                            child: const Text('Tìm trực tiếp YIFY'))),
                  ]),
            if (directChecked &&
                !directAvailable &&
                (directFallback || directRequested))
              const Text('YIFY Direct đang tắt trong cấu hình backend.',
                  style: TextStyle(color: Colors.amber)),
            if (seasonSearchMessage != null)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(seasonSearchMessage!)),
          ],
          const SizedBox(height: 8),
          if (busy) const LinearProgressIndicator(),
          if (!canSearch)
            const SizedBox.shrink()
          else if (results.isEmpty)
            const Center(child: Text('Chọn nguồn rồi bắt đầu tìm Vietsub'))
          else
            ...(provider == 'all'
                ? allProviderResultGroups()
                : results.map(subtitleResultTile)),
        ]));
  }
}
