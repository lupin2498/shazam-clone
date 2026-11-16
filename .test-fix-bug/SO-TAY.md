# Sổ tay kiểm thử: shazam-clone (Tìm Nhạc)
<!-- Agent test-fix-bug tự cập nhật sau mỗi lần chạy. -->

## Lệnh và môi trường
- backend test: `cd backend && /opt/venv-backend/bin/python -m pytest -q` (hoặc `pytest -q`; cần `pythonpath = .` trong `pytest.ini`). ~9 s, 140 ca (redis-server có sẵn thì chạy cả hợp đồng Cache trên Redis thật).
- backend chạy thật: PostgreSQL 16 ở `/usr/lib/postgresql/16/bin` (initdb bằng `runuser -u postgres`, thư mục dữ liệu dưới `/var/tmp`), `redis-server`, rồi
  `DATABASE_URL=postgresql+asyncpg://postgres@127.0.0.1:<cổng>/timnhac REDIS_URL=redis://127.0.0.1:<cổng>/0 DEMO_MODE=true ADMIN_TOKEN=<t> QUOTA_PER_DEVICE_PER_DAY=5 SEARCH_PER_DEVICE_PER_DAY=3 uvicorn app.main:app --port <cổng>`
  và `python tests/live/smoke.py --base-url http://127.0.0.1:<cổng> --admin-token <t>` (9 bước, có `--only`).
- mobile: `export PATH=/opt/flutter-sdk/flutter/bin:$PATH; cd mobile && flutter pub get && flutter analyze && flutter test` (~12 s, 76 ca).
- APK debug: `export ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk; flock /tmp/android-build.lock flutter build apk --debug` (~115 s khi đổi Kotlin, ~11 s khi cache ấm; `build/` ~2,3 GB: xoá khi xong).
- CI: `.github/workflows/` do phiên chính quản lý (backend, mobile analyze + test + APK/IPA, test kênh native trên emulator/simulator). Phiên kiểm thử không đụng workflow, không đẩy lên remote.

## Bẫy của dự án
- [2026-11-16] Công cụ Bash của phiên worktree từ chối lệnh "quá phức tạp" (heredoc ghi file, chuỗi lệnh có git) → ghi file bằng Write/Edit, lời commit viết ra file rồi `git commit -F`, mỗi lệnh git một lần gọi.
- [2026-11-16] Bộ pytest dùng SQLite + MemoryCache: không thấy lỗi của PostgreSQL (VARCHAR, tranh chấp giao dịch, pool khi client ngắt SSE) và của Redis → chạy thêm `tests/live/smoke.py`.
- [2026-11-16] Chế độ demo chỉ có 3 bài mẫu: tranh chấp "lần đầu lưu một bài" chỉ tái hiện trên CSDL trống (TRUNCATE track CASCADE + FLUSHALL), phải lặp vài lần.
- [2026-11-16] FastAPI bọc mọi ngoại lệ lúc đọc thân yêu cầu thành 400: middleware muốn trả 413 phải tự gửi phản hồi.
- [2026-11-16] Mạng chỉ ra registry gói và dl.google.com: adapter/engine chỉ kiểm bằng mock; không nạp được kinh nghiệm chung từ repo khác.
- [2026-11-16] `Stream.timeout` trong chuỗi `async*` (ApiClient.streamLinks) để luồng mở sau "done" dưới fake_async → ResultScreen tải mãi trong widget test. Dùng `stallGuard()` (Timer + StreamController) trên luồng byte (bằng chứng: dda50f8, 2 widget test).
- [2026-11-16] Huỷ stream `async*` khi generator đứng ở `await for` không đóng nguồn → timeout đặt ở luồng byte thô, test khẳng định `body.hasListener == false`.
- [2026-11-16] Dưới fake_async, `await controller.close()` của StreamController đã bị huỷ có thể treo cả lượt test (300 s) → không await close trong testWidgets; chạy `flutter test` qua `timeout` và ghi ra file thay vì pipe vào grep (pipe giữ đầu ra tới khi xong).
- [2026-11-16] `trackJson()` trong fakes có album "Nơi Này Có Anh": test tìm theo tiêu đề phải bỏ album và nghệ sĩ, nếu không sẽ xanh nhầm (7d6c3cc).
- [2026-11-16] Kiểm "đỏ trước khi sửa" không dùng git stash (dùng chung giữa các worktree): chép file lib đã sửa ra scratchpad, `git checkout HEAD -- <file>`, chạy test, chép lại. Test mới gọi tham số mới thì thêm tạm tham số bỏ qua vào bản cũ.
- [2026-11-16] `use_build_context_synchronously` đã bật sẵn (flutter_lints 6). Quét thêm: bật tạm `discarded_futures`, `cancel_subscriptions`, `close_sinks` trong analysis_options rồi `git checkout` lại.
- [2026-11-16] FakeNative có điểm tiêm lỗi (`startError`, `stopError`, `cancelError`, `openError`, `previewStopError`, `integrityTokenFailures`) và cổng chờ (`micPermissionGate`, `probeGate`, `previewGate`).

## Bản đồ phủ
- Backend: hạn mức/hoàn lượt (`test_quota`, `test_cache`), bảo mật (`test_security`), đầu vào xấu, dạng trả lời engine, tranh chấp lưu, tài nguyên luồng link, véc-tơ requestHash; smoke HTTP thật 9 bước. Thiếu: engine/adapter thật.
- Mobile: ApiClient với phản hồi bất thường và SSE (`robustness_test`), ListenSession mọi nhánh lỗi, hàng chờ offline (`pending_queue_test`), Play Integrity và chạy đua cấu hình (`contract_test`), màn hình cắt file (`trim_lifecycle_test`), trang chủ/kết quả/lịch sử (`widget_test`), "Máy chủ" (`server_address_test`). Thiếu: ScanScreen, SearchScreen, màn hình kết quả nhận diện (outcome), test Kotlin (không có khung; chỉ `integration_test/native_bridge_test.dart` chạy trên CI).
- iOS: chưa kiểm ở đây (không có macOS).

## Việc còn treo
- [ ] iOS không có token toàn vẹn: quyết định App Attest hoặc miễn kiểm theo nền tảng trước khi bật `INTEGRITY_MODE=enforce`; câu "Hãy cài app từ Google Play" ở `backend/app/deps.py`.
- [ ] Đo thời gian backend với engine thật so với timeout 25 s của app (vượt → mẫu vào hàng chờ, gửi lại, tốn thêm lượt).
- [ ] Kiểm rò file descriptor trên máy thật sau `5aae227` (lệnh trong lời commit).
- [ ] Test vòng đời cho ScanScreen, SearchScreen.
- [ ] Chạy lại smoke test HTTP khi đổi mã backend.

## Ghi nhanh

## Nhật ký
- 2026-11-16 | nhánh worktree-agent-a2d3bb7479033f934 | backend | pytest 57 → 136 | 9 commit sửa lỗi (1 nghiêm trọng, 4 cao) + hạ tầng test + smoke | dừng giữa chừng vì hạn mức API của model
- 2026-11-16 | cùng nhánh, gộp ccr-f60ecfdd-76t6yr tới 8fab4d8 | mobile Dart + Kotlin | flutter 28 → 76, pytest 140 | sửa 9 lỗi (2 cao) + 1 hạ tầng test | 1 lần xanh nhầm do bài test (fixture album), 1 lần treo do fake_async | ~40 phút
