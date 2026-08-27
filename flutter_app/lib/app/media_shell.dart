part of '../media_control.dart';

class MediaShell extends StatefulWidget {
  const MediaShell({super.key, this.api, this.bootstrapper});
  final Api? api;
  final ControllerBootstrapper? bootstrapper;
  @override
  State<MediaShell> createState() => _MediaShellState();
}

class _MediaShellState extends State<MediaShell> {
  int selected = 0;
  int workspace = 1;
  final lastSelected = [1, 0];
  final visited = <int>{0};
  late final Api api;
  late final ControllerBootstrapper bootstrapper;
  ControllerStartupResult? controllerState;
  static const destinations = [
    NavigationDestination(
        icon: Icon(Icons.dashboard_outlined),
        selectedIcon: Icon(Icons.dashboard),
        label: 'Tổng quan'),
    NavigationDestination(icon: Icon(Icons.search), label: 'Khám phá'),
    NavigationDestination(
        icon: Icon(Icons.downloading_outlined),
        selectedIcon: Icon(Icons.downloading),
        label: 'Downloads'),
    NavigationDestination(
        icon: Icon(Icons.subtitles_outlined),
        selectedIcon: Icon(Icons.subtitles),
        label: 'Vietsub'),
    NavigationDestination(
        icon: Icon(Icons.video_library_outlined),
        selectedIcon: Icon(Icons.video_library),
        label: 'Thư viện'),
    NavigationDestination(
        icon: Icon(Icons.dns_outlined),
        selectedIcon: Icon(Icons.dns),
        label: 'Services'),
    NavigationDestination(
        icon: Icon(Icons.settings_outlined),
        selectedIcon: Icon(Icons.settings),
        label: 'Cài đặt'),
  ];
  static const workspaceDestinations = [
    [1, 2, 3, 4],
    [0, 5, 6],
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

  Widget selectedPage(int page) => switch (page) {
        0 => OverviewPage(api: api),
        1 => DiscoveryPage(api: api),
        2 => DownloadsPage(api: api, active: selected == 2),
        3 => SubtitlesPage(api: api),
        4 => LibraryPage(api: api),
        5 => ServicesPage(api: api),
        _ => SettingsPage(api: api),
      };

  void selectWorkspace(int value) => setState(() {
        workspace = value;
        selected = lastSelected[value];
        visited.add(selected);
      });

  void selectDestination(int value) => setState(() {
        selected = workspaceDestinations[workspace][value];
        lastSelected[workspace] = selected;
        visited.add(selected);
      });

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
    final currentDestinations = workspaceDestinations[workspace];
    final selectedIndex = currentDestinations.indexOf(selected);
    final pages = List<Widget>.generate(
        destinations.length,
        (index) => visited.contains(index)
            ? selectedPage(index)
            : const SizedBox.shrink());
    return Scaffold(
        appBar: AppBar(title: const Text('Media Control')),
        body: Column(children: [
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                        value: 0,
                        icon: Icon(Icons.movie_filter_outlined),
                        label: Text('Nội dung')),
                    ButtonSegment(
                        value: 1,
                        icon: Icon(Icons.tune),
                        label: Text('Hệ thống')),
                  ],
                  selected: {workspace},
                  onSelectionChanged: (value) => selectWorkspace(value.first))),
          Expanded(child: LayoutBuilder(builder: (context, constraints) {
            final content = IndexedStack(index: selected, children: pages);
            if (constraints.maxWidth >= 840) {
              return Row(children: [
                NavigationRail(
                    selectedIndex: selectedIndex,
                    labelType: NavigationRailLabelType.all,
                    destinations: currentDestinations
                        .map((index) => NavigationRailDestination(
                            icon: destinations[index].icon,
                            selectedIcon: destinations[index].selectedIcon,
                            label: Text(destinations[index].label)))
                        .toList(),
                    onDestinationSelected: selectDestination),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ]);
            }
            return Column(children: [
              Expanded(child: content),
              NavigationBar(
                  selectedIndex: selectedIndex,
                  destinations: currentDestinations
                      .map((index) => destinations[index])
                      .toList(),
                  onDestinationSelected: selectDestination),
            ]);
          }))
        ]));
  }
}
