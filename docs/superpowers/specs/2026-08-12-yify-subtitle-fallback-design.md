# Thiết kế phụ đề Bazarr với YIFY Direct fallback

## Mục tiêu

Media Control hỗ trợ hai cách tìm phụ đề song song:

1. Bazarr là luồng mặc định và là nơi quản lý trạng thái phụ đề.
2. Backend có adapter YIFY Direct tùy chọn để tìm bổ sung khi người dùng yêu cầu hoặc Bazarr không có kết quả phù hợp.

Tính năng chỉ hoạt động với phim đã tồn tại trong thư viện. Flutter không kết nối trực tiếp đến website phụ đề.

## Phạm vi

- Tự động tìm phụ đề bằng Bazarr theo thứ tự tiếng Việt, sau đó tiếng Anh.
- Tìm thủ công và chọn một kết quả cụ thể từ Bazarr.
- Tùy chọn tìm trực tiếp YIFY từ backend.
- Lọc kết quả theo ngôn ngữ và provider.
- Tải, xóa, tìm lại và quét lại phụ đề.
- Lưu phụ đề cạnh video với hậu tố `.vi.srt` hoặc `.en.srt`.
- Yêu cầu Bazarr và Jellyfin quét lại sau khi có thay đổi.

Không bao gồm CAPTCHA bypass, anti-bot trả phí, Whisper, dịch AI hoặc tải phim từ YIFY.

## Kiến trúc

### Bazarr

Bazarr tiếp tục kết nối Radarr và Sonarr, giữ profile `Vietnamese-English`, cutoff tiếng Việt và provider miễn phí `yifysubtitles` cùng `gestdown`. Đây là luồng tự động duy nhất.

### Backend

Backend thêm một giao diện provider chung:

- `BazarrSubtitleProvider`: gọi API Bazarr hiện có.
- `YifyDirectSubtitleProvider`: tìm và tải phụ đề trực tiếp từ YIFY khi được bật.

Adapter YIFY được cô lập. Lỗi hoặc thay đổi website không làm hỏng luồng Bazarr. Backend áp dụng timeout, giới hạn kích thước, xác thực kiểu file và không lưu cookie lâu dài.

YIFY Direct chỉ được gọi khi:

- Người dùng bấm `Tìm trực tiếp YIFY`; hoặc
- Công tắc fallback được bật và tìm kiếm Bazarr không có kết quả đúng ngôn ngữ.

Nếu YIFY không có API công khai ổn định, adapter sử dụng dữ liệu trang công khai trong phạm vi điều khoản cho phép. Khi gặp challenge, CAPTCHA hoặc cấu trúc không nhận diện được, adapter trả `provider_unavailable`; không cố vượt xác minh.

### Flutter

Trang Phụ đề tải danh sách phim từ thư viện và cho chọn phim thay vì yêu cầu nhập Radarr ID. Trang có:

- Ngôn ngữ: Việt hoặc Anh.
- Provider: Tất cả, Bazarr, YIFY Direct, Gestdown.
- Công tắc `Cho phép YIFY Direct fallback`.
- Nút `Tìm qua Bazarr` và `Tìm trực tiếp YIFY`.
- Danh sách kết quả gồm provider, ngôn ngữ, điểm khớp, release, hearing-impaired và định dạng.
- Tác vụ tải, xóa, quét lại và tìm lại.

## Luồng dữ liệu

### Tự động

1. Radarr import phim.
2. Bazarr nhận phim và áp profile Việt–Anh.
3. Bazarr tìm tiếng Việt; nếu không đạt cutoff thì tiếp tục tiếng Anh theo profile.
4. Bazarr lưu file cạnh video.
5. Jellyfin nhận file ở lần scan tiếp theo.

YIFY Direct không chạy nền để tránh phụ thuộc website ngoài Bazarr.

### Thủ công

1. Flutter chọn phim, ngôn ngữ và provider.
2. Backend xác nhận phim có trong Radarr/Bazarr và có đường dẫn thư viện.
3. Backend gọi Bazarr, YIFY Direct hoặc cả hai.
4. Backend chuẩn hóa và loại kết quả trùng.
5. Người dùng chọn đúng một kết quả.
6. Backend tải vào file tạm, kiểm tra định dạng/kích thước, rồi đặt cạnh video.
7. Backend yêu cầu Bazarr scan-disk và Jellyfin refresh.

## API

- `GET /v1/library/subtitle-media`
- `GET /v1/library/{mediaId}/subtitles`
- `GET /v1/library/{mediaId}/subtitles/search?language=vi&provider=all&directFallback=true`
- `GET /v1/library/{mediaId}/subtitles/yify/search?language=vi`
- `POST /v1/library/{mediaId}/subtitles/download`
- `DELETE /v1/library/{mediaId}/subtitles/{subtitleId}`
- `POST /v1/library/{mediaId}/subtitles/refresh`

Kết quả chuẩn hóa gồm `id`, `provider`, `source`, `language`, `release`, `score`, `hearingImpaired`, `format`, `downloadToken`. `downloadToken` có thời hạn ngắn và không chứa URL tùy ý do client cung cấp.

## Xác thực kết quả và tải file

- Chỉ chấp nhận phim có IMDb/TMDB hoặc tiêu đề + năm khớp.
- Ưu tiên release name khớp; hiển thị cảnh báo nếu chỉ khớp phim.
- Chỉ cho phép `.srt`, `.vtt`, `.ass` và archive hợp lệ chứa các định dạng này.
- Giới hạn kích thước tải và chống path traversal khi giải nén.
- Backend tự tạo tên file; Flutter không gửi đường dẫn đích.
- Không ghi API key, cookie hoặc URL tải có token vào log.

## Xử lý lỗi

- `provider_unavailable`: website/API không truy cập được hoặc có challenge.
- `no_results`: không có kết quả đúng ngôn ngữ.
- `media_mismatch`: kết quả không khớp phim.
- `unsafe_archive`: archive hoặc đường dẫn không an toàn.
- `download_failed`: tải hoặc ghi file thất bại.
- `refresh_failed`: file đã lưu nhưng Bazarr/Jellyfin chưa refresh; cho phép retry.

Khi fallback trực tiếp thất bại, kết quả Bazarr vẫn được giữ nguyên trong giao diện.

## Cấu hình

- `YIFY_DIRECT_ENABLED=false` mặc định.
- `YIFY_DIRECT_BASE_URL` chỉ được đặt ở backend/bootstrap, không nhận từ Flutter.
- Timeout và giới hạn kích thước có giá trị mặc định an toàn.
- Cài đặt Flutter chỉ thay đổi quyền dùng fallback; không thay đổi hostname provider.

## Kiểm thử nghiệm thu

- Bazarr vẫn tự phát hiện phụ đề Việt/Anh sau import.
- Tìm Bazarr lọc đúng ngôn ngữ/provider.
- Khi fallback tắt, backend không gọi YIFY Direct.
- Khi fallback bật và Bazarr trống, backend gọi YIFY Direct đúng một lần.
- Lỗi YIFY không làm mất kết quả Bazarr.
- Kết quả trùng giữa Bazarr/YIFY được gộp.
- Download token hết hạn hoặc bị sửa bị từ chối.
- Archive path traversal và file quá lớn bị từ chối.
- Phụ đề tải thành công được Bazarr và Jellyfin nhận diện.
- Flutter cho chọn phim, provider và ngôn ngữ; không yêu cầu nhập ID thủ công.
- Node tests, Flutter analyze/test/build Windows và kiểm tra stack đều pass.

## Quyết định phạm vi

- Bazarr là nguồn sự thật duy nhất về trạng thái phụ đề.
- YIFY Direct là thao tác theo yêu cầu, không chạy lịch nền.
- YIFY Direct mặc định tắt để tránh phụ thuộc website không ổn định.
- Không thêm nguồn torrent hoặc tự động tải phim trong thay đổi này.
