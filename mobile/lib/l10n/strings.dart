/// User-facing text (Vietnamese). Kept in one place to make a later i18n pass easy.
abstract final class S {
  static const appName = 'Tìm Nhạc';

  // Home
  static const tapToListen = 'Chạm để nhận diện';
  static const tapToHum = 'Chạm rồi ngân nga hoặc huýt sáo';
  static const modeListen = 'Nghe';
  static const modeHum = 'Ngân nga';
  static const pickFile = 'Chọn file';
  static const recent = 'Gần đây';
  static const seeAll = 'Xem tất cả';
  static const history = 'Lịch sử';
  static const settings = 'Cài đặt';
  static const searchByName = 'Tìm theo tên';
  static String pendingChip(int n) => '$n mẫu đang chờ mạng';

  // Permission
  static const micTitle = 'Cho phép dùng micro';
  static const micRationale =
      'Tìm Nhạc cần micro để nghe đoạn nhạc đang phát quanh bạn trong khoảng 12 giây. '
      'App chỉ thu khi bạn bấm nghe và không lưu bản ghi sau khi nhận diện xong.';
  static const micDenied = 'Chưa có quyền micro. Bạn vẫn có thể chọn file ghi âm để nhận diện.';
  static const openSettings = 'Mở cài đặt';
  static const allow = 'Cho phép';
  static const notNow = 'Để sau';
  static const micBusy = 'Không mở được micro (có thể app khác đang dùng). Hãy thử lại.';

  // Listening
  static const listening = 'Đang nghe…';
  static const listeningHum = 'Đang nghe bạn ngân nga…';
  static const searching = 'Đang tìm bài hát…';
  static const cancel = 'Hủy';
  static const holdNear = 'Đưa điện thoại lại gần nguồn phát';

  // Outcomes
  static const silent = 'Không nghe thấy âm thanh';
  static const silentHint = 'Mẫu gần như im lặng nên chưa gửi đi. Hãy lại gần nguồn phát hoặc tăng âm lượng.';
  static const noMatch = 'Không tìm thấy bài hát';
  static const noMatchHint = 'Có thể bài chưa có trong kho, hoặc tiếng ồn quá lớn.';
  static const tipCloser = 'Thử lại gần nguồn phát hơn';
  static const tipHum = 'Thử chế độ ngân nga';
  static const tipSearch = 'Gõ tên bài để tìm link';
  static const tryAgain = 'Thử lại';
  static const savedOffline = 'Đã lưu mẫu';
  static const savedOfflineHint = 'Bạn đang mất mạng. App sẽ nhận diện khi có mạng và gửi thông báo khi xong.';
  static const networkError = 'Không kết nối được máy chủ. Kiểm tra mạng rồi thử lại.';
  static const genericError = 'Đã có lỗi xảy ra. Vui lòng thử lại.';
  static const serverBusy = 'Máy chủ đang bận. Vui lòng thử lại sau.';
  static const appOutdated = 'Phiên bản app đã cũ, vui lòng cập nhật lên bản mới nhất.';
  static const ok = 'OK';
  static const candidatesTitle = 'Có thể là một trong các bài sau';
  static const candidatesHint = 'Chọn bài đúng để xem link.';
  static String confidence(double c) => 'Độ tin cậy ${(c * 100).round()}%';

  // Result
  static const listenGroup = 'Nghe';
  static const getGroup = 'Tải/Mua';
  static const findingLinks = 'Đang tìm link trên các nền tảng…';
  static const noListenLinks = 'Chưa tìm được link nghe.';
  static const noFreeDownload =
      'Không có bản tải miễn phí hợp pháp cho bài này. Bạn có thể mua hoặc tải offline trong app chính chủ.';
  static const noGetLinks = 'Chưa tìm được nguồn mua hoặc tải hợp pháp cho bài này.';
  static const exact = 'Chính xác';
  static String searchOn(String platform) => 'Tìm trên $platform';
  static const buyAndDownload = 'Mua và tải';
  static const freeByArtist = 'Tải miễn phí — nghệ sĩ cho phép';
  static String creativeCommons(String license) => 'Tải — $license';
  static const freeDownload = 'Tải miễn phí';
  static const openAppOffline = 'Mở app để tải offline';
  static const instrumental = 'Không lời';
  static const maybeBeat = 'Có thể là bản beat';
  static const coverOf = 'Có thể là bản cover/hòa tấu của bài này';
  static const melodyMatch = 'Khớp theo giai điệu';
  static String work(String title) => 'Tác phẩm: $title';
  static const share = 'Chia sẻ';
  static const reportWrong = 'Báo sai';
  static const reportWrongTitle = 'Kết quả nhận diện sai?';
  static const reportWrongBody = 'Cảm ơn bạn! Báo cáo giúp cải thiện độ chính xác.';
  static const reportLink = 'Báo cáo link';
  static const reportSent = 'Đã gửi báo cáo';
  static const linkHidden = 'Đã ẩn link này';
  static const cannotOpen = 'Không mở được link';
  static const refresh = 'Tải lại link';
  static const beatLinks = 'Tìm thêm bản beat/karaoke';

  // Trim
  static const trimTitle = 'Chọn đoạn nhạc';
  static const trimHint = 'Kéo khung để chọn 10–15 giây có nhạc rõ nhất.';
  static const preview = 'Nghe thử';
  static const stop = 'Dừng';
  static const recognizeSegment = 'Nhận diện đoạn này';
  static const scanWholeFile = 'Quét cả file';
  static const loadingFile = 'Đang đọc file…';
  static const fileError = 'Không đọc được âm thanh trong file này.';
  static const scanning = 'Đang quét cả file…';
  static String scanProgress(int done, int total) => 'Đã quét $done/$total đoạn';
  static const scanEmpty = 'Không nhận ra bài nào trong file.';
  static const scanResults = 'Các bài trong file';

  // Search
  static const searchHint = 'Tên bài hát, nghệ sĩ…';
  static const searchEmpty = 'Không có kết quả.';

  // History
  static const historyEmpty = 'Chưa có bài nào. Chạm nút nghe để bắt đầu.';
  static const historySearch = 'Tìm trong lịch sử';
  static const historyNoMatch = 'Không có bài nào khớp với tìm kiếm.';
  static const today = 'Hôm nay';
  static const yesterday = 'Hôm qua';
  static const pendingSection = 'Đang chờ mạng';
  static const pendingItem = 'Mẫu ghi âm sẽ được nhận diện khi có mạng';
  static const deleted = 'Đã xóa';
  static const undo = 'Hoàn tác';

  // Settings
  static const preferredPlatforms = 'Nền tảng ưu tiên';
  static const preferredHint = 'Link của các nền tảng này luôn xếp đầu danh sách Nghe. Kéo để đổi thứ tự.';
  static const otherPlatforms = 'Thêm nền tảng';
  static const country = 'Quốc gia';
  static const countryHint = 'Dùng để tìm link đúng kho nhạc của quốc gia.';
  static const clearData = 'Xóa dữ liệu';
  static const clearDataHint = 'Xóa lịch sử, mẫu đang chờ và mã thiết bị ẩn danh.';
  static const clearDataConfirm = 'Xóa toàn bộ dữ liệu trên máy?';
  static const clear = 'Xóa';
  static const privacy = 'Chính sách riêng tư';
  static const about = 'Thông tin';
  static String quota(int n) => 'Tối đa $n lượt nhận diện mỗi ngày';
  static const server = 'Máy chủ';
  static const serverUnset = 'Chưa đặt địa chỉ';
  static String serverDefault(String url) => '$url (mặc định)';
  static const serverHint =
      'Địa chỉ backend của Tìm Nhạc, ví dụ https://api.example.com. '
      'Máy chủ trong mạng nội bộ có thể dùng http://, ví dụ http://192.168.1.10:8000.';
  static const serverUseDefault = 'Mặc định';
  static const save = 'Lưu';
  static const serverConnected = 'Đã kết nối máy chủ';
  static const serverSavedOffline = 'Đã lưu địa chỉ, nhưng chưa kết nối được máy chủ';
  static const serverNotAllowed = 'Chưa có địa chỉ máy chủ hợp lệ. Vào Cài đặt → Máy chủ để nhập.';

  // Notifications
  static String notifyMatched(String title, String artist) => '$title — $artist';
  static const notifyMatchedTitle = 'Đã nhận diện bài hát';
  static const notifyNoMatchTitle = 'Không nhận ra bài hát';
  static const notifyNoMatchBody = 'Mẫu đã lưu khi mất mạng không khớp bài nào.';

  // Music playing in other apps (Android 10+, Quick Settings tile)
  static const bgNoMatchBody = 'Nhạc đang phát trên máy không khớp bài nào.';
  static const bgSilentTitle = 'Không thu được âm thanh';
  static const bgSilentBody =
      'Không có nhạc đang phát, hoặc app đang phát chặn việc thu âm thanh. Hãy thử nghe qua micro.';
  static const bgFailedTitle = 'Chưa nhận diện được';
  static const playbackSection = 'Nhạc đang phát trên máy';
  static const playbackHint =
      'Nhận diện nhạc trong video hay app khác mà không phải rời app đó: kéo thanh thông báo xuống '
      'và chạm ô "Tìm Nhạc" trong Cài đặt nhanh. Kết quả hiện bằng thông báo. '
      'Một số app chặn việc thu âm thanh của chúng.';
  static const playbackAddTile = 'Thêm ô vào Cài đặt nhanh';
  static const playbackAddTileManual =
      'Kéo thanh thông báo xuống hết cỡ, chạm biểu tượng bút chì rồi kéo ô "Tìm Nhạc" vào.';
  static const playbackTileAdded = 'Đã thêm ô "Tìm Nhạc" vào Cài đặt nhanh';
  static const playbackTileExists = 'Ô "Tìm Nhạc" đã có trong Cài đặt nhanh';
  static const playbackListenNow = 'Nghe ngay nhạc đang phát nền';
  static const playbackListenNowHint = 'Cho nhạc phát trong app khác (chạy nền) rồi chạm vào đây.';

  // Google Drive sync
  static const syncSection = 'Đồng bộ Google Drive';
  static const syncSignIn = 'Đăng nhập Google';
  static const syncSignInHint =
      'Lưu lịch sử và cài đặt (gồm địa chỉ máy chủ) vào thư mục riêng của Tìm Nhạc trên Google Drive '
      'của bạn. Cài lại app hay dùng máy khác sẽ tự khôi phục.';
  static const syncNotConfigured = 'Bản cài này chưa được cấu hình đăng nhập Google.';
  static const syncNow = 'Đồng bộ ngay';
  static const syncing = 'Đang đồng bộ…';
  static const syncNever = 'Chưa đồng bộ lần nào';
  static String syncedAt(String when) => 'Đã đồng bộ $when';
  static const syncNeedsSignIn = 'Phiên đăng nhập đã hết hạn. Chạm để đăng nhập lại.';
  static const syncOffline = 'Chưa đồng bộ được: không có mạng.';
  static const syncDriveFull = 'Google Drive đã đầy, không lưu thêm được.';
  static const syncFailed = 'Chưa đồng bộ được, app sẽ thử lại sau.';
  static const syncNoDriveAccess =
      'Chưa cho phép Tìm Nhạc dùng Google Drive. Chạm để đăng nhập lại và đánh dấu quyền Drive.';
  static const syncNewerFormat = 'Dữ liệu trên Drive do bản app mới hơn tạo. Hãy cập nhật app.';
  static const syncDeleteRemoteFailed =
      'Đã đăng xuất, nhưng chưa xóa được bản sao trên Google Drive (không có mạng).';
  static const serverSynced = 'đồng bộ qua Google Drive';
  static const syncSignInFailed = 'Không đăng nhập được Google. Thử lại sau.';
  static const syncSignInNotConfigured =
      'Google chưa nhận ứng dụng này (thiếu cấu hình OAuth). Xem hướng dẫn trong README.';
  static const syncSignOut = 'Đăng xuất';
  static const syncSignOutTitle = 'Đăng xuất Google?';
  static const syncSignOutBody = 'Lịch sử và cài đặt vẫn ở trên máy này nhưng không đồng bộ nữa.';
  static const syncDeleteRemote = 'Xóa cả bản sao trên Google Drive';
  static const syncRestored = 'Đã khôi phục lịch sử và cài đặt từ Google Drive';
  static const clearDataSyncedHint = 'Máy này cũng đăng xuất Google để dữ liệu không tải về lại.';
  static const clearDataEverywhere = 'Xóa cả lịch sử đã đồng bộ trên mọi máy';
}
