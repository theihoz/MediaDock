# Unified Media Search Design

## Mục tiêu

Tối ưu trang Khám phá bằng một thanh tìm kiếm hợp nhất cho Phim và TV Show. Người dùng có thể tìm theo nhiều tên gọi, người tham gia sản xuất, studio hoặc network; kết quả xuất hiện nhanh khi đang gõ và không làm mất danh sách thịnh hành khi ô tìm kiếm trống.

## Trải nghiệm người dùng

- Một thanh tìm kiếm chung nằm trên hai tab `Phim` và `TV Show`.
- Nhập tối thiểu 2 ký tự sẽ tự tìm sau debounce 400 ms.
- Mỗi lần gõ mới hủy hoặc bỏ qua response của truy vấn cũ để kết quả không nhảy ngược.
- Dropdown hiển thị tối đa 8 gợi ý, gồm poster, tiêu đề, năm, loại nội dung và lý do khớp.
- Enter hoặc `Xem tất cả` mở lưới kết quả đầy đủ.
- Tab `Phim` và `TV Show` lọc kết quả hợp nhất mà không gọi lại API khi dữ liệu còn mới.
- Khi xóa nội dung tìm kiếm, dropdown đóng và tab hiện lại nội dung thịnh hành.
- Lưu tối đa 10 từ khóa gần đây trên máy; người dùng có thể chọn lại hoặc xóa lịch sử.
- Bộ lọc gồm năm, loại nội dung và trạng thái đã có trong thư viện.

## Phạm vi tìm kiếm

Một truy vấn được đối chiếu với:

- Tiêu đề hiển thị, tên gốc, tên quốc tế, tên dịch và alias.
- Tiêu đề không dấu, không phân biệt hoa thường và không phụ thuộc dấu câu.
- Tên diễn viên, đạo diễn và biên kịch.
- Studio, hãng sản xuất và nhà phân phối.
- Network hoặc kênh phát hành của TV Show.

Backend gộp bản trùng theo `mediaType + TMDB ID` hoặc `mediaType + TVDB ID`. Một kết quả có nhiều lý do khớp vẫn chỉ xuất hiện một lần; lý do ưu tiên hiển thị theo thứ tự: tiêu đề/alias, diễn viên hoặc đoàn phim, studio/network.

## Kiến trúc backend

Thêm endpoint:

`GET /v1/discover/search?q=...&type=all|movie|series&year=...&library=all|in|out&limit=...`

Endpoint thực hiện song song:

1. Tìm phim qua Radarr/TMDB metadata.
2. Tìm TV Show qua Sonarr/TVDB metadata.
3. Tìm mở rộng theo người, studio và network qua metadata provider đã cấu hình.

Mỗi nhánh có timeout riêng; lỗi một nhánh không làm hỏng các nhánh còn lại. Response bao gồm:

- `items`: danh sách chuẩn hóa.
- `partial`: có nguồn bị lỗi hoặc timeout.
- `sources`: trạng thái từng nguồn.
- `query`: truy vấn đã chuẩn hóa.

Mỗi item có `mediaType`, ID provider, `title`, `originalTitle`, `aliases`, `year`, `poster`, `overview`, `rating`, `inLibrary`, `matchedBy` và `matchedText`. API không trả credential hoặc raw provider response.

Backend cache truy vấn chuẩn hóa trong 5 phút và gộp request đồng thời cùng khóa. Giới hạn tối đa 50 kết quả đầy đủ và 8 kết quả ở chế độ suggestion. Truy vấn dưới 2 ký tự không gọi provider.

## Flutter

Tách logic tìm kiếm thành controller có trách nhiệm debounce, request generation, cache phiên và bỏ qua response cũ. Widget thanh tìm kiếm chỉ quản lý nhập liệu, dropdown, lịch sử và bộ lọc.

Các trạng thái giao diện:

- `idle`: hiển thị thịnh hành.
- `typing`: giữ kết quả hiện tại trong lúc debounce.
- `loading`: hiển thị progress nhỏ trong thanh tìm kiếm.
- `results`: dropdown hoặc lưới kết quả.
- `partial`: hiển thị kết quả kèm chip `Một số nguồn chưa phản hồi`.
- `empty`: thông báo không tìm thấy và gợi ý thử alias khác.
- `failed`: lỗi gọn, có nút thử lại, không hiện exception thô.

Poster lỗi dùng placeholder. Điều hướng từ gợi ý hoặc card sử dụng đúng trang chi tiết Phim/TV Show hiện có.

## Hiệu năng và độ ổn định

- Debounce 400 ms.
- Không cho request tìm kiếm chồng vô hạn.
- Timeout riêng từng provider, không dùng một timeout tổng làm mất kết quả đã có.
- Cache backend 5 phút và cache phiên Flutter cho thao tác quay lại.
- Chuẩn hóa query bằng trim, lowercase, Unicode normalization và bỏ dấu phục vụ so khớp; vẫn giữ nguyên chuỗi gốc để hiển thị.
- Kết quả từ response cũ không được ghi đè response của query mới.

## Kiểm thử nghiệm thu

- Gõ `Mushoku Tensei`, `Jobless Reincarnation` hoặc alias Nhật trả cùng TV Show.
- Gõ `Benedict Cumberbatch` trả phim và TV Show có diễn viên này, kèm lý do khớp.
- Gõ `Marvel Studios` trả nội dung liên quan studio.
- Gõ tên network trả TV Show phù hợp.
- Phim và TV Show được tìm đồng thời; lỗi Sonarr vẫn giữ kết quả phim và ngược lại.
- Gõ nhanh nhiều ký tự chỉ hiển thị kết quả của query cuối.
- Xóa query quay lại trending ngay.
- Kết quả trùng từ alias/người/studio chỉ xuất hiện một lần.
- Lịch sử giới hạn 10 mục và có thể xóa.
- Flutter tests, analyze, Windows build, backend tests và Compose validation pass.

## Giới hạn

- Không thêm API key metadata mới nếu hệ thống hiện tại chưa có; khả năng tìm người/studio/network dùng metadata provider đã cấu hình và trả trạng thái `partial` khi provider không hỗ trợ.
- Không tìm trực tiếp torrent từ thanh tìm kiếm; release chỉ được tìm khi người dùng mở chi tiết nội dung.
- Không tự động tải release từ kết quả gợi ý.
- Media stack vẫn chỉ khởi động khi người dùng nhấn Start.
