# Thiết kế nguồn Nyaa hybrid

## Mục tiêu

Bổ sung Nyaa cho cả phim và TV Show mà không để Cloudflare hoặc một mirror lỗi làm chậm toàn bộ tìm kiếm. Hệ thống chỉ hiển thị những nguồn thực sự trả về release phù hợp và tiếp tục giữ kín magnet, API key và download token.

## Kiến trúc nguồn

- `Nyaa.si` là nguồn Nyaa chính và được truy cập qua FlareSolverr đã có trong media stack.
- `Nyaa.land` là mirror dự phòng. Kiểm tra runtime ngày 2026-08-13 xác nhận mirror cũng bật Cloudflare, vì vậy nó dùng FlareSolverr nhưng vẫn là indexer và endpoint độc lập.
- Hai endpoint Nyaa được cấu hình thành hai indexer riêng, cùng tag `nyaa-anime` và được đồng bộ sang cả Radarr lẫn Sonarr.
- YTS, EZTV, Internet Archive và Tokyo Toshokan tiếp tục hoạt động độc lập.
- Tìm release gọi tất cả nguồn được bật đồng thời. Mỗi nhánh có timeout riêng; một nguồn lỗi không hủy kết quả của nguồn khác.

## Bootstrap Prowlarr

Bootstrap idempotent sẽ:

1. Tạo hoặc cập nhật FlareSolverr indexer proxy tại `http://flaresolverr:8191`.
2. Tạo hoặc cập nhật `Nyaa.si` với base URL chính thức và gắn proxy FlareSolverr.
3. Tạo hoặc cập nhật `Nyaa.land` bằng cùng schema Nyaa, thay base URL bằng mirror và gắn proxy FlareSolverr do kiểm tra runtime xác nhận Cloudflare Protection.
4. Bật phạm vi movie và series, gắn tag `nyaa-anime`, đồng bộ Radarr/Sonarr và không tạo bản trùng khi bootstrap chạy lại.
5. Nếu schema Prowlarr không cho thay base URL hoặc mirror không tương thích, giữ indexer ở trạng thái `needs_manual_configuration` thay vì làm bootstrap thất bại.

Không tự giải CAPTCHA, không lưu cookie trình duyệt cá nhân và không dùng dịch vụ anti-captcha trả phí.

## Tìm kiếm và chuẩn hóa release

- Movie và TV Show tiếp tục dùng bộ tổng hợp release hiện tại.
- Nyaa được truy vấn song song với các nguồn hiện có.
- Timeout riêng:
  - `Nyaa.si`: 12 giây do có FlareSolverr.
  - `Nyaa.land`: 8 giây.
- Bộ lọc title hỗ trợ tên gốc, tên thay thế và dạng romanized; TV Show vẫn bắt buộc đúng season hoặc episode.
- Release sai loại, sai season/tập hoặc thiếu `guid/indexerId` bị loại bỏ.
- Kết quả trùng được gộp ưu tiên theo info-hash; nếu thiếu hash thì dùng tên chuẩn hóa, dung lượng và scope.
- Response giữ contract download token kín. Flutter không nhận magnet hoặc credential.
- Nhãn nguồn là `Nyaa.si` hoặc `Nyaa.land`; UI chỉ tạo chip cho nguồn có ít nhất một release hợp lệ.

## Trạng thái và lỗi

Trang Services hiển thị riêng hai nguồn:

- `ready`: indexer kiểm tra thành công.
- `cloudflare_blocked`: Nyaa.si gặp challenge/CAPTCHA mà FlareSolverr không xử lý được.
- `degraded`: timeout hoặc lỗi tạm thời.
- `needs_manual_configuration`: schema/mirror cần thiết lập thủ công.
- `disabled`: người dùng đã tắt nguồn.

Lỗi Nyaa không được biến thành lỗi toàn bộ request nếu còn nguồn khác thành công. Nếu mọi nguồn đều lỗi, backend trả lỗi tổng hợp có hướng dẫn, không đưa HTML Cloudflare hoặc thông tin nội bộ lên Flutter.

## Giao diện

- Services/Nguồn tải có hai card Nyaa với endpoint, phạm vi, trạng thái và lần kiểm tra gần nhất.
- Danh sách release nhóm theo nguồn có kết quả và hiển thị chip `Nyaa.si` hoặc `Nyaa.land`.
- Không thêm nút nguồn mới ở màn hình chi tiết; người dùng vẫn chọn release cụ thể như hiện tại.
- Có thể tắt từng indexer trong Prowlarr mà không ảnh hưởng nguồn còn lại.

## Kiểm thử

- Bootstrap nhiều lần chỉ tạo một FlareSolverr proxy, một Nyaa.si và một Nyaa.land.
- Nyaa.si dùng proxy; Nyaa.land dùng URL mirror đúng cấu hình.
- Movie và TV Show gọi Nyaa đồng thời với các nguồn hiện tại.
- Nyaa.si timeout/Cloudflare nhưng Nyaa.land hoặc nguồn khác thành công thì request vẫn trả kết quả đúng hạn.
- Hai Nyaa trả cùng torrent thì UI chỉ thấy một release.
- TV release sai season/tập bị loại.
- Services phân biệt `cloudflare_blocked`, `degraded` và `ready` mà không lộ credential.
- Backend/controller tests, Flutter tests/analyze/build Windows, Compose validation và runtime search qua ứng dụng đều đạt.

## Mặc định và giới hạn

- Nyaa bật mặc định cho cả movie và series, ưu tiên anime nhưng không tự tải.
- Chỉ tải nội dung người dùng có quyền sử dụng.
- Cloudflare có thể thay đổi bất kỳ lúc nào; mirror là fallback bắt buộc để giữ trải nghiệm ổn định.
- Media stack vẫn chỉ khởi động khi người dùng nhấn Start.
