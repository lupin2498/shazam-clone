import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../config.dart';
import '../l10n/strings.dart';
import '../services/app_services.dart';
import '../services/drive_sync.dart';
import '../services/google_account.dart';
import '../services/native_bridge.dart';
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
        listenable: Listenable.merge([settings, services.config, services.sync, services.account]),
        builder: (context, _) {
          final config = services.config.value;
          final preferred = settings.preferredPlatforms;
          final others = config.enabledPlatforms
              .where((p) => !preferred.contains(p.id) && p.androidPackage != null)
              .toList();
          final theme = Theme.of(context);
          return ListView(
            children: [
              SyncSection(services: services),
              const Divider(height: 32),
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
                subtitle: Text(services.account.signedIn
                    ? '${serverLabel(services)} · ${S.serverSynced}'
                    : serverLabel(services)),
                onTap: () => _editServer(context),
              ),
              if (services.playbackCaptureSupported) ...[
                const Divider(height: 32),
                ListTile(
                  title: Text(S.playbackSection, style: theme.textTheme.titleMedium),
                  subtitle: const Text(S.playbackHint),
                ),
                ListTile(
                  leading: const Icon(Icons.dashboard_customize_outlined),
                  title: const Text(S.playbackAddTile),
                  onTap: () => _addTile(context),
                ),
                ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: const Text(S.playbackListenNow),
                  subtitle: const Text(S.playbackListenNowHint),
                  onTap: () => services.native.startPlaybackCapture(),
                ),
              ],
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

  /// Android 13+ adds the tile from a system dialog; older versions get the manual steps.
  Future<void> _addTile(BuildContext context) async {
    final native = AppScope.of(context).native;
    int code;
    try {
      code = await native.requestAddQuickSettingsTile();
    } catch (_) {
      code = QuickTileResult.unavailable;
    }
    if (!context.mounted) return;
    switch (code) {
      case QuickTileResult.added:
        showSnack(context, S.playbackTileAdded);
      case QuickTileResult.alreadyAdded:
        showSnack(context, S.playbackTileExists);
      case QuickTileResult.notAdded:
        break; // the user said no
      default:
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text(S.playbackAddTile),
            content: const Text(S.playbackAddTileManual),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(S.ok))],
          ),
        );
    }
  }

  Future<void> _clear(BuildContext context) async {
    final services = AppScope.of(context);
    // Signed in, the history would come back from Drive: this device signs out too.
    final signedIn = services.account.signedIn;
    var everywhere = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text(S.clearDataConfirm),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(S.clearDataHint),
              if (signedIn) ...[
                const SizedBox(height: 8),
                const Text(S.clearDataSyncedHint),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: everywhere,
                  onChanged: (v) => setState(() => everywhere = v ?? false),
                  title: const Text(S.clearDataEverywhere),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text(S.clear)),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (signedIn) {
      if (everywhere) await services.sync.clearEverywhere();
      await services.sync.signOut();
    }
    await services.history.clearAll();
    await services.settings.reset();
    if (context.mounted) showSnack(context, S.deleted);
  }
}

/// "Đồng bộ Google Drive": sign in, status of the last sync, sign out.
class SyncSection extends StatelessWidget {
  const SyncSection({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final account = services.account;
    final sync = services.sync;
    final header = ListTile(title: Text(S.syncSection, style: Theme.of(context).textTheme.titleMedium));
    if (!account.configured) {
      return Column(children: [
        header,
        const ListTile(leading: Icon(Icons.cloud_off_outlined), title: Text(S.syncNotConfigured)),
      ]);
    }
    if (!account.signedIn) {
      return Column(children: [
        header,
        ListTile(
          leading: const Icon(Icons.cloud_outlined),
          title: const Text(S.syncSignIn),
          subtitle: const Text(S.syncSignInHint),
          onTap: () => _signIn(context),
        ),
      ]);
    }
    final needsSignIn = sync.state == SyncState.needsSignIn || sync.state == SyncState.noDriveAccess;
    return Column(children: [
      header,
      ListTile(
        leading: Icon(needsSignIn ? Icons.cloud_off_outlined : Icons.cloud_done_outlined),
        title: Text(account.email ?? ''),
        subtitle: Text(syncStatusText(sync, DateTime.now())),
        trailing: sync.state == SyncState.syncing
            ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : IconButton(tooltip: S.syncNow, icon: const Icon(Icons.sync), onPressed: () => sync.sync()),
        onTap: needsSignIn ? () => _signIn(context) : null,
      ),
      ListTile(
        leading: const Icon(Icons.logout),
        title: const Text(S.syncSignOut),
        onTap: () => _signOut(context),
      ),
    ]);
  }

  Future<void> _signIn(BuildContext context) async {
    final sync = services.sync;
    try {
      final ok = await sync.signIn();
      if (ok && sync.lastRestored && context.mounted) showSnack(context, S.syncRestored);
    } on GoogleAuthException catch (e) {
      if (!context.mounted) return;
      showSnack(
        context,
        e.code == 'not_configured'
            ? S.syncSignInNotConfigured
            : e.isNetwork
                ? S.syncOffline
                : S.syncSignInFailed,
      );
    }
  }

  Future<void> _signOut(BuildContext context) async {
    var deleteRemote = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text(S.syncSignOutTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(S.syncSignOutBody),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: deleteRemote,
                onChanged: (v) => setState(() => deleteRemote = v ?? false),
                title: const Text(S.syncDeleteRemote),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text(S.syncSignOut)),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final deleted = await services.sync.signOut(deleteRemote: deleteRemote);
    if (deleteRemote && !deleted && context.mounted) showSnack(context, S.syncDeleteRemoteFailed);
  }
}

/// The status line under the account: what the last sync did, or why it could not.
String syncStatusText(SyncService sync, DateTime now) => switch (sync.state) {
      SyncState.syncing => S.syncing,
      SyncState.offline => S.syncOffline,
      SyncState.needsSignIn => S.syncNeedsSignIn,
      SyncState.noDriveAccess => S.syncNoDriveAccess,
      SyncState.driveFull => S.syncDriveFull,
      SyncState.newerFormat => S.syncNewerFormat,
      SyncState.failed => S.syncFailed,
      SyncState.idle || SyncState.ok =>
        sync.lastSyncedAt == null ? S.syncNever : S.syncedAt(formatSyncTime(sync.lastSyncedAt!, now)),
    };

/// "lúc 14:05" today, "lúc 14:05 ngày 16/11" otherwise.
String formatSyncTime(DateTime t, DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  final time = 'lúc ${two(t.hour)}:${two(t.minute)}';
  final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
  return sameDay ? time : '$time ngày ${two(t.day)}/${two(t.month)}';
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
              'Lịch sử nhận diện và mẫu chờ mạng lưu trên điện thoại. Mẫu chờ mạng tự xóa sau khi gửi. '
                  'Nếu bạn bật Đồng bộ Google Drive, lịch sử (không gồm âm thanh) và cài đặt được lưu trong '
                  'thư mục riêng của Tìm Nhạc trên Google Drive của bạn. App chỉ xin quyền với thư mục đó và '
                  'địa chỉ email, không đọc được file nào khác. Đăng xuất hoặc Xóa dữ liệu để dừng đồng bộ.'),
          section('Quyền',
              'Micro: để nghe nhạc khi bạn bấm nút. Thông báo: khi có mẫu chờ mạng hoặc kết quả nhận diện '
                  'chạy nền. Ghi màn hình (Android 10+, chỉ khi bạn chạm ô Tìm Nhạc trong Cài đặt nhanh): để thu '
                  'âm thanh các app khác đang phát trong khoảng 12 giây; app không ghi hình. '
                  'App không xin quyền đọc bộ nhớ; file được chọn qua trình chọn file của hệ thống.'),
          section('Link nghe và tải',
              'App chỉ đề xuất nguồn hợp pháp: nền tảng nghe nhạc, cửa hàng bán nhạc, bài nghệ sĩ cho tải và nhạc '
                  'giấy phép mở. App không tải hay chuyển đổi nhạc từ YouTube, Spotify hay nền tảng khác.'),
        ],
      ),
    );
  }
}
