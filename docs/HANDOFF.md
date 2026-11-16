# Bàn giao phiên — Tìm Nhạc (cập nhật 16/11/2026, phiên 2)

Tài liệu này để một phiên làm việc mới tiếp tục dự án mà không cần đọc lại lịch sử. Đọc kèm [README](../README.md) (cách chạy, cấu hình, API, bản iOS) và [báo cáo kiểm thử](BAO-CAO-KIEM-THU.md).

## 1. Mục tiêu và nguồn yêu cầu

Làm app theo tài liệu thiết kế "App nhận diện nhạc & truy tìm đa nền tảng" (người dùng tải lên ở phiên đầu; **tài liệu gốc không nằm trong repo** — nếu cần chi tiết, nhờ người dùng đính kèm lại). Các mục § trong code và README trỏ về tài liệu đó. Tóm tắt yêu cầu cốt lõi:

- App Android + iOS (Flutter) nhận diện nhạc từ micro, từ file, từ ngân nga; trả **mọi** link nghe và link tải/mua **hợp pháp** (YouTube, Spotify, SoundCloud, Apple Music, Zing MP3, NCT, nguồn Creative Commons…).
- App chỉ gọi backend riêng; khóa API chỉ ở backend. Không tải/chuyển luồng YouTube/Spotify thành MP3 (chính sách Google Play).
- Xếp tầng nhận diện: ACRCloud 6 s → ACRCloud 12 s → AudD → ACRCloud Cover Song (≤ 3 ứng viên) → không khớp. Chế độ ngân nga đi thẳng bước Cover Song.
- Truy tìm link: ID engine trả về → ISRC → tên + nghệ sĩ (chấm điểm, lệch thời lượng ≤ 3 s); nền tảng không có API dùng link tìm kiếm sâu "Tìm trên …"; đệm 30 ngày (khớp) / 1 ngày (rỗng); đẩy link về app dần qua SSE.
- Chỉ tiêu (§10): tên bài ≤ 8 s (trung vị), link đầu tiên ≤ 2 s sau tên bài, đúng ≥ 90 % có lời / ≥ 75 % không lời, mẫu ≤ 150 KB, APK ≤ 25 MB.
- Giai đoạn: MVP = F1–F6; GD2 = F7 (offline), F8 (ngân nga), F9 (web danh sách trắng); GD3 = F10 (âm thanh nội bộ), F11 (tài khoản, iOS).

## 2. Trạng thái hiện tại

- Repo `lupin2498/shazam-clone`, nhánh làm việc **`ccr-f60ecfdd-76t6yr`** (đã push; tách từ `claude/gallant-darwin-4ynhg5` ở `a31fae8`). Chưa có PR (người dùng chưa yêu cầu).
- Đã làm F1–F9 và bản iOS của F11. Chưa làm F10, tài khoản/đồng bộ, ShazamKit, App Attest.
- Phiên 2 thêm:
  - **App iOS** (`mobile/ios/`): lớp native Swift cài đúng các kênh `vn.timnhac/*` như Android, nên mã Dart dùng chung. Đã sửa theo một lượt soát mã độc lập (crash "Nghe thử", thu âm bị ngắt khi có cuộc gọi/cắm tai nghe, phiên âm thanh làm tắt nhạc app khác).
  - **Cài đặt → Máy chủ**: địa chỉ backend chọn lúc chạy (`lib/services/server_address.dart`); bản release không có `API_BASE_URL` thì app bảo người dùng nhập.
  - **Kiểm thử và sửa lỗi** bởi agent test-fix-bug: xem `docs/BAO-CAO-KIEM-THU.md` (bảng lỗi đã/chưa sửa, phần chưa kiểm chứng) và sổ tay `.test-fix-bug/`.
  - **CI build bộ cài**: mỗi lần push có artifact `tim-nhac-android` (APK release 3 ABI) và `tim-nhac-ios` (IPA chưa ký).
- Kiểm thử: backend **140** pytest (`pytest -q` chạy được như CI), Flutter **76** test, `flutter analyze` sạch. Ở CI: XCTest iOS **14/14** (`mobile/ios/RunnerTests`) và test kênh native `mobile/integration_test/native_bridge_test.dart` **9/9** trên simulator iOS (kể cả thu âm và nghe thử); cùng test kênh 9/9 trên emulator Android (micro đã cấp quyền).
- APK release (khóa debug, không gắn địa chỉ máy chủ): arm64 ~18,7 MB, armv7 ~16,4 MB, x86_64 ~20,0 MB.

## 3. Chưa kiểm chứng (cần làm khi có điều kiện)

- Chưa có khóa thật: ACRCloud, AudD, YouTube, Spotify, SoundCloud, Jamendo, Brave — chỉ test bằng mock (`respx`). Mạng của phiên chặn các API công khai (Deezer, iTunes, archive.org…).
- Chưa đối chiếu phản hồi thật của ACRCloud: tên khóa kết quả Cover Song (code đọc `metadata.humming` và `metadata.cover_songs`), thang điểm humming, trường ảnh bìa (`album.covers`/`album.cover`).
- Android: nhận diện qua micro với âm thanh thật trên máy thật; Play Integrity chạy thật; mẫu link tìm kiếm Zing MP3/NCT trên máy thật.
- iOS — **chưa chạy trên iPhone thật** (simulator không có cuộc gọi, tai nghe hay app nhạc khác): thu âm với phiên `playAndRecord` + `mixWithOthers` + `measurement`, tiếp tục thu sau cuộc gọi/Siri/đổi tai nghe, "Mở bằng" từ app khác khi app đang tắt, trình chọn tệp, thông báo, quyền mạng nội bộ.
- Timeout 25 s của app sát trường hợp xấu nhất của backend (2 engine × 10 s) — chưa đo với khóa thật.

## 4. Bản đồ code

```
backend/app/
  main.py                 create_app(): lifespan dựng httpx, DB, cache, services
  config.py               Settings (mọi biến môi trường; xem backend/.env.example)
  models.py               track, track_link (+hidden), recognition, candidate, link_report, recognition_report
  audio.py                kiểm tra mẫu: ADTS/WAV, độ dài ≤ 15,5 s, ≤ 2 MB
  text.py                 chuẩn hóa tên, is_instrumental, score_match (ngưỡng 0,72)
  platforms.py            danh sách nền tảng + mẫu URL tìm kiếm ({q}, {qp}, {country})
  recognition/            acrcloud.py, audd.py, demo.py, cascade.py (xếp tầng + cờ maybe_beat/cover/melody)
  links/resolver.py       chạy adapter song song, timeout, ngắt mạch, đệm Redis, lưu track_link
  links/adapters/         youtube, spotify, soundcloud, apple(+iTunes), deezer, vn (Zing/NCT), odesli,
                          open_sources (Bandcamp, Jamendo, Internet Archive, CC search), web_search (Brave)
  security/               integrity.py (Play Integrity, request_hash), quota.py (theo session_id + stage)
  routers/                recognitions, tracks (SSE), search, links (report), config, admin
backend/tests/live/smoke.py  kiểm thử khói qua HTTP thật (uvicorn + PostgreSQL + Redis), xem sổ tay
mobile/lib/
  services/recognizer.dart   ListenSession: thu 12 s (15 s ngân nga), gửi thử 6 s, im lặng, offline
  services/api_client.dart   multipart, SSE (canh im lặng 20 s), mã lỗi tiếng Việt, địa chỉ máy chủ
  services/server_address.dart  kiểm địa chỉ backend: release chỉ https://, trừ máy trong mạng nội bộ
  services/native_bridge.dart  hợp đồng kênh vn.timnhac/native, levels, shared_files, connectivity
  services/history.dart      SQLite: history, pending_sample; HistoryRepository
  services/pending_queue.dart  gửi lại mẫu khi có mạng + thông báo
  services/link_sorter.dart  nhóm "Nghe"/"Tải/Mua", thứ tự §7, nhãn nút
  screens/                   home, listening, trim, scan, result, outcome_screens, search, history, settings (+ ServerDialog)
mobile/android/app/src/main/kotlin/vn/timnhac/app/
  MainActivity.kt   các kênh platform, quyền, picker, intent chia sẻ, mở app nền tảng
  AudioCapture.kt   AudioRecord VOICE_RECOGNITION 44,1 kHz mono, tắt NS/AGC/AEC
  AacEncoder.kt     PCM → AAC-LC 64 kbps ADTS (+ resample)
  AudioFileDecoder.kt  MediaExtractor + MediaCodec: probe, waveform, segment
  Helpers.kt        PreviewPlayer, IntegrityHelper, Notifier, ConnectivityWatcher
mobile/ios/Runner/
  NativeBridge.swift   các kênh vn.timnhac/*, quyền micro, trình chọn tệp, "Mở bằng", chia sẻ, mở link
  AudioCapture.swift   AVAudioEngine, tự chạy lại sau ngắt/đổi thiết bị
  AacEncoder.swift     AVAudioConverter → AAC-LC 64 kbps ADTS (cùng khung với Android)
  AudioFileDecoder.swift  AVAssetReader: probe, waveform, segment
  Helpers.swift        PreviewPlayer, Notifier, ConnectivityWatcher
mobile/ios/RunnerTests/RunnerTests.swift   XCTest cho mã hóa/giải mã/đo mức
mobile/integration_test/native_bridge_test.dart   test kênh native trên emulator/simulator
.github/workflows/ci.yml   backend, mobile (+APK), android (emulator), ios (IPA + XCTest + kênh)
```

## 5. Quyết định đã chốt (đừng đảo ngược khi không có lý do)

- Tên app "Tìm Nhạc", package/bundle id `vn.timnhac.app` trên cả Android và iOS (tài liệu không nêu; người dùng có thể đổi — nếu đổi, sửa cả `PLAY_PACKAGE_NAME`, `PRODUCT_BUNDLE_IDENTIFIER` và lệnh `simctl privacy` trong CI).
- Flutter 3.50: Material nằm ở gói `material_ui` (`import 'package:material_ui/material_ui.dart'`); `package:flutter/material.dart` đã deprecated.
- Ít plugin: chỉ `http`, `sqflite`, `path`, `shared_preferences`, `crypto` (dev: `integration_test`, `sqflite_common_ffi`, `fake_async`). Picker, chia sẻ, mở link, thông báo, mạng, Play Integrity viết native.
- Hợp đồng kênh `vn.timnhac/*` (tên method, tham số, kiểu trả về trong `native_bridge.dart`) là chung cho Kotlin và Swift: đổi một bên phải đổi cả hai.
- Mẫu gửi lên là AAC dạng ADTS để backend đo độ dài từ header, không cần giải mã.
- Hạn mức tính theo `session_id`: mẫu 6 s và 12 s của cùng một lần chạm = 1 lượt; mỗi đoạn khi "Quét cả file" tính riêng; hoàn lượt khi mọi engine lỗi.
- `requestHash = sha256(device_id|session_id|stage|sha256(audio))` — Dart (`integrity.dart`) và Python (`security/integrity.py`) phải khớp; có test véc-tơ cố định ở cả hai phía.
- Chấm điểm: tiêu đề 0,55 + nghệ sĩ 0,30 + thời lượng 0,15; ngưỡng 0,72; lệch > 3 s → loại; bản cover/remix/live hoặc lệch nhãn không lời → nhân 0,3.
- "Tải offline" của YouTube gắn vào YouTube Music; Bandcamp luôn có link tìm kiếm ở nhóm Mua; tìm kiếm CC (FMA, Jamendo, Musopen) chỉ cho bài không lời; Odesli chỉ bổ sung nền tảng phụ.
- Link bị báo "violation" ẩn ngay; lý do khác ẩn khi đủ 3 báo cáo; duyệt qua `/admin/reports` (cần `ADMIN_TOKEN`).
- `DEMO_MODE=true` trả kết quả mẫu; backend từ chối khởi động nếu bật cùng `ENVIRONMENT=production`.
- Địa chỉ backend: `--dart-define=API_BASE_URL` lúc build, hoặc Cài đặt → Máy chủ lúc chạy (thắng địa chỉ lúc build). Bản release chỉ gửi qua `https://`, **trừ máy chủ trong mạng nội bộ** (`192.168.x.x`, `10.x.x.x`, `172.16–31.x.x`, `localhost`, `*.local`) để thử với backend trên máy tính cùng Wi-Fi — đây là nới so với "release chỉ HTTPS" của phiên 1; người dùng có thể bảo siết lại. Quy tắc nằm trong Dart vì engine Flutter không áp cấu hình mạng Android/ATS cho `dart:io`.
- iOS thu âm bằng `playAndRecord` + `mixWithOthers` + `measurement` (nhạc app khác vẫn phát và micro nghe được, như Android). iOS chưa có App Attest: **giữ `INTEGRITY_MODE` ở `off`/`monitor`** khi còn người dùng iOS.
- CI: lượt chạy do push không bị hủy khi có push mới (để giữ bộ cài của commit đó); lượt pull request thì hủy. Địa chỉ backend cho bộ cài CI lấy từ biến repo `API_BASE_URL`; khóa ký APK từ các secret `ANDROID_KEYSTORE_*`.

## 6. Thiết lập môi trường cho phiên mới

Phiên cloud chạy trên môi trường **shazam-clone** (cho phép `dl.google.com`). Setup script cài Flutter 3.50.0 vào `/opt/flutter-sdk/flutter` (PATH trong `/root/.bashrc`), chạy `flutter pub get` ở `mobile/` và tạo venv `/opt/venv-backend`. Phiên 2 xác nhận script chạy đúng ở phiên mới.

```bash
cd backend && /opt/venv-backend/bin/python -m pytest -q
cd mobile && flutter analyze && flutter test
```

**Android SDK không có trong setup script** vì cài nó cần chấp nhận giấy phép Android SDK của Google — hỏi người dùng trước khi đưa vào script. Phiên 2 cài tay (người dùng yêu cầu xuất APK):

1. Tải `https://dl.google.com/android/repository/commandlinetools-linux-16111833_latest.zip` (SHA-1 `e025545c62a8e64c7559119566a569fb1dec5f60`), giải nén vào `/opt/android-sdk/cmdline-tools/latest`.
2. `yes | sdkmanager --licenses`, rồi `sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0" "ndk;28.2.13676358" "cmake;3.22.1"` (~2,7 GB).
3. `export ANDROID_HOME=/opt/android-sdk`, `flutter config --android-sdk /opt/android-sdk`.

Ghi chú môi trường:

- Maven Central đôi khi trả 429 khi Gradle tải nhiều cùng lúc: chạy lại lệnh build là qua (lần đầu mất vài lượt).
- Không tải được artifact của GitHub Actions về phiên (host `*.blob.core.windows.net` bị chặn): IPA chỉ lấy được từ trang Actions.
- Không có macOS: bản iOS chỉ build/test được trên CI (`macos-latest`). Máy macOS có thể phải chờ ~10 phút; simulator khởi động lần đầu ~6 phút; cả job iOS ~25 phút.
- Bash trong worktree của agent từ chối lệnh "quá phức tạp" (heredoc, chuỗi lệnh có git): xem `.test-fix-bug/SO-TAY.md`.
- Docker daemon không tự chạy: `dockerd > /tmp/dockerd.log 2>&1 &`. Kéo image từ Docker Hub được; `ghcr.io` thì không.
- `docker build` của backend lỗi SSL khi `pip install` vì proxy của sandbox; để thử, dùng bản Dockerfile tạm có thêm CA `/root/.ccr/ca-bundle.crt` và `PIP_CERT` (không commit thay đổi đó).
- PostgreSQL 16 có sẵn ở `/usr/lib/postgresql/16/bin` (initdb bằng `runuser -u postgres`, dữ liệu dưới `/var/tmp`); `redis-server` có sẵn.
- Không có KVM: emulator Android chạy phần mềm rất chậm (khởi động ~10 phút, ~9 GB). CI chạy emulator có KVM, nên test kênh native để CI làm.
- Flutter 3.50 chạy Dart trên luồng chính Android: việc nặng phải để native (worker thread) hoặc isolate.

## 7. Việc tiếp theo đề xuất (theo thứ tự)

1. Xem lượt CI mới nhất của nhánh: job `ios` phải xanh cả XCTest lẫn test kênh trên simulator; nếu đỏ, đọc log bước "Platform channels on the simulator".
2. Cài thử APK trên điện thoại Android thật và IPA (ký bằng Sideloadly/AltStore) trên iPhone thật với backend `DEMO_MODE=true` chạy trên máy tính cùng Wi-Fi: thu âm, nghe thử, chọn file, "Mở bằng", hàng chờ offline.
3. Khi người dùng có khóa: điền `backend/.env`, chạy thử với ACRCloud/AudD thật, đối chiếu định dạng phản hồi (mục 3), chỉnh ngưỡng `ACR_MIN_SCORE`, `ACR_EARLY_MIN_SCORE`, `HUM_MIN_CONFIDENCE`; đo timeout.
4. Đo chỉ tiêu §10 trên bộ thử 200 bài (100 có lời, 100 không lời); ghi kết quả.
5. iOS: App Attest/DeviceCheck (hoặc backend miễn kiểm Integrity cho iOS), PHPicker để chọn video từ Ảnh, Share Extension, tài khoản Apple Developer để ký và đưa lên TestFlight.
6. Kiểm tra mẫu link tìm kiếm Zing MP3/NCT trên máy thật; sửa qua `SEARCH_URL_OVERRIDES` nếu cần.
7. Thay huy hiệu chữ cái bằng logo chính thức theo hướng dẫn thương hiệu từng nền tảng (§7).
8. Thêm Alembic (hiện dùng `CREATE_TABLES=true` / `create_all`).
9. Cấu hình Play Integrity thật (`PLAY_CLOUD_PROJECT_NUMBER`, service account), chạy `INTEGRITY_MODE=monitor`.
10. Tạo PR khi người dùng yêu cầu; GD3: F10, tài khoản/đồng bộ, ShazamKit.

Các việc nhỏ ở phiên 1 (nút OK của banner "app đã cũ", tìm lịch sử với Unicode tổ hợp, `split_artists` với "Tyler, The Creator", hoàn lượt khi engine lỗi) đã sửa. Lỗi còn lại: mục 4 của báo cáo kiểm thử.
