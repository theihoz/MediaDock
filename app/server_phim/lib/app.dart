import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/dashboard_controller.dart';

const ink = Color(0xFF08111F);
const panel = Color(0xFF111E31);
const panelRaised = Color(0xFF182942);
const projector = Color(0xFF5AB0FF);
const amber = Color(0xFFFFB454);
const mint = Color(0xFF45D19A);
const mist = Color(0xFFDCE7F5);
const muted = Color(0xFF8FA5BF);

class ServerPhimApp extends StatefulWidget {
  const ServerPhimApp({super.key});

  @override
  State<ServerPhimApp> createState() => _ServerPhimAppState();
}

class _ServerPhimAppState extends State<ServerPhimApp> {
  late final GoRouter router;

  @override
  void initState() {
    super.initState();
    router = GoRouter(
      initialLocation: '/overview',
      routes: [
        ShellRoute(
          builder: (context, state, child) =>
              AppShell(location: state.uri.path, child: child),
          routes: [
            GoRoute(
              path: '/overview',
              builder: (context, state) => const OverviewScreen(),
            ),
            GoRoute(
              path: '/discover',
              builder: (context, state) => const DiscoverScreen(),
            ),
            GoRoute(
              path: '/library',
              builder: (context, state) => const LibraryScreen(),
            ),
            GoRoute(
              path: '/downloads',
              builder: (context, state) => const DownloadsScreen(),
            ),
            GoRoute(
              path: '/subtitles',
              builder: (context, state) => const SubtitlesScreen(),
            ),
            GoRoute(
              path: '/admin',
              builder: (context, state) => const AdminScreen(),
            ),
          ],
        ),
      ],
    );
  }

  @override
  void dispose() {
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    debugShowCheckedModeBanner: false,
    title: 'Server Phim',
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: ink,
      colorScheme: const ColorScheme.dark(
        primary: projector,
        secondary: amber,
        tertiary: mint,
        surface: panel,
        onSurface: mist,
        error: Color(0xFFFF6B6B),
      ),
      fontFamily: 'Segoe UI Variable',
      cardTheme: const CardThemeData(
        color: panel,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(18)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panelRaised,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    ),
    routerConfig: router,
  );
}

class Destination {
  const Destination(this.label, this.path, this.icon);
  final String label;
  final String path;
  final IconData icon;
}

const destinations = [
  Destination('Tổng quan', '/overview', Icons.space_dashboard_rounded),
  Destination('Khám phá', '/discover', Icons.explore_rounded),
  Destination('Thư viện', '/library', Icons.video_library_rounded),
  Destination('Tải xuống', '/downloads', Icons.downloading_rounded),
  Destination('Phụ đề', '/subtitles', Icons.subtitles_rounded),
  Destination('Quản trị', '/admin', Icons.tune_rounded),
];

class AppShell extends StatelessWidget {
  const AppShell({required this.location, required this.child, super.key});
  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final selected = destinations
        .indexWhere((d) => d.path == location)
        .clamp(0, destinations.length - 1);
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 184,
            color: const Color(0xFF0C1728),
            child: SafeArea(
              child: Column(
                children: [
                  const _Brand(),
                  const SizedBox(height: 24),
                  Expanded(
                    child: NavigationRail(
                      backgroundColor: Colors.transparent,
                      extended: true,
                      minExtendedWidth: 184,
                      selectedIndex: selected,
                      onDestinationSelected: (index) =>
                          context.go(destinations[index].path),
                      indicatorColor: projector.withValues(alpha: .16),
                      selectedIconTheme: const IconThemeData(color: projector),
                      selectedLabelTextStyle: const TextStyle(
                        color: mist,
                        fontWeight: FontWeight.w700,
                      ),
                      unselectedIconTheme: const IconThemeData(color: muted),
                      unselectedLabelTextStyle: const TextStyle(color: muted),
                      destinations: [
                        for (final d in destinations)
                          NavigationRailDestination(
                            icon: Icon(d.icon),
                            label: Text(d.label),
                          ),
                      ],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(18),
                    child: Text(
                      'CHỈ TRÊN MÁY NÀY',
                      style: TextStyle(
                        color: muted,
                        fontSize: 10,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                const SignalStrip(),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(20, 26, 16, 0),
    child: Row(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: projector,
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
          child: Padding(
            padding: EdgeInsets.all(9),
            child: Icon(Icons.movie_filter_rounded, color: ink, size: 22),
          ),
        ),
        SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SERVER PHIM',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.1,
                  fontSize: 14,
                ),
              ),
              Text(
                'projection console',
                style: TextStyle(color: muted, fontSize: 10),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class SignalStrip extends ConsumerWidget {
  const SignalStrip({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(dashboardControllerProvider);
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      decoration: const BoxDecoration(
        color: Color(0xFF0A1525),
        border: Border(bottom: BorderSide(color: Color(0xFF1F3047))),
      ),
      child: Row(
        children: [
          for (final stage in const [
            ('YÊU CẦU', Icons.add_circle_outline),
            ('TẢI XUỐNG', Icons.downloading),
            ('PHỤ ĐỀ', Icons.closed_caption),
            ('SẴN SÀNG', Icons.play_circle_fill),
          ]) ...[
            Icon(stage.$2, size: 16, color: state.serverOnline ? mint : muted),
            const SizedBox(width: 7),
            Text(
              stage.$1,
              style: TextStyle(
                color: state.serverOnline ? mist : muted,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
            if (stage.$1 != 'SẴN SÀNG')
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Divider(color: Color(0xFF28405C)),
                ),
              ),
          ],
          const SizedBox(width: 16),
          _StatusPill(
            healthy: state.serverOnline,
            text: state.serverOnline ? 'LIVE' : 'OFFLINE',
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.healthy, required this.text});
  final bool healthy;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: (healthy ? mint : muted).withValues(alpha: .12),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: healthy ? mint : muted,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 7),
        Text(
          text,
          style: TextStyle(
            color: healthy ? mint : muted,
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 1,
          ),
        ),
      ],
    ),
  );
}

class ScreenFrame extends StatelessWidget {
  const ScreenFrame({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.child,
    this.action,
    super.key,
  });
  final String eyebrow;
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? action;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(32, 30, 32, 42),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    eyebrow.toUpperCase(),
                    style: const TextStyle(
                      color: projector,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 32,
                      height: 1,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.8,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    subtitle,
                    style: const TextStyle(color: muted, fontSize: 14),
                  ),
                ],
              ),
            ),
            ?action,
          ],
        ),
        const SizedBox(height: 28),
        child,
      ],
    ),
  );
}

class OverviewScreen extends ConsumerWidget {
  const OverviewScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(dashboardControllerProvider);
    final controller = ref.read(dashboardControllerProvider.notifier);
    if (!state.serverOnline) {
      return ScreenFrame(
        eyebrow: 'Phòng máy',
        title: 'Server đang tắt',
        subtitle: 'MediaServer chỉ khởi động khi bạn chủ động bật.',
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            padding: const EdgeInsets.all(38),
            decoration: BoxDecoration(
              color: panel,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFF24364E)),
            ),
            child: Column(
              children: [
                const Icon(
                  Icons.power_settings_new_rounded,
                  size: 58,
                  color: amber,
                ),
                const SizedBox(height: 18),
                const Text(
                  'Phòng chiếu đang nghỉ',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Bật Ubuntu, Docker và toàn bộ dịch vụ bằng một lần nhấn.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: state.loading ? null : controller.startServer,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Bật server'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final free = state.storage['free_bytes'] as num? ?? 0;
    final healthy = state.services.where((s) => s['state'] == 'healthy').length;
    return ScreenFrame(
      eyebrow: 'Phòng máy',
      title: 'Tổng quan',
      subtitle: 'Một điểm nhìn cho Ubuntu, Docker, GPU và kho phim.',
      action: Row(
        children: [
          OutlinedButton.icon(
            onPressed: controller.refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Làm mới'),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: controller.stopServer,
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Tắt server'),
          ),
        ],
      ),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) => GridView.count(
              crossAxisCount: constraints.maxWidth >= 900 ? 4 : 2,
              crossAxisSpacing: 14,
              mainAxisSpacing: 14,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: constraints.maxWidth >= 900 ? 1.75 : 2.5,
              children: [
                MetricCard(
                  label: 'WSL · DOCKER',
                  value: 'Đang chạy',
                  icon: Icons.developer_board,
                  color: mint,
                ),
                const MetricCard(
                  label: 'GPU',
                  value: 'RTX 4050',
                  icon: Icons.memory,
                  color: projector,
                ),
                MetricCard(
                  label: 'DỊCH VỤ',
                  value: '$healthy / ${state.services.length}',
                  icon: Icons.hub,
                  color: mint,
                ),
                MetricCard(
                  label: 'Ổ D CÒN TRỐNG',
                  value: '${(free / 1073741824).toStringAsFixed(1)} GB',
                  icon: Icons.storage,
                  color: amber,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Tín hiệu dịch vụ',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 9,
                    runSpacing: 9,
                    children: [
                      for (final service in state.services)
                        _ServiceChip(
                          name: service['name']?.toString() ?? '',
                          healthy: service['state'] == 'healthy',
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    super.key,
  });
  final String label, value;
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
              Icon(icon, color: color, size: 20),
            ],
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    ),
  );
}

class _ServiceChip extends StatelessWidget {
  const _ServiceChip({required this.name, required this.healthy});
  final String name;
  final bool healthy;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: panelRaised,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          healthy ? Icons.check_circle : Icons.warning_rounded,
          size: 15,
          color: healthy ? mint : amber,
        ),
        const SizedBox(width: 7),
        Text(
          name,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
        ),
      ],
    ),
  );
}

class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});
  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  final search = TextEditingController();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dashboardControllerProvider);
    final controller = ref.read(dashboardControllerProvider.notifier);
    return ScreenFrame(
      eyebrow: 'Danh mục',
      title: 'Khám phá',
      subtitle: 'Tìm và gửi yêu cầu tới Seerr, không cần mở thêm tab.',
      child: Column(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: search,
                      onSubmitted: controller.search,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Tên phim hoặc series...',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: () => controller.search(search.text),
                    icon: const Icon(Icons.search),
                    label: const Text('Tìm kiếm'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.high_quality_rounded, color: projector),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '1080p mặc định',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          'Chỉ bật 4K cho nội dung thực sự cần.',
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const Text('Yêu cầu 4K cho nội dung này'),
                  const SizedBox(width: 8),
                  Switch(value: state.request4k, onChanged: controller.set4k),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          if (state.searchResults.isEmpty)
            const _EmptyState(
              icon: Icons.local_movies_outlined,
              title: 'Sẵn sàng tìm phim',
              detail: 'Kết quả từ Seerr sẽ xuất hiện tại đây.',
            )
          else
            ...state.searchResults.map(
              (item) => MediaRow(
                item: item,
                action: FilledButton(
                  onPressed: () => controller.requestMedia(item),
                  child: Text(state.request4k ? 'Thêm 4K' : 'Thêm 1080p'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class MediaRow extends StatelessWidget {
  const MediaRow({required this.item, required this.action, super.key});
  final Map<String, dynamic> item;
  final Widget action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 58,
              decoration: BoxDecoration(
                color: panelRaised,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.movie, color: muted),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item['title']?.toString() ?? 'Untitled',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${item['media_type'] ?? ''}  ·  ${item['year'] ?? '—'}',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            action,
          ],
        ),
      ),
    ),
  );
}

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(dashboardControllerProvider);
    final controller = ref.read(dashboardControllerProvider.notifier);
    return ScreenFrame(
      eyebrow: 'Kho nội dung',
      title: 'Thư viện',
      subtitle: 'Monitor, rescan và quản lý phim đã nhập vào ổ D.',
      action: FilledButton.tonalIcon(
        onPressed: controller.refresh,
        icon: const Icon(Icons.sync),
        label: const Text('Refresh & rescan'),
      ),
      child: state.library.isEmpty
          ? const _EmptyState(
              icon: Icons.video_library_outlined,
              title: 'Thư viện chưa có dữ liệu',
              detail: 'Phim đã import từ Radarr và Sonarr sẽ hiện ở đây.',
            )
          : Column(
              children: [
                for (final item in state.library)
                  MediaRow(
                    item: item,
                    action: IconButton(
                      tooltip: 'Xóa hai bước',
                      icon: const Icon(
                        Icons.delete_outline,
                        color: Color(0xFFFF8B8B),
                      ),
                      onPressed: () =>
                          _confirmDelete(context, item, controller),
                    ),
                  ),
              ],
            ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    Map<String, dynamic> item,
    DashboardController controller,
  ) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xác nhận xóa dữ liệu'),
        content: Text(
          'Xóa “${item['title']}” khỏi thư viện? Backend sẽ yêu cầu token xác nhận bước hai.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Giữ lại'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (accepted == true) await controller.deleteLibrary(item['id'].toString());
  }
}

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(dashboardControllerProvider);
    final controller = ref.read(dashboardControllerProvider.notifier);
    return ScreenFrame(
      eyebrow: 'Hàng đợi hợp nhất',
      title: 'Tải xuống',
      subtitle:
          'qBittorrent là mặc định; SABnzbd sẵn sàng khi có tài khoản Usenet.',
      child: state.downloads.isEmpty
          ? const _EmptyState(
              icon: Icons.downloading_outlined,
              title: 'Hàng đợi đang trống',
              detail: 'Torrent và Usenet sẽ cùng xuất hiện trong màn hình này.',
            )
          : Column(
              children: [
                for (final job in state.downloads)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  job['title'].toString(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              _StatusPill(
                                healthy: true,
                                text: job['client'].toString().toUpperCase(),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          LinearProgressIndicator(
                            value: (job['progress'] as num?)?.toDouble() ?? 0,
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              IconButton(
                                onPressed: () => controller.downloadAction(
                                  job['id'].toString(),
                                  'pause',
                                ),
                                icon: const Icon(Icons.pause),
                              ),
                              IconButton(
                                onPressed: () => controller.downloadAction(
                                  job['id'].toString(),
                                  'resume',
                                ),
                                icon: const Icon(Icons.play_arrow),
                              ),
                              IconButton(
                                onPressed: () => controller.downloadAction(
                                  job['id'].toString(),
                                  'retry',
                                ),
                                icon: const Icon(Icons.refresh),
                              ),
                              IconButton(
                                onPressed: () => controller.downloadAction(
                                  job['id'].toString(),
                                  'cancel',
                                ),
                                icon: const Icon(
                                  Icons.cancel_outlined,
                                  color: Color(0xFFFF8B8B),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class SubtitlesScreen extends ConsumerWidget {
  const SubtitlesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(dashboardControllerProvider);
    final controller = ref.read(dashboardControllerProvider.notifier);
    return ScreenFrame(
      eyebrow: 'Ngôn ngữ',
      title: 'Phụ đề',
      subtitle: 'Tiếng Việt được ưu tiên; tiếng Anh luôn là lớp dự phòng.',
      child: Column(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  const Icon(Icons.translate, color: projector),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ưu tiên: Việt → Anh',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          'Bazarr tự tìm lại khi chưa có bản Việt.',
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  _StatusPill(healthy: state.serverOnline, text: 'BAZARR'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (state.subtitles.isEmpty)
            const _EmptyState(
              icon: Icons.subtitles_off_outlined,
              title: 'Chưa có mục thiếu phụ đề',
              detail: 'Kết quả theo dõi từ Bazarr sẽ xuất hiện tại đây.',
            )
          else
            ...state.subtitles.map(
              (item) => MediaRow(
                item: item,
                action: Row(
                  children: [
                    OutlinedButton(
                      onPressed: () => controller.subtitleAction(
                        item['id'].toString(),
                        'rescan',
                      ),
                      child: const Text('Quét lại'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => controller.subtitleAction(
                        item['id'].toString(),
                        'search',
                      ),
                      child: const Text('Tìm ngay'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class AdminScreen extends ConsumerWidget {
  const AdminScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(dashboardControllerProvider.notifier);
    return ScreenFrame(
      eyebrow: 'Điều khiển sâu',
      title: 'Quản trị',
      subtitle: 'Indexer, client, profile và provider được gom theo module.',
      action: FilledButton.tonalIcon(
        onPressed: controller.updateServer,
        icon: const Icon(Icons.system_update_alt),
        label: const Text('Cập nhật stack'),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => GridView.count(
          crossAxisCount: constraints.maxWidth >= 520 ? 2 : 1,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: constraints.maxWidth >= 900 ? 2.35 : 1.3,
          children: [
            AdminTile(
              icon: Icons.radar,
              title: 'Indexer',
              detail: 'Prowlarr · tracker chờ tài khoản',
              color: projector,
              onTap: () => _showConfig(
                context,
                controller,
                'indexers',
                'Indexer',
                'Torznab',
                const {'baseUrl': '', 'apiKey': ''},
              ),
            ),
            AdminTile(
              icon: Icons.cloud_download,
              title: 'Download client',
              detail: 'qBittorrent mặc định · SABnzbd dự phòng',
              color: mint,
              onTap: () => _showConfig(
                context,
                controller,
                'clients',
                'Download client',
                'QBittorrent',
                const {
                  'service': 'radarr',
                  'host': 'qbittorrent',
                  'port': 8081,
                },
              ),
            ),
            AdminTile(
              icon: Icons.high_quality,
              title: 'Quality profile',
              detail: '1080p mặc định · 4K theo nội dung',
              color: amber,
              onTap: () => _showConfig(
                context,
                controller,
                'profiles',
                'Quality profile',
                'ServarrQualityProfile',
                const {'profileId': 4, 'quality': '1080p'},
              ),
            ),
            AdminTile(
              icon: Icons.folder_open,
              title: 'Root folder',
              detail: '/data/library trên ổ D',
              color: projector,
              onTap: () => _showConfig(
                context,
                controller,
                'profiles',
                'Root folder',
                'RootFolder',
                const {
                  'movies': '/data/library/movies',
                  'tv': '/data/library/tv',
                  'music': '/data/library/music',
                },
              ),
            ),
            AdminTile(
              icon: Icons.subtitles,
              title: 'Subtitle provider',
              detail: 'Việt ưu tiên · Anh dự phòng',
              color: mint,
              onTap: () => _showConfig(
                context,
                controller,
                'providers',
                'Subtitle provider',
                'OpenSubtitlesCom',
                const {'username': '', 'password': ''},
              ),
            ),
            AdminTile(
              icon: Icons.build_circle_outlined,
              title: 'Integration nâng cao',
              detail: 'Autobrr · FlareSolverr · Cleanuparr · Wizarr',
              color: amber,
              onTap: () => _showConfig(
                context,
                controller,
                'clients',
                'Integration nâng cao',
                'Integration',
                const {'enabled': true},
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showConfig(
    BuildContext context,
    DashboardController controller,
    String kind,
    String title,
    String defaultImplementation,
    Map<String, dynamic> defaultSettings,
  ) async {
    final name = TextEditingController(text: title);
    final implementation = TextEditingController(text: defaultImplementation);
    final settings = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(defaultSettings),
    );
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Cấu hình $title'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Tên hiển thị'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: implementation,
                decoration: const InputDecoration(labelText: 'Implementation'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: settings,
                minLines: 4,
                maxLines: 8,
                style: const TextStyle(
                  fontFamily: 'Cascadia Mono',
                  fontSize: 12,
                ),
                decoration: const InputDecoration(
                  labelText: 'Thiết lập JSON',
                  helperText:
                      'Secret chỉ gửi tới backend loopback và được redact khỏi response.',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Lưu cấu hình'),
          ),
        ],
      ),
    );
    if (save == true) {
      final decoded = jsonDecode(settings.text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Thiết lập phải là JSON object');
      }
      await controller.saveAdminResource(
        kind,
        name.text.trim(),
        implementation.text.trim(),
        decoded,
      );
    }
    name.dispose();
    implementation.dispose();
    settings.dispose();
  }
}

class AdminTile extends StatelessWidget {
  const AdminTile({
    required this.icon,
    required this.title,
    required this.detail,
    required this.color,
    required this.onTap,
    super.key,
  });
  final IconData icon;
  final String title, detail;
  final Color color;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    detail,
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: muted),
          ],
        ),
      ),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.detail,
  });
  final IconData icon;
  final String title, detail;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(vertical: 52),
    decoration: BoxDecoration(
      color: panel,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFF21334B)),
    ),
    child: Column(
      children: [
        Icon(icon, color: muted, size: 42),
        const SizedBox(height: 14),
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
        ),
        const SizedBox(height: 6),
        Text(detail, style: const TextStyle(color: muted)),
      ],
    ),
  );
}
