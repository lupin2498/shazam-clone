# Báo cáo kiểm thử và sửa lỗi: Tìm Nhạc

Ngày 2026-11-16. Nhánh `worktree-agent-a2d3bb7479033f934`, mốc ban đầu `a31fae8`. Đợt chạy gồm hai phiên: phiên đầu làm backend (11 commit, `7acf0ae` → `5a2f47f`) thì dừng giữa chừng vì lỗi hạn mức API của model; phiên sau làm mobile (Dart, Kotlin) và gộp nhánh `ccr-f60ecfdd-76t6yr` tới `8fab4d8`.

## 1. Kết quả

| Bộ test | Mốc `a31fae8` | Cuối đợt | Lệnh |
|---|---|---|---|
| Backend (pytest, SQLite + bộ nhớ, thêm redis-server thật nếu có) | 57 | **140/140** | `cd backend && pytest -q` |
| Flutter (unit + widget) | 28 | **76/76** (14 ca do nhánh chính mang vào) | `cd mobile && flutter test` |
| `flutter analyze` | sạch | sạch | |
| APK debug | build được | **build được** ở `f20e8a8` | `flock /tmp/android-build.lock flutter build apk --debug` |
| Smoke test HTTP thật (uvicorn + PostgreSQL 16 + Redis, chế độ demo) | chưa có | 9 bước, chạy ở phiên đầu; phiên sau không đổi mã backend nên không chạy lại | `backend/tests/live/smoke.py` |

Không có lần đỏ nào bị bỏ qua, nới ngưỡng hay đánh dấu skip. Test của redis-server tự bỏ qua khi máy không có `redis-server` (máy này có, nên đã chạy).

## 2. Phạm vi và cách kiểm

- **Backend:** hạn mức và hoàn lượt, bảo mật (log, URL, kích thước thân yêu cầu, token admin), dữ liệu engine sai dạng, tranh chấp khi lưu đồng thời, tài nguyên CSDL của luồng SSE. Kiểm bằng pytest, rồi chạy thật với PostgreSQL và Redis vì SQLite không lộ lỗi độ dài VARCHAR, tranh chấp giao dịch và pool kết nối.
- **Mobile Dart:** lớp lỗi "trạng thái kẹt", vòng đời màn hình (await rồi dùng context hoặc setState, rời màn hình giữa chừng), phản hồi máy chủ bất thường (HTML 502, JSON sai dạng, SSE đứt hoặc im), hàng chờ offline, Play Integrity, hợp đồng `requestHash` Dart↔Python, tính năng "Cài đặt → Máy chủ" sau khi gộp. Có quét thêm bằng lint (`cancel_subscriptions`, `close_sinks`, `discarded_futures`, `unawaited_futures`) bật tạm, không commit.
- **Android Kotlin:** đọc lại `MainActivity`, `AudioCapture`, `AacEncoder`, `AudioFileDecoder`, `Helpers`: Result trả đúng một lần, giải phóng MediaCodec/MediaExtractor/MediaPlayer/AudioRecord trên mọi nhánh lỗi, luồng worker.
- Mỗi lỗi có test hồi quy viết trước, chạy đỏ trên mã cũ (với Dart: tạm đưa file lib về HEAD và chạy lại), xanh sau khi sửa. Kotlin chưa có khung test: kiểm bằng build APK và lập luận, cách kiểm trên máy ghi ở mục 5.

## 3. Lỗi đã sửa

| # | Mức độ | Lỗi (người dùng thấy) | Nguyên nhân | Cách sửa | Test hồi quy | Commit |
|---|---|---|---|---|---|---|
| 1 | Nghiêm trọng | Dùng lại một `session_id` thì mọi lượt nhận diện trong 1 giờ đều miễn phí: hạn mức 30 lượt/ngày thành vô hạn lượt gọi engine trả tiền | `consume()` coi mọi yêu cầu sau yêu cầu đầu là mẫu thứ hai của cùng lần chạm | Mỗi session chỉ chia lượt đúng một cặp early→full | `tests/test_quota.py` (7/9 đỏ trước) | `8af445e` |
| 2 | Cao | Khoá YouTube/Jamendo nằm trong URL ghi ra log INFO | Log của httpx in nguyên URL | Hạ log httpx, bộ lọc che `key=`, `client_id=`... | `test_api_keys_never_reach_the_logs` | `97726d7` |
| 3 | Cao | Link "Mua và tải" có thể là `javascript:`/`intent:` lấy từ dữ liệu ngoài | Không lọc scheme; ghép ID engine vào URL không kiểm | Chỉ http(s) tuyệt đối có host; kiểm ID trước khi ghép | `test_security.py` | `34472d0` |
| 4 | Cao | Tải lên không giới hạn kích thước (làm đầy bộ nhớ máy chủ); mẫu âm thanh bị ghi ra đĩa, trái cam kết riêng tư | Không có giới hạn thân yêu cầu; ngưỡng ghi đĩa mặc định của trình phân tích multipart | Middleware trả 413 sớm; giữ mẫu trong bộ nhớ | `test_security.py` | `5a2f47f` |
| 5 | Cao | Mỗi luồng link giữ 2 kết nối CSDL suốt lúc chờ adapter; app rời màn hình giữa chừng thì kết nối bị huỷ kèm ERROR (đo: 27 lỗi sau 45 lần ngắt, PostgreSQL) → nguy cơ cạn pool | Mở phiên CSDL rồi mới chờ adapter | Chỉ mở phiên cho từng bước đọc/ghi ngắn, chạy trong `asyncio.shield` | `test_link_stream_resources.py` | `14e768e` |
| 6 | Cao | Màn hình nghe hoặc Kết quả quay mãi: proxy trả HTML 502, kết nối SSE chết hoặc im, mã hoá lỗi khi dừng thu, micro mở lỗi, ghi lịch sử lỗi, "matched" không có ứng viên làm app sập | `_decode` gọi jsonDecode trên mọi phản hồi; SSE không có giới hạn im lặng hay kiểm `done`; các nhánh lỗi của ListenSession không tới `_finish` | ApiClient chỉ ném ApiException; `stallGuard` 20 s trên luồng byte; thiếu `done` → lỗi mạng nhưng giữ link đã nhận; mọi nhánh lỗi kết thúc phiên | `robustness_test.dart` (13/15 đỏ trước) | `dda50f8` |
| 7 | Cao (khi bật `INTEGRITY_MODE=enforce`) | Chuẩn bị Play Integrity lỗi một lần (mất mạng lúc mở app) hoặc provider hết hạn → không gửi token nữa cho tới khi tắt hẳn app, mọi yêu cầu bị từ chối | Ghi nhớ số project trước khi biết kết quả, không bao giờ thử lại | Thử lại sau tối đa 1 lần/phút; token lỗi → chuẩn bị lại một lần rồi xin lại | `contract_test.dart` nhóm Play Integrity (3/4 đỏ trước) | `7061b85` |
| 8 | Trung bình | Hết lượt khi engine sập: API trả 503 nhưng vẫn trừ lượt | Không có đường hoàn lượt | Hoàn lượt (giới hạn theo ngày) khi cascade lỗi | `test_quota.py` | `8af445e` |
| 9 | Trung bình | Hai lượt nhận diện cùng bài mới gần như cùng lúc → 500 (vỡ UNIQUE); 8 thiết bị cùng bản ghi → nhiều hàng track | Kiểm-rồi-chèn không khoá | `INSERT … ON CONFLICT DO NOTHING` rồi đọc lại; khoá tư vấn `pg_advisory_xact_lock` theo ISRC/match_key; chuẩn hoá ISRC | `test_storage_races.py`, bước đồng thời của smoke | `b24b30e`, `ab2746e` |
| 10 | Trung bình | Engine trả JSON khác dạng → 500; điểm 1/100 đọc thành độ tin cậy 100%; "Tyler, The Creator" bị tách đôi | Giả định dạng phản hồi, nhầm thang điểm | Đọc phòng thủ, đúng thang, danh sách tên ngoại lệ | `test_engine_answers.py` | `d613221` |
| 11 | Trung bình | Đổi máy chủ hai lần liên tiếp: cấu hình (cả số project Play Integrity) của máy chủ cũ trả lời muộn đè lên máy chủ mới, kể cả bản lưu đệm | `refresh()` nhận mọi câu trả lời | Bỏ câu trả lời của địa chỉ không còn dùng | `contract_test.dart` (đỏ trước) | `823056f` |
| 12 | Trung bình | Hàng chờ offline: một mẫu bị từ chối vĩnh viễn (413/422) chặn mọi mẫu sau nó mãi; lưu lịch sử lỗi sau khi nhận diện → mất kết quả, không thông báo | Mọi lỗi khác `invalid_sample` đều "giữ rồi dừng"; `_report` không bắt lỗi lưu | Phân loại lỗi vĩnh viễn/tạm thời; vẫn báo tên bài khi không lưu được | `pending_queue_test.dart` (3/5 đỏ trước) | `a56a995` |
| 13 | Trung bình | Bấm "Nghe thử" rồi Back ngay: nhạc vẫn phát tới hết sau khi màn hình đóng; previewStop lỗi → nút kẹt "Dừng" và "Nhận diện đoạn này" không làm gì | dispose chỉ dừng khi `_playing` đã bật; không bắt lỗi kênh; setState sau await | Dừng nếu previewPlay trả lời muộn; bắt lỗi; kiểm `mounted` | `trim_lifecycle_test.dart` (3/3 đỏ trước) | `58bf126` |
| 14 | Trung bình | Rò MediaExtractor (giữ file descriptor) mỗi lần đọc tệp mà máy không có bộ giải mã (DTS, AC-4...) hoặc tệp không mở được; rò MediaPlayer khi "Nghe thử" URI hỏng | Tạo codec nằm ngoài try/finally; `open()` không release khi `setDataSource` lỗi | Release trên mọi nhánh lỗi; lỗi vẫn ném lên như cũ | Không có khung test Kotlin; build APK; cách kiểm ở mục 5 | `5aae227` |
| 15 | Thấp | Mẫu WAV cụt → 500; token admin lạ → 500; app gửi phiên bản "1.0" bị trả 426 oan (app lại coi "1.0" = "1.0.0") | Thiếu kiểm đầu vào; so tuple khác độ dài | Kiểm và trả 4xx; đệm 0 cho đủ ba số | `test_bad_input.py` | `2430c18` |
| 16 | Thấp | Tìm lịch sử không khớp chuỗi dạng tổ hợp (NFD: tên file từ iOS/macOS, vài bộ gõ) | Chỉ tra bảng ký tự dựng sẵn | Bỏ dấu tổ hợp U+0300–U+036F | `unit_test.dart` (2 ca đỏ trước) | `7d6c3cc` |
| 17 | Thấp | Nút "OK" của banner "app đã cũ" không làm gì; câu chữ nhắc Google Play dù app chạy cả iOS | onPressed rỗng | Ẩn banner tới lần mở app sau; câu trung tính | `widget_test.dart` (đỏ trước) | `2036754` |
| 18 | Thấp | Tìm lịch sử không ra kết quả thì báo "Chưa có bài nào" như thể mất lịch sử | Một nhánh cho mọi danh sách rỗng | Dòng "Không có bài nào khớp với tìm kiếm." | `widget_test.dart` (đỏ trước) | `0707089` |
| 19 | Hạ tầng test | `pytest -q` không chạy được như CI | Thiếu `pythonpath = .` | `pytest.ini` | Job CI | `7acf0ae` |
| 20 | Hạ tầng test | Test `requestHash` của Dart so công thức Dart với chính nó, không bắt được lệch giữa hai phía | Test lặp lại logic | Véc-tơ cố định tính bằng Python, đọc hash trong header thật mà ApiClient gửi; cùng hằng số ở backend | `contract_test.dart`, `test_integrity_vectors.py` | `86fb2a3` |

Rà mà không thấy lỗi: thứ tự trường `requestHash` khớp ở cả ba chỗ gọi (nhận diện, tìm kiếm, báo cáo link), hai phía băm chuỗi nguyên văn UTF-8, không chuẩn hoá Unicode. `ServerAddress.parse/isAllowed`: các trường hợp lạ (IPv6 ánh xạ IPv4, `127.1`, tên miền bắt đầu bằng `fc`) đều nghiêng về bắt buộc https. Lỗi `server_address` không bị coi là lỗi mạng (đã thêm test ở mức phiên nghe, `f20e8a8`). `MethodChannel.Result` trong `MainActivity.kt` trả đúng một lần trên mọi nhánh, kể cả khi xin quyền lần hai trong lúc lần đầu chưa trả lời.

## 4. Lỗi tìm thấy nhưng chưa sửa

| Mức độ | Vấn đề | Vì sao chưa sửa |
|---|---|---|
| Cao (khi bật enforce) | iOS trả `false` cho `integrityPrepare` (chưa có App Attest), nên không bao giờ gửi token. Bật `INTEGRITY_MODE=enforce` thì mọi yêu cầu từ iOS bị từ chối với câu "Hãy cài app từ Google Play" (`backend/app/deps.py:50`) | Cần quyết định thiết kế (App Attest/DeviceCheck, hoặc backend miễn kiểm theo nền tảng); `mobile/ios/` ngoài phạm vi |
| Trung bình (chưa đo) | Timeout của app là 25 s; backend trường hợp xấu nhất chạy hai engine × 10 s + ảnh bìa 1,5 s + tải lên mạng di động. Vượt 25 s thì app lưu mẫu offline rồi gửi lại, tốn thêm lượt | Không có khoá engine thật để đo |
| Thấp | Mẫu offline gửi lại bằng `session_id` mới: một lần chạm có thể tốn 2 lượt (mẫu 6 s đã tính + mẫu đầy đủ gửi lại) | Đúng thiết kế đã ghi trong `8af445e`; cần quyết định sản phẩm |
| Thấp | Activity bị huỷ khi đang mở trình chọn file ("Không giữ hoạt động", máy ít RAM): tệp đã chọn bị bỏ qua | Giới hạn của FlutterActivity tạo engine theo từng activity |
| Thấp | `AudioCapture.stop()` có thể chặn luồng chính tới 1 s khi `cancelRecording` chạy lúc worker đang dừng thu | Chỉ giật hình, không treo; sửa cần đổi mô hình khoá |
| Thấp | `ResultScreen._persist()` lỗi lưu → lỗi bất đồng bộ không ai bắt (không ảnh hưởng người dùng) | Ưu tiên thấp |

## 5. Chưa kiểm chứng ở môi trường này

- **Kotlin (`5aae227`):** chỉ biên dịch. Kiểm trên máy: chọn nhiều lần một tệp `.dts`/`.ac4`, rồi `adb shell ls /proc/$(adb shell pidof vn.timnhac.app)/fd | wc -l` không được tăng dần. Nên chạy lại `integration_test/native_bridge_test.dart` trên CI (hợp đồng kênh không đổi).
- **iOS:** không build được ở đây (không có macOS).
- **Engine và adapter thật** (ACRCloud, AudD, Spotify, YouTube...): mạng chỉ ra được registry gói, chỉ kiểm bằng mock.
- **Play Integrity thật:** hết hạn provider, mã lỗi thật; chỉ kiểm bằng FakeNative.
- **Trên máy thật:** nghe thử với tệp lớn hoặc tệp trên Drive, thông báo của hàng chờ offline, quyền micro bị thu hồi giữa chừng, hiệu năng.

## 6. Chỗ Dart còn giả định Android

1. `PlatformInfo.androidPackage` là khoá duy nhất cho "app đã cài" (`AppServices.refreshInstalledApps`) và cho danh sách "Nền tảng ưu tiên" (`settings_screen.dart` lọc `p.androidPackage != null`): nền tảng không có gói Android (iTunes Store) không bao giờ chọn được trên iOS; nền tảng mới từ `/v1/config` mà Swift chưa có bảng ánh xạ gói → URL scheme thì không bao giờ được coi là đã cài.
2. `NativeBridge.openUrl(url, androidPackage:)`: tham số mang tên Android; iOS phải tự ánh xạ.
3. `IntegrityService` chỉ có Play Integrity (xem mục 4). Sau `7061b85`, iOS tốn tối đa một lời gọi kênh mỗi phút để thử lại.
4. Thông điệp lỗi do backend gửi về hiện nguyên văn trong app: "Hãy cài app từ Google Play" (403 `integrity_failed`).
5. Chú thích tài liệu: `native_bridge.dart` ("Everything the app needs from Android", `PickedFile.uri` là `content://`; trên iOS là file URL), `config.dart` (`flutter build apk`). Dart coi URI là chuỗi mờ nên không sai hành vi.
6. `AppConfig.defaults` chỉ có `androidPackage`, không có thông tin iOS.

## 7. Giả định đã dùng

- Lỗi `413`/`422` của `/v1/recognitions` là vĩnh viễn với mẫu đó (gửi lại cũng vậy), nên hàng chờ xoá mẫu và đi tiếp.
- Banner "app đã cũ" chỉ ẩn trong phiên chạy hiện tại; mở lại app thì hiện lại.
- Giới hạn im lặng của luồng link là 20 s (backend giới hạn mỗi adapter vài giây).

## 8. Nhánh và commit

Nhánh `worktree-agent-a2d3bb7479033f934`, chưa đẩy lên remote. Commit theo thứ tự: backend `7acf0ae` … `5a2f47f` (phiên đầu); mobile `dda50f8`; gộp `0bdb170` (nhánh chính tới `8fab4d8`); `7d6c3cc`, `2036754`, `86fb2a3`, `7061b85`, `58bf126`, `5aae227`, `a56a995`, `0707089`, `823056f`, `f20e8a8`; báo cáo và sổ tay ở commit cuối.

File test mới: `backend/tests/test_quota.py`, `test_cache.py`, `test_security.py`, `test_bad_input.py`, `test_engine_answers.py`, `test_storage_races.py`, `test_link_stream_resources.py`, `test_integrity_vectors.py`, `tests/live/smoke.py`; `mobile/test/robustness_test.dart`, `contract_test.dart`, `pending_queue_test.dart`, `trim_lifecycle_test.dart`.
