# Bàn giao phiên — Tìm Nhạc (cập nhật 16/11/2026)

Tài liệu này để một phiên làm việc mới tiếp tục dự án mà không cần đọc lại lịch sử. Đọc kèm [README](../README.md) (cách chạy, cấu hình, API).

## 1. Mục tiêu và nguồn yêu cầu

Làm app theo tài liệu thiết kế "App nhận diện nhạc & truy tìm đa nền tảng" (người dùng tải lên ở phiên trước; **tài liệu gốc không nằm trong repo** — nếu cần chi tiết, nhờ người dùng đính kèm lại). Các mục § trong code và README trỏ về tài liệu đó. Tóm tắt yêu cầu cốt lõi:

- App Android (Flutter, iOS sau) nhận diện nhạc từ micro, từ file, từ ngân nga; trả **mọi** link nghe và link tải/mua **hợp pháp** (YouTube, Spotify, SoundCloud, Apple Music, Zing MP3, NCT, nguồn Creative Commons…).
- App chỉ gọi backend riêng; khóa API chỉ ở backend. Không tải/chuyển luồng YouTube/Spotify thành MP3 (chính sách Google Play).
- Xếp tầng nhận diện: ACRCloud 6 s → ACRCloud 12 s → AudD → ACRCloud Cover Song (≤ 3 ứng viên) → không khớp. Chế độ ngân nga đi thẳng bước Cover Song.
- Truy tìm link: ID engine trả về → ISRC → tên + nghệ sĩ (chấm điểm, lệch thời lượng ≤ 3 s); nền tảng không có API dùng link tìm kiếm sâu "Tìm trên …"; đệm 30 ngày (khớp) / 1 ngày (rỗng); đẩy link về app dần qua SSE.
- Chỉ tiêu (§10): tên bài ≤ 8 s (trung vị), link đầu tiên ≤ 2 s sau tên bài, đúng ≥ 90 % có lời / ≥ 75 % không lời, mẫu ≤ 150 KB, APK ≤ 25 MB.
- Giai đoạn: MVP = F1–F6; GD2 = F7 (offline), F8 (ngân nga), F9 (web danh sách trắng); GD3 = F10 (âm thanh nội bộ), F11 (tài khoản, iOS).

## 2. Trạng thái hiện tại

- Repo `lupin2498/shazam-clone`, nhánh **`claude/gallant-darwin-4ynhg5`**, đã push. Chưa có PR (người dùng chưa yêu cầu).
- Commit: `56eb24a` (toàn bộ app + backend), `3b93adb` (sửa dispose TrimScreen, đồng bộ AudioCapture), `f224938` (gọn ô link, cho phép HTTP ở bản profile), cộng commit chứa file này.
- Đã làm F1–F9. Chưa làm F10, F11, iOS, ShazamKit.
- Kiểm thử: backend **57/57** pytest, Flutter **28/28** test, `flutter analyze` sạch. APK release: arm64 18,7 MB, armv7 16,4 MB, x86_64 20,0 MB.
- Đã chạy thật:
  - Backend với PostgreSQL 16 + Redis 7 (chế độ demo); image Docker build và chạy (user `api`, không phải root).
  - App trên emulator Android 14 (bản profile/AOT): chia sẻ MP3 → cắt đoạn → mã hóa AAC → `POST /v1/recognitions` được chấp nhận → màn Kết quả + SSE link; luồng micro 12 s với emulator không có âm thanh → báo "Không nghe thấy âm thanh", không gửi mẫu (đúng thiết kế).

## 3. Chưa kiểm chứng (cần làm khi có điều kiện)

- Chưa có khóa thật: ACRCloud, AudD, YouTube, Spotify, SoundCloud, Jamendo, Brave — chỉ test bằng mock (`respx`). Sandbox phiên trước còn chặn các API công khai (Deezer, iTunes, archive.org).
- Chưa đối chiếu phản hồi thật của ACRCloud: tên khóa kết quả Cover Song (code đọc `metadata.humming` và `metadata.cover_songs`), thang điểm humming (code coi > 1 là thang 0–100), trường ảnh bìa (`album.covers`/`album.cover`).
- Nhận diện qua micro với âm thanh thật; Play Integrity chạy thật; mẫu link tìm kiếm Zing MP3 (`/tim-kiem/bai-hat?q=`) và NCT (`/tim-kiem/bai-hat?q=`) trên máy thật.
- Workflow CI (`.github/workflows/ci.yml`) chưa chạy lần nào trên GitHub.

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
  security/               integrity.py (Play Integrity, request_hash), quota.py (theo session_id)
  routers/                recognitions, tracks (SSE), search, links (report), config, admin
mobile/lib/
  services/recognizer.dart   ListenSession: thu 12 s (15 s ngân nga), gửi thử 6 s, im lặng, offline
  services/api_client.dart   multipart, SSE, mã lỗi tiếng Việt
  services/native_bridge.dart  kênh vn.timnhac/native, levels, shared_files, connectivity
  services/history.dart      SQLite: history, pending_sample; HistoryRepository
  services/pending_queue.dart  gửi lại mẫu khi có mạng + thông báo
  services/link_sorter.dart  nhóm "Nghe"/"Tải/Mua", thứ tự §7, nhãn nút
  screens/                   home, listening, trim, scan, result, outcome_screens, search, history, settings
mobile/android/app/src/main/kotlin/vn/timnhac/app/
  MainActivity.kt   các kênh platform, quyền, picker, intent chia sẻ, mở app nền tảng
  AudioCapture.kt   AudioRecord VOICE_RECOGNITION 44,1 kHz mono, tắt NS/AGC/AEC
  AacEncoder.kt     PCM → AAC-LC 64 kbps ADTS (+ resample)
  AudioFileDecoder.kt  MediaExtractor + MediaCodec: probe, waveform, segment
  Helpers.kt        PreviewPlayer, IntegrityHelper, Notifier, ConnectivityWatcher
```

## 5. Quyết định đã chốt (đừng đảo ngược khi không có lý do)

- Tên app "Tìm Nhạc", package `vn.timnhac.app` (tài liệu không nêu; người dùng có thể đổi — nếu đổi, sửa cả `PLAY_PACKAGE_NAME`).
- Flutter 3.50: Material nằm ở gói `material_ui` (`import 'package:material_ui/material_ui.dart'`); `package:flutter/material.dart` đã deprecated.
- Ít plugin: chỉ `http`, `sqflite`, `path`, `shared_preferences`, `crypto`. Picker, chia sẻ, mở link, thông báo, mạng, Play Integrity viết native trong `MainActivity.kt`.
- Mẫu gửi lên là AAC dạng ADTS để backend đo độ dài từ header, không cần giải mã.
- Hạn mức tính theo `session_id`: mẫu 6 s và 12 s của cùng một lần chạm = 1 lượt; mỗi đoạn khi "Quét cả file" tính riêng.
- `requestHash = sha256(device_id|session_id|stage|sha256(audio))` — Dart (`integrity.dart`) và Python (`security/integrity.py`) phải khớp.
- Chấm điểm: tiêu đề 0,55 + nghệ sĩ 0,30 + thời lượng 0,15; ngưỡng 0,72; lệch > 3 s → loại; bản cover/remix/live hoặc lệch nhãn không lời → nhân 0,3.
- "Tải offline" của YouTube gắn vào YouTube Music; Bandcamp luôn có link tìm kiếm ở nhóm Mua; tìm kiếm CC (FMA, Jamendo, Musopen) chỉ cho bài không lời; Odesli chỉ bổ sung nền tảng phụ.
- Link bị báo "violation" ẩn ngay; lý do khác ẩn khi đủ 3 báo cáo; duyệt qua `/admin/reports` (cần `ADMIN_TOKEN`).
- `DEMO_MODE=true` trả kết quả mẫu; backend từ chối khởi động nếu bật cùng `ENVIRONMENT=production`.
- Bản debug và profile cho phép HTTP thường (thử với backend cục bộ); bản release chỉ HTTPS.

## 6. Thiết lập môi trường cho phiên mới

Phiên cloud nên chạy trên môi trường **shazam-clone** (đã cho phép `dl.google.com` cho Google Maven/Android SDK). Môi trường này có setup script (chưa được kiểm chứng ở một phiên mới) cài:

- Flutter 3.50.0 vào `/opt/flutter-sdk` (tarball từ storage.googleapis.com), thêm vào PATH trong `/root/.bashrc`, chạy `flutter pub get` ở `mobile/`.
- venv `/opt/venv-backend` với `backend/requirements-dev.txt`.

Kiểm tra nhanh sau khi vào phiên:

```bash
cd backend && /opt/venv-backend/bin/python -m pytest -q
```
```bash
cd mobile && flutter analyze && flutter test
```

**Android SDK không có trong setup script** vì cài nó cần chấp nhận giấy phép Android SDK — hỏi người dùng trước. Hai cách đã biết:

1. Cách chuẩn (cần `dl.google.com`, đã được cho phép): tải command-line tools (phiên trước thấy URL `https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip`, chưa tự chạy), giải nén vào `/opt/android-sdk/cmdline-tools/latest`, để người dùng chấp nhận giấy phép, rồi `sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0"`.
2. Cách phiên trước đã dùng khi `dl.google.com` còn bị chặn: lấy thẳng các layer của image Docker Hub `cimg/android:2026.11.1-ndk` qua registry API (layer 13 cmdline-tools, 14 platform-tools + build-tools, 15 platforms, 18 cmake) và giải nén `home/circleci/android-sdk/*` vào `/opt/android-sdk`.

Sau đó: `export ANDROID_HOME=/opt/android-sdk`, `flutter config --android-sdk /opt/android-sdk`. Lần build đầu Gradle tự cài NDK 28.2.13676358 và CMake 3.22.1 (~2,5 phút).

Ghi chú môi trường:

- Docker daemon không tự chạy: `dockerd > /tmp/dockerd.log 2>&1 &`. Kéo image từ Docker Hub được; `ghcr.io` thì không (blob bị chặn).
- `docker build` của backend lỗi SSL khi `pip install` vì proxy của sandbox; để thử, dùng bản Dockerfile tạm có thêm CA `/root/.ccr/ca-bundle.crt` và `PIP_CERT` (không commit thay đổi đó).
- PostgreSQL 16 có sẵn ở `/usr/lib/postgresql/16/bin`; thư mục dữ liệu phải nằm chỗ user `postgres` đọc được (ví dụ `/var/tmp/...`, không dùng `/tmp/claude-0`). `redis-server` có sẵn.
- Không có KVM: emulator chạy được ở chế độ phần mềm nhưng rất chậm (khởi động ~10 phút). Dùng image `system-images;android-34;aosp_atd;x86_64`, đặt `disk.dataPartition.size=1024M`, cài **bản profile** (`flutter build apk --profile --target-platform android-x64`) — bản debug JIT gây ANR. Đưa file vào app: `adb push` vào `/data/local/tmp` rồi `run-as vn.timnhac.app cp … files/`, mở bằng intent `SEND` với URI `file:///data/user/0/vn.timnhac.app/files/<tên>`. Emulator + image tốn ~9 GB; ổ phiên có hạn mức, xóa khi xong.
- Flutter 3.50 chạy Dart trên luồng chính Android: việc nặng phải để native (worker thread) hoặc isolate.

## 7. Việc tiếp theo đề xuất (theo thứ tự)

1. Khi người dùng có khóa: điền `backend/.env`, chạy thử với ACRCloud/AudD thật, đối chiếu định dạng phản hồi (mục 3), chỉnh ngưỡng `ACR_MIN_SCORE`, `ACR_EARLY_MIN_SCORE`, `HUM_MIN_CONFIDENCE`.
2. Đo chỉ tiêu §10 trên bộ thử 200 bài (100 có lời, 100 không lời); ghi kết quả.
3. Kiểm tra mẫu link tìm kiếm Zing MP3/NCT trên máy thật; sửa qua `SEARCH_URL_OVERRIDES` nếu cần.
4. Thay huy hiệu chữ cái bằng logo chính thức theo hướng dẫn thương hiệu từng nền tảng (§7).
5. Thêm Alembic (hiện dùng `CREATE_TABLES=true` / `create_all`).
6. Hoàn hạn mức khi mọi engine lỗi (hiện lượt vẫn bị trừ khi trả 503).
7. Cấu hình Play Integrity thật (`PLAY_CLOUD_PROJECT_NUMBER`, service account), chạy `INTEGRITY_MODE=monitor` rồi `enforce`.
8. Chạy CI trên GitHub; tạo PR khi người dùng yêu cầu.
9. GD2/GD3: ShazamKit (tùy chọn), F10, F11, iOS (viết kênh native `AVAudioEngine` tương ứng `MainActivity.kt`).

Việc nhỏ đã biết: nút "OK" của banner "app đã cũ" ở trang chủ chưa làm gì; tìm kiếm lịch sử chưa xử lý chuỗi Unicode dạng tổ hợp (NFD); `split_artists` của AudD tách theo ", " có thể tách sai tên kiểu "Tyler, The Creator".
