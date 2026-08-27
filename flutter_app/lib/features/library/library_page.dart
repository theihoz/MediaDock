part of '../../media_control.dart';

String jellyfinDetailsUrl(String jellyfinBaseUrl, Object jellyfinId) =>
    '${jellyfinBaseUrl.replaceFirst(RegExp(r'/+$'), '')}/web/#/details?id=${Uri.encodeComponent('$jellyfinId')}';

String _libraryWatchState(dynamic item) {
  if (item['watched'] == true) return 'Đã xem';
  final ticks = num.tryParse('${item['playbackPositionTicks'] ?? 0}') ?? 0;
  return ticks > 0 ? 'Xem tiếp' : 'Chưa xem';
}

Widget _libraryPoster(dynamic url) {
  const fallback = Center(child: Icon(Icons.image_not_supported_outlined));
  if (url == null || '$url'.isEmpty) return fallback;
  return Image.network('$url',
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => fallback);
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
    final confirmed = await confirmAction(
      context,
      title: 'Xóa phụ đề?',
      message: 'Xóa ${subtitle['name'] ?? 'phụ đề này'} khỏi nội dung?',
      confirmLabel: 'Xóa',
    );
    if (!confirmed) return;
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

  Future<void> openJellyfin([dynamic movie]) async {
    if (!Platform.isWindows) return;
    final id = movie?['jellyfinId'];
    final url = id == null || '$id'.isEmpty
        ? widget.api.config.jellyfinBaseUrl
        : jellyfinDetailsUrl(widget.api.config.jellyfinBaseUrl, id);
    await Process.start('explorer.exe', [url]);
  }

  @override
  Widget build(BuildContext context) => PageFrame(
      title: 'Thư viện',
      actions: [
        FilledButton.icon(
            onPressed: () => openJellyfin(),
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
                  childAspectRatio: .72,
                  children: items
                      .map((x) => Card(
                          child: InkWell(
                              onTap: () => selectMovie(x),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                        child: ClipRRect(
                                            borderRadius:
                                                const BorderRadius.vertical(
                                                    top: Radius.circular(12)),
                                            child: Semantics(
                                                image: true,
                                                label:
                                                    'Poster ${x['title'] ?? ''}',
                                                child: _libraryPoster(
                                                    x['poster'])))),
                                    Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                  '${x['title'] ?? ''}${(x['year'] ?? 0) > 0 ? ' (${x['year']})' : ''}',
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleMedium),
                                              const SizedBox(height: 6),
                                              Text(_libraryWatchState(x)),
                                              Text(
                                                  x['type'] == 'series'
                                                      ? 'TV Show • ${x['episodeCount'] ?? 0} tập'
                                                      : '${x['videoCodec'] ?? ''} • ${x['audioCodec'] ?? ''} • ${x['subtitleCount'] ?? 0} phụ đề',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis),
                                            ]))
                                  ]))))
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
            onPressed: selected['jellyfinId'] == null ||
                    '${selected['jellyfinId']}'.isEmpty
                ? null
                : () => openJellyfin(selected),
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
      Text('${selected['videoCodec'] ?? ''} • ${selected['audioCodec'] ?? ''}'),
      const SizedBox(height: 12),
      Wrap(spacing: 10, runSpacing: 10, children: [
        FilledButton.icon(
            onPressed: selected['jellyfinId'] == null ||
                    '${selected['jellyfinId']}'.isEmpty
                ? null
                : () => openJellyfin(selected),
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
            trailing: TextButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: const Text('Xóa'),
                onPressed: () => deleteSubtitle(subtitle)))),
        const Divider(),
        Listener(
            onPointerDown: (_) => startDeleteHold(),
            onPointerUp: (_) => cancelDeleteHold(),
            onPointerCancel: (_) => cancelDeleteHold(),
            child: SizedBox(
                width: 320,
                child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
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
