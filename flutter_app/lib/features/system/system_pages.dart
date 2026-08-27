part of '../../media_control.dart';

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
    if (value == 'restart' || value == 'stop') {
      final restarting = value == 'restart';
      final confirmed = await confirmAction(
        context,
        title: restarting ? 'Khởi động lại server?' : 'Dừng server?',
        message: restarting
            ? 'Các dịch vụ media sẽ tạm ngắt trong lúc khởi động lại.'
            : 'Downloads và các tác vụ đang chạy sẽ bị tạm dừng.',
        confirmLabel: restarting ? 'Khởi động lại' : 'Dừng',
      );
      if (!confirmed || !mounted) return;
    }
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
                label: const Text('Khởi động lại')),
            OutlinedButton.icon(
                onPressed: busy ? null : () => action('stop'),
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Dừng')),
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
    if (action == 'restart' || action == 'stop') {
      final restarting = action == 'restart';
      final confirmed = await confirmAction(
        context,
        title: restarting ? 'Khởi động lại $id?' : 'Dừng $id?',
        message: restarting
            ? 'Dịch vụ sẽ tạm thời không khả dụng.'
            : 'Các tác vụ của dịch vụ này sẽ bị tạm dừng.',
        confirmLabel: restarting ? 'Khởi động lại' : 'Dừng',
      );
      if (!confirmed || !mounted) return;
    }
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
                child: Column(children: [
              ListTile(
                  leading: Icon(Icons.circle,
                      color:
                          x['state'] == 'running' ? Colors.green : Colors.grey,
                      size: 14),
                  title: Text(x['id']),
                  subtitle: Text('${x['state']} • ${x['health'] ?? ''}'),
                  trailing: IconButton(
                      onPressed: () => logs(x['id']),
                      tooltip: 'Xem log',
                      icon: const Icon(Icons.article_outlined))),
              Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(spacing: 4, children: [
                        TextButton.icon(
                            onPressed: () => act(x['id'], 'start'),
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Bật')),
                        TextButton.icon(
                            onPressed: () => act(x['id'], 'restart'),
                            icon: const Icon(Icons.restart_alt),
                            label: const Text('Khởi động lại')),
                        TextButton.icon(
                            onPressed: () => act(x['id'], 'stop'),
                            icon: const Icon(Icons.stop),
                            label: const Text('Dừng'))
                      ])))
            ])))
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
