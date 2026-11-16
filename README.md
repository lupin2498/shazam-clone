# Tìm Nhạc — nhận diện nhạc và truy tìm link nghe/tải hợp pháp đa nền tảng

App Android (Flutter) nhận diện bài hát từ micro, từ file ghi âm hoặc từ tiếng ngân nga, rồi liệt kê **mọi** link nghe và link tải/mua hợp pháp tìm được trên YouTube, Spotify, SoundCloud, Apple Music, Deezer, Zing MP3, NhacCuaTui và các nguồn giấy phép mở. Mã nguồn làm theo tài liệu thiết kế "App nhận diện nhạc & truy tìm đa nền tảng"; số mục (§) trong README trỏ về tài liệu đó.

```
mobile/    App Flutter (Android trước, iOS sau trên cùng codebase)
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
| F11 | Tài khoản, đồng bộ, iOS (GD3) | Chưa làm. Phần Dart dùng chung được; iOS cần viết kênh native (`AVAudioEngine`) tương ứng `MainActivity.kt` |

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
# Backend chạy trên máy phát triển, nhìn từ Android emulator:
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

Bản debug cho phép HTTP thường để thử với backend cục bộ; bản release chỉ dùng HTTPS.

Phát hành:

1. Tạo `android/key.properties` (không commit) với `storeFile`, `storePassword`, `keyAlias`, `keyPassword`.
2. `flutter build appbundle --dart-define=API_BASE_URL=https://api.<tên miền>`
3. Liên kết dự án Google Cloud trong Play Console, đặt `PLAY_CLOUD_PROJECT_NUMBER` và `GOOGLE_SERVICE_ACCOUNT_FILE` ở backend rồi chuyển `INTEGRITY_MODE` sang `monitor`, sau đó `enforce`.

Kích thước APK release đo được: 16–20 MB mỗi ABI (mục tiêu ≤ 25 MB, §10).

Phần native nằm ở `mobile/android/app/src/main/kotlin/vn/timnhac/app/`: thu âm (`AudioCapture.kt`), mã hóa AAC 64 kbps dạng ADTS (`AacEncoder.kt`), giải mã file bằng `MediaExtractor` + `MediaCodec` (`AudioFileDecoder.kt`), Play Integrity, thông báo, mở app nền tảng (`MainActivity.kt`, `Helpers.kt`).

## Kiểm thử

```bash
cd backend && pytest            # 57 test: chuẩn hóa/chấm điểm, engine, xếp tầng, adapter, API, SSE, hạn mức, báo cáo
cd mobile && flutter test       # 28 test: SSE, sắp xếp link, luồng nghe 6 s/12 s, hàng chờ offline, quét file, giao diện
```

## Việc cần làm trước khi phát hành

- Thay huy hiệu chữ cái bằng logo chính thức của từng nền tảng theo hướng dẫn thương hiệu (§7).
- Kiểm tra lại mẫu link tìm kiếm của Zing MP3 và NhacCuaTui trên thiết bị thật (sửa được qua `SEARCH_URL_OVERRIDES`); liên hệ hợp tác để có API (§13).
- Lấy ý kiến pháp lý trước khi mở rộng danh sách trắng tìm kiếm web (§7).
- Đo lại các chỉ tiêu §10 trên bộ thử 200 bài với khóa ACRCloud/AudD thật.
- Dùng công cụ migration (ví dụ Alembic) thay cho `CREATE_TABLES=true` khi lược đồ bắt đầu thay đổi.
- ShazamKit cho Android (GD2, tùy chọn) và iOS (GD3).
