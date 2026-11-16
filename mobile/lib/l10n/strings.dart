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

  // Notifications
  static String notifyMatched(String title, String artist) => '$title — $artist';
  static const notifyMatchedTitle = 'Đã nhận diện bài hát';
  static const notifyNoMatchTitle = 'Không nhận ra bài hát';
  static const notifyNoMatchBody = 'Mẫu đã lưu khi mất mạng không khớp bài nào.';
}
