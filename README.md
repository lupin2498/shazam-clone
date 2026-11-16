# Tìm Nhạc — nhận diện nhạc và truy tìm link nghe/tải hợp pháp đa nền tảng

App Android và iOS (Flutter) nhận diện bài hát từ micro, từ file ghi âm hoặc từ tiếng ngân nga, rồi liệt kê **mọi** link nghe và link tải/mua hợp pháp tìm được trên YouTube, Spotify, SoundCloud, Apple Music, Deezer, Zing MP3, NhacCuaTui và các nguồn giấy phép mở. Mã nguồn làm theo tài liệu thiết kế "App nhận diện nhạc & truy tìm đa nền tảng"; số mục (§) trong README trỏ về tài liệu đó.

```
mobile/    App Flutter: Android (android/) và iOS (ios/) trên cùng mã Dart
backend/   API FastAPI: nhận diện xếp tầng, truy tìm link, hạn mức, Play Integrity
docs/      HANDOFF.md: trạng thái, quyết định đã chốt, việc tiếp theo (đọc trước khi làm tiếp)
```

## Kiến trúc

```
App Flutter ──HTTPS──▶ Backend FastAPI ──▶ ACRCloud (chính) → AudD (dự phòng) → ACRCloud Cover Song (ngân nga)
   │  ▲                     │
   │  └──── SSE: link ◀─────┼──▶ YouTube Data API · Spotify Web API · SoundCloud API · iTunes Search
   │                        │    Deezer API · Odesli (bổ sung) · Jamendo · Internet Archive · Brave Search
   │                        ├──▶ PostgreSQL (track, track_link, recognition, candidate, link_report)
   │                        └──▶ Redis (đệm link theo ISRC, hạn mức thiết bị và API ngoài)
   └─ SQLite trên máy: history, pending_sample
```

- Khóa API chỉ nằm ở backend; app chỉ nói chuyện với backend (§4, §9).
- Mẫu âm thanh chỉ giữ trong bộ nhớ khi nhận diện, không ghi xuống đĩa hay CSDL (§8, §10).
- App và backend **không** tải hay chuyển luồng YouTube/Spotify thành MP3; nhóm "Tải/Mua" chỉ gồm nguồn được cấp phép (§1, §7).

## Đã làm theo tài liệu

| Mã | Yêu cầu | Trạng thái |
| --- | --- | --- |
| F1 | Nghe qua micro một chạm | Có. PCM 16-bit mono 44,1 kHz, nguồn `VOICE_RECOGNITION`, tắt NS/AGC/AEC; gửi thử ở giây 6, gửi đủ ở giây 12 |
| F2 | Nhận diện từ file, kể cả file chia sẻ từ app khác | Có. Trình chọn file hệ thống (không xin quyền bộ nhớ), nhận `ACTION_SEND`/`ACTION_VIEW` audio/video, màn hình cắt đoạn 10–15 giây (mặc định 12 giây ở 30% độ dài), nghe thử, quét cả file mỗi 30 giây |
| F3 | Nhạc không lời | Có. Cờ `is_instrumental` (từ khóa + thể loại), nhãn "Không lời", "Có thể là bản beat", "bản cover của…", tên tác phẩm cho nhạc cổ điển; link tìm bản beat/karaoke; loại bản có lời khi tìm theo tên |
| F4 | Truy tìm trên các nền tảng | Có. 14 adapter chạy song song, mỗi adapter tối đa 3 giây, ngắt mạch riêng |
| F5 | Liệt kê toàn bộ link, tách "Nghe" và "Tải/Mua" | Có. Không cắt bớt; nhãn "Chính xác" / "Tìm trên …"; báo rõ khi không có bản tải miễn phí hợp pháp |
| F6 | Lịch sử trên máy, xem lại link không cần nhận diện lại | Có (SQLite) |
| F7 | Lưu mẫu khi mất mạng, tự nhận diện khi có mạng (GD2) | Có. Hàng chờ `pending_sample`, gửi lại khi có mạng, thông báo khi xong |
| F8 | Ngân nga/huýt sáo (GD2) | Có. Chế độ "Ngân nga" đi thẳng vào bước Cover Song, trả tối đa 3 ứng viên |
| F9 | Tìm trên web khác có danh sách trắng (GD2) | Có khung: Bandcamp, Jamendo, Internet Archive, FMA, Musopen; tìm kiếm web qua Brave Search, chỉ giữ tên miền trong danh sách trắng (tắt khi chưa có khóa — nhà cung cấp chưa chốt, §13) |
| F10 | Nhạc phát trong app khác (GD3) | Chưa làm |
| F11 | Tài khoản, đồng bộ, iOS (GD3) | Có bản iOS (xem [App iOS](#app-ios)); tài khoản và đồng bộ chưa làm |

Thêm so với tài liệu: `POST /v1/recognitions/{id}/report` cho nút "Báo sai" trên màn hình Kết quả, `GET /v1/tracks/{id}`, và `/admin/reports` để duyệt link bị báo cáo trong 48 giờ.

## Backend

### Chạy nhanh (không cần khóa API)

```bash
cd backend
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
DEMO_MODE=true uvicorn app.main:app --reload
```

`DEMO_MODE=true` trả kết quả mẫu thay vì gọi engine, đủ để chạy thử toàn bộ luồng app. Backend từ chối khởi động nếu bật cờ này với `ENVIRONMENT=production`.

### Chạy đủ bộ với PostgreSQL + Redis

```bash
cd backend
cp .env.example .env   # điền khóa API
docker compose up --build
```

### Cấu hình

Mọi biến nằm trong [`backend/.env.example`](backend/.env.example). Thiếu khóa nào thì adapter tương ứng tự lùi về link tìm kiếm sâu, không làm hỏng luồng chính.

| Biến | Dùng cho |
| --- | --- |
| `ACRCLOUD_*` | Engine chính. Bật "3rd Party ID Integration" để có ISRC và ID Spotify/Deezer/YouTube — đây là nguồn link chính vì hạn mức tìm kiếm YouTube/Spotify rất thấp (§6) |
| `ACRCLOUD_HUM_*` | Dự án Cover Song (humming) riêng, nếu có |
| `AUDD_API_TOKEN` | Engine dự phòng; trả kèm link Apple Music, Spotify, Deezer |
| `YOUTUBE_API_KEY` | `search.list` khi engine không trả ID video; backend tự đếm 100 lượt/ngày |
| `SPOTIFY_CLIENT_*` | Tìm theo ISRC rồi theo tên (tối đa 10 kết quả/lần, quy định 2026) |
| `SOUNDCLOUD_CLIENT_*` | Tìm bài, phát hiện bài nghệ sĩ cho tải; token được đệm (giới hạn 50 token/12 giờ) |
| `JAMENDO_CLIENT_ID`, `BRAVE_SEARCH_API_KEY` | Nguồn giấy phép mở và tìm kiếm web danh sách trắng (GD2) |
| `INTEGRITY_MODE`, `PLAY_*`, `GOOGLE_SERVICE_ACCOUNT_FILE` | Play Integrity: `off` khi phát triển, `monitor` để quan sát, `enforce` khi phát hành |
| `QUOTA_PER_DEVICE_PER_DAY` | Hạn mức nhận diện, mặc định 30; một lần chạm (mẫu 6 giây + 12 giây) tính là một lượt |
| `SEARCH_URL_OVERRIDES` | Sửa mẫu link tìm kiếm (ví dụ Zing MP3, NCT) mà không phát hành lại app |

### API

| Endpoint | Chức năng |
| --- | --- |
| `POST /v1/recognitions` | multipart: `audio` (AAC ADTS ≤ 15 giây), `mode` (`auto`/`hum`), `source` (`mic`/`file`/`hum`), `stage` (`early`/`full`), `session_id`, `filename_hint`. Trả `matched` / `candidates` / `no_match`; header `X-Quota-Remaining` |
| `GET /v1/tracks/{id}/links?country=VN[&variant=beat][&stream=false]` | SSE: sự kiện `track`, mỗi adapter một sự kiện `links`, cuối cùng `done`. `stream=false` trả một JSON |
| `GET /v1/search?q=` | Tìm bài thủ công khi không khớp |
| `POST /v1/links/{id}/report` | `reason`: `wrong_song`, `broken`, `violation` (ẩn ngay), `other` (ẩn khi đủ 3 báo cáo) |
| `POST /v1/recognitions/{id}/report` | Nút "Báo sai" |
| `GET /v1/config` | Nền tảng đang bật, ngưỡng điểm, độ dài mẫu, phiên bản app tối thiểu, số dự án Play Integrity |

Mọi yêu cầu kèm `X-Device-Id` (mã ngẫu nhiên, không phải Android ID), `X-App-Version` và — khi bật — `X-Integrity-Token` gắn với `requestHash = sha256(device|session|stage|sha256(audio))`.

Tài liệu OpenAPI: `http://localhost:8000/docs`.

## App Flutter

Yêu cầu Flutter 3.50 trở lên (Material nằm trong gói `material_ui`).

```bash
cd mobile
flutter pub get
flutter run        # bản debug tự trỏ về backend trên máy phát triển
```

### Địa chỉ backend

- Lúc build: `--dart-define=API_BASE_URL=https://api.<tên miền>`.
- Lúc chạy: **Cài đặt → Máy chủ** trong app; địa chỉ nhập ở đây thay cho địa chỉ lúc build, không cần cài lại app.
- Bản debug/profile không có `API_BASE_URL` dùng `http://10.0.2.2:8000` (Android emulator) hoặc `http://127.0.0.1:8000` (iOS simulator). Bản release không có `API_BASE_URL` thì chưa có địa chỉ: app báo vào Cài đặt → Máy chủ để nhập.
- Bản release chỉ gửi qua `https://`, trừ máy chủ trong mạng nội bộ (`192.168.x.x`, `10.x.x.x`, `172.16–31.x.x`, `localhost`, `*.local`) được dùng `http://` để thử với backend chạy trên máy tính cùng Wi-Fi. Bản debug/profile nhận mọi địa chỉ `http://`. Quy tắc nằm ở `lib/services/server_address.dart`, vì engine Flutter không áp cấu hình mạng của Android hay ATS của iOS cho kết nối của Dart.

Thử trên điện thoại thật khi chưa triển khai backend: chạy backend trên máy tính (`DEMO_MODE=true uvicorn app.main:app --host 0.0.0.0`), rồi nhập `http://<IP máy tính>:8000` vào Cài đặt → Máy chủ.

Phát hành:

1. Tạo `android/key.properties` (không commit) với `storeFile`, `storePassword`, `keyAlias`, `keyPassword`.
2. `flutter build appbundle --dart-define=API_BASE_URL=https://api.<tên miền>`
3. Liên kết dự án Google Cloud trong Play Console, đặt `PLAY_CLOUD_PROJECT_NUMBER` và `GOOGLE_SERVICE_ACCOUNT_FILE` ở backend rồi chuyển `INTEGRITY_MODE` sang `monitor`, sau đó `enforce`.

Kích thước APK release đo được: 16–20 MB mỗi ABI (mục tiêu ≤ 25 MB, §10).

### Bộ cài từ GitHub Actions

Mỗi lần push, workflow [`CI`](.github/workflows/ci.yml) build sẵn bộ cài; tải ở mục **Artifacts** của lượt chạy:

| Artifact | Nội dung |
| --- | --- |
| `tim-nhac-android` | APK release cho `arm64-v8a` (đa số điện thoại), `armeabi-v7a` (máy 32-bit cũ), `x86_64` (emulator) |
| `tim-nhac-ios` | `tim-nhac-unsigned.ipa`: bản iOS **chưa ký** |

- Địa chỉ backend ghi vào bộ cài lấy từ biến repo `API_BASE_URL` (Settings → Secrets and variables → Actions → Variables) hoặc ô nhập khi bấm **Run workflow**. Để trống thì người dùng nhập trong app.
- Ký APK: đặt các secret `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Thiếu secret thì APK ký bằng khóa debug của máy build: cài thử được, nhưng mỗi lượt build một chữ ký khác nhau (phải gỡ bản cũ trước khi cài bản mới) và không đưa lên Google Play được.

Phần native nằm ở `mobile/android/app/src/main/kotlin/vn/timnhac/app/`: thu âm (`AudioCapture.kt`), mã hóa AAC 64 kbps dạng ADTS (`AacEncoder.kt`), giải mã file bằng `MediaExtractor` + `MediaCodec` (`AudioFileDecoder.kt`), Play Integrity, thông báo, mở app nền tảng (`MainActivity.kt`, `Helpers.kt`).

### App iOS

`mobile/ios/` (iOS 15 trở lên, bundle id `vn.timnhac.app`) cài cùng các kênh native như Android nên mã Dart không đổi. Mã Swift ở `mobile/ios/Runner/`:

| File | Việc |
| --- | --- |
| `AudioCapture.swift` | Thu âm bằng `AVAudioEngine`, phiên âm thanh ở chế độ `measurement` (tắt tự chỉnh âm lượng và khử ồn), PCM 16-bit mono |
| `AacEncoder.swift` | `AVAudioConverter` → AAC-LC 64 kbps, đóng khung ADTS giống Android |
| `AudioFileDecoder.swift` | `AVAssetReader`: đọc độ dài, vẽ sóng âm, cắt đoạn (cả tiếng trong video) |
| `NativeBridge.swift` | Kênh `vn.timnhac/*`: quyền micro, trình chọn tệp, nhận file "Mở bằng"/chia sẻ từ app khác, bảng chia sẻ, mở link, thông báo, trạng thái mạng |
| `Helpers.swift` | Nghe thử, thông báo cục bộ, theo dõi mạng |

Build cần macOS + Xcode (trên Linux/Windows dùng bộ cài từ GitHub Actions):

```bash
cd mobile
flutter build ios --release --no-codesign      # build/ios/iphoneos/Runner.app
```

Cài file `.ipa` chưa ký lên iPhone:

- Không có tài khoản trả phí: dùng [Sideloadly](https://sideloadly.io) hoặc [AltStore](https://altstore.io) trên máy tính; công cụ ký bằng Apple ID của bạn (bản cài hết hạn sau 7 ngày, cài lại để gia hạn).
- Có tài khoản Apple Developer: mở `mobile/ios/Runner.xcworkspace` bằng Xcode, chọn Team ở Signing & Capabilities rồi Archive để đưa lên TestFlight/App Store.

Khác với Android:

- Chưa có đối ứng của Play Integrity (App Attest): app iOS không gửi `X-Integrity-Token`, nên **đừng bật `INTEGRITY_MODE=enforce`** khi còn người dùng iOS.
- Nhận file từ app khác qua "Mở bằng… / Sao chép vào Tìm Nhạc" (kiểu tài liệu audio/video); chưa có Share Extension riêng.
- iOS không cho app chạy nền để gửi mẫu chờ mạng: hàng chờ được gửi khi mở lại app.
- File được chọn hay nhận về là bản sao trong thư mục tạm của app, tự xóa ở lần mở app sau.

## Kiểm thử

```bash
cd backend && pytest            # chuẩn hóa/chấm điểm, engine, xếp tầng, adapter, API, SSE, hạn mức, báo cáo
cd mobile && flutter test       # SSE, sắp xếp link, luồng nghe 6 s/12 s, hàng chờ offline, quét file, địa chỉ máy chủ, giao diện
```

Phần native được kiểm trên máy ảo (CI chạy cả hai ở mỗi lần push):

```bash
cd mobile
# Kênh native từ đầu tới cuối, trên Android emulator hoặc iOS simulator đang mở:
flutter test integration_test/native_bridge_test.dart -d <id thiết bị>
# Bộ mã hóa AAC, bộ giải mã file và phép đo mức âm của iOS (XCTest):
flutter build ios --config-only --debug --simulator
xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner -destination 'platform=iOS Simulator,name=<tên máy>'
```

## Việc cần làm trước khi phát hành

- Thay huy hiệu chữ cái bằng logo chính thức của từng nền tảng theo hướng dẫn thương hiệu (§7).
- Kiểm tra lại mẫu link tìm kiếm của Zing MP3 và NhacCuaTui trên thiết bị thật (sửa được qua `SEARCH_URL_OVERRIDES`); liên hệ hợp tác để có API (§13).
- Lấy ý kiến pháp lý trước khi mở rộng danh sách trắng tìm kiếm web (§7).
- Đo lại các chỉ tiêu §10 trên bộ thử 200 bài với khóa ACRCloud/AudD thật.
- Dùng công cụ migration (ví dụ Alembic) thay cho `CREATE_TABLES=true` khi lược đồ bắt đầu thay đổi.
- ShazamKit cho Android (GD2, tùy chọn) và iOS (GD3).
- iOS: thử thu âm trên iPhone thật, App Attest cho backend, Share Extension, khai báo quyền riêng tư và ký để đưa lên TestFlight.
