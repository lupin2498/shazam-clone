import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../config.dart';
import '../l10n/strings.dart';
import '../services/app_services.dart';
import '../services/server_address.dart';
import '../widgets/common.dart';

const kCountries = {
  'VN': 'Việt Nam',
  'US': 'Hoa Kỳ',
  'GB': 'Anh',
  'JP': 'Nhật Bản',
  'KR': 'Hàn Quốc',
  'SG': 'Singapore',
  'TH': 'Thái Lan',
  'ID': 'Indonesia',
  'PH': 'Philippines',
  'MY': 'Malaysia',
  'AU': 'Úc',
  'CA': 'Canada',
  'FR': 'Pháp',
  'DE': 'Đức',
};

/// "Cài đặt": preferred platforms, country, clear data, privacy policy (section 3).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final settings = services.settings;
    return Scaffold(
      appBar: AppBar(title: const Text(S.settings)),
      body: ListenableBuilder(
        listenable: Listenable.merge([settings, services.config]),
        builder: (context, _) {
          final config = services.config.value;
          final preferred = settings.preferredPlatforms;
          final others = config.enabledPlatforms
              .where((p) => !preferred.contains(p.id) && p.androidPackage != null)
              .toList();
          final theme = Theme.of(context);
          return ListView(
            children: [
              ListTile(
                title: Text(S.preferredPlatforms, style: theme.textTheme.titleMedium),
                subtitle: const Text(S.preferredHint),
              ),
              ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                onReorderItem: (from, to) {
                  final list = List.of(preferred);
                  list.insert(to, list.removeAt(from));
                  settings.setPreferredPlatforms(list);
                },
                children: [
                  for (var i = 0; i < preferred.length; i++)
                    ListTile(
                      key: ValueKey(preferred[i]),
                      leading: PlatformBadge(config.platform(preferred[i]), size: 32),
                      title: Text(config.platform(preferred[i]).name),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () =>
                                settings.setPreferredPlatforms(List.of(preferred)..remove(preferred[i])),
                          ),
                          ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                        ],
                      ),
                    ),
                ],
              ),
              if (others.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final p in others)
                        ActionChip(
                          avatar: PlatformBadge(p, size: 20),
                          label: Text(p.name),
                          onPressed: () => settings.setPreferredPlatforms([...preferred, p.id]),
                        ),
                    ],
                  ),
                ),
              const Divider(height: 32),
              ListTile(
                leading: const Icon(Icons.public),
                title: const Text(S.country),
                subtitle: const Text(S.countryHint),
                trailing: DropdownButton<String>(
                  value: kCountries.containsKey(settings.country) ? settings.country : kDefaultCountry,
                  onChanged: (v) => v == null ? null : settings.setCountry(v),
                  items: [
                    for (final e in kCountries.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.speed),
                title: Text(S.quota(config.quotaPerDay)),
              ),
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text(S.server),
                subtitle: Text(serverLabel(services)),
                onTap: () => _editServer(context),
              ),
              const Divider(height: 32),
              ListTile(
                leading: const Icon(Icons.privacy_tip_outlined),
                title: const Text(S.privacy),
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => const PrivacyScreen())),
              ),
              ListTile(
                leading: Icon(Icons.delete_forever, color: theme.colorScheme.error),
                title: const Text(S.clearData),
                subtitle: const Text(S.clearDataHint),
                onTap: () => _clear(context),
              ),
              AboutListTile(
                icon: const Icon(Icons.info_outline),
                applicationName: S.appName,
                applicationVersion: kAppVersion,
                aboutBoxChildren: [Text('${S.server}: ${serverLabel(services)}')],
                child: const Text(S.about),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Address shown in the list: the user's choice, the built-in one, or "not set".
  static String serverLabel(AppServices services) {
    final url = services.api.currentBaseUrl;
    if (url.isEmpty) return S.serverUnset;
    return services.settings.serverOverride == null ? S.serverDefault(url) : url;
  }

  Future<void> _editServer(BuildContext context) async {
    final services = AppScope.of(context);
    // null: cancelled; empty: back to the built-in address; otherwise the validated address.
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => ServerDialog(
        initial: services.api.currentBaseUrl,
        canReset: services.settings.serverOverride != null,
      ),
    );
    if (choice == null) return;
    await services.settings.setServerOverride(choice.isEmpty ? null : choice);
    final connected = await services.reconnect();
    if (connected) unawaited(services.pending.process());
    if (context.mounted) showSnack(context, connected ? S.serverConnected : S.serverSavedOffline);
  }

  Future<void> _clear(BuildContext context) async {
    final services = AppScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(S.clearDataConfirm),
        content: const Text(S.clearDataHint),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text(S.clear)),
        ],
      ),
    );
    if (ok != true) return;
    await services.history.clearAll();
    await services.settings.reset();
    if (context.mounted) showSnack(context, S.deleted);
  }
}

/// "Máy chủ": the backend address, checked by [ServerAddress.parse] before it is accepted.
class ServerDialog extends StatefulWidget {
  const ServerDialog({super.key, required this.initial, required this.canReset});

  final String initial;

  /// Whether "Mặc định" (drop the user's choice) is offered.
  final bool canReset;

  @override
  State<ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<ServerDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    try {
      Navigator.pop(context, ServerAddress.parse(_controller.text));
    } on ServerAddressException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(S.server),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(S.serverHint),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(hintText: 'https://', errorText: _error, errorMaxLines: 4),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        if (widget.canReset)
          TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text(S.serverUseDefault)),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(S.cancel)),
        FilledButton(onPressed: _save, child: const Text(S.save)),
      ],
    );
  }
}

/// Section 10: what is collected and who processes it.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final engines = AppScope.of(context).config.value.engines;
    final engineText = engines.isEmpty ? 'ACRCloud và AudD' : engines.join(' và ');
    final theme = Theme.of(context);
    Widget section(String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(body),
            ],
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const Text(S.privacy)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          section('Âm thanh',
              'App chỉ thu âm khi bạn bấm nghe, trong tối đa 15 giây. Mẫu âm thanh (hoặc đoạn bạn chọn từ file) '
                  'được gửi tới máy chủ của Tìm Nhạc và chuyển cho dịch vụ nhận diện $engineText. '
                  'Máy chủ xóa mẫu ngay sau khi nhận diện; chỉ giữ kết quả và số liệu ẩn danh.'),
          section('Mã thiết bị',
              'App tạo một mã ngẫu nhiên, không gắn với phần cứng hay danh tính của bạn, để tính hạn mức '
                  'lượt nhận diện mỗi ngày. Xóa dữ liệu trong Cài đặt sẽ tạo mã mới.'),
          section('Lịch sử',
              'Lịch sử nhận diện và mẫu chờ mạng chỉ lưu trên điện thoại, không sao lưu lên đám mây. '
                  'Mẫu chờ mạng tự xóa sau khi gửi.'),
          section('Quyền',
              'Micro: để nghe nhạc khi bạn bấm nút. Thông báo: chỉ khi có mẫu chờ mạng. '
                  'App không xin quyền đọc bộ nhớ; file được chọn qua trình chọn file của hệ thống.'),
          section('Link nghe và tải',
              'App chỉ đề xuất nguồn hợp pháp: nền tảng nghe nhạc, cửa hàng bán nhạc, bài nghệ sĩ cho tải và nhạc '
                  'giấy phép mở. App không tải hay chuyển đổi nhạc từ YouTube, Spotify hay nền tảng khác.'),
        ],
      ),
    );
  }
}
