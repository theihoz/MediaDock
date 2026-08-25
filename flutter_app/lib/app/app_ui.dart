part of '../media_control.dart';

List<String> actionableReleaseSources(List<dynamic> releases) {
  final sources = <String>[];
  for (final value in releases) {
    if (value is! Map || value['downloadable'] == false) continue;
    final source = '${value['source'] ?? 'Prowlarr'}';
    if (!sources.contains(source)) sources.add(source);
  }
  return sources;
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

String vietnameseError(Object error) {
  if (error is SocketException || error is TimeoutException) {
    return 'Dịch vụ cục bộ chưa sẵn sàng. Hãy thử lại.';
  }
  if (error is String) return error;
  if (error is ApiException) {
    return switch (error.code) {
      'invalid_request' => 'Yêu cầu không hợp lệ. Hãy kiểm tra và thử lại.',
      'request_too_large' => 'Dữ liệu gửi lên quá lớn.',
      'not_found' => 'Không tìm thấy nội dung yêu cầu.',
      'conflict' => 'Thao tác xung đột với trạng thái hiện tại.',
      'upstream_timeout' => 'Dịch vụ nguồn phản hồi quá lâu. Hãy thử lại.',
      _ => 'Dịch vụ nguồn tạm thời không khả dụng. Hãy thử lại.',
    };
  }
  return 'Đã xảy ra lỗi. Hãy thử lại.';
}

void showError(BuildContext context, Object error) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(vietnameseError(error))));

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ) ??
    false;

String friendlyDownloadError(Object error) {
  final value = '$error'.toLowerCase();
  if (value.contains('qbittorrent') ||
      value.contains('download_client_rejected')) {
    return 'qBittorrent chưa nhận bản tải. Hãy kiểm tra Downloads rồi thử lại.';
  }
  return 'Không thể gửi bản tải lúc này. Hãy thử lại.';
}
