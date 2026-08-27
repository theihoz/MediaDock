# Hướng dẫn Media Control

## Cài đặt

Media Control 0.2.0 dành cho Windows 10 64-bit trở lên. Cài WSL2 với bản phân phối Ubuntu, Docker Desktop và Microsoft Visual C++ 2015–2022 x64 runtime. Ổ media cần còn ít nhất 10 GB. Flutter có hỗ trợ Windows và NSIS 3.x chỉ cần thiết khi tự build bộ cài.

Build bộ cài chưa ký từ PowerShell chạy bằng quyền Administrator:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/build-installer.ps1
```

Chạy `dist\install.exe` bằng quyền Administrator. Bộ cài đặt client vào `C:\Program Files\Media Control`, lưu stack riêng tư ở `C:\ProgramData\MediaControl\stack` và mặc định dùng `D:\Media`. Quá trình cài chuẩn bị file, secret, controller loopback và firewall nhưng không tự bật container media.

Với source checkout, mở Ubuntu WSL tại thư mục dự án rồi chạy:

```bash
chmod +x scripts/*.sh
./scripts/bootstrap.sh --keep-running
```

Đây là luồng lần đầu: lệnh khởi động stack, chờ service bắt buộc, gọi `auto-configure.ps1 -MediaRoot <Windows path> -FirstRun`, seed cache cục bộ, hoàn tất wizard Jellyfin, yêu cầu Bazarr tìm phụ đề thiếu lần đầu và giữ stack chạy. Bỏ `--keep-running` nếu muốn dừng sau khi setup.

Để dùng thư mục tùy chỉnh, đặt đủ hai dạng đường dẫn trước lần chạy đầu, ví dụ `MEDIA_ROOT=/mnt/e/Media` và `MEDIA_ROOT_DOCKER=E:/Media`. Script chuẩn bị Windows cũng nhận `-MediaRoot E:\Media`. Không di chuyển media root đã khởi tạo bằng cách chỉ sửa một biến.

## Không gian làm việc

Client Material 3 nền tối có hai workspace và giữ lại trạng thái. Từ 840 px trở lên ứng dụng dùng navigation rail; dưới 840 px dùng thanh điều hướng phía dưới.

- **Nội dung**: Khám phá, Downloads, Vietsub và Thư viện.
- **Hệ thống**: Tổng quan, Services và Cài đặt.

Mỗi trang chỉ được tạo khi truy cập lần đầu và giữ filter, lựa chọn cùng trạng thái liên quan khi người dùng chuyển trang. Host controller cục bộ có thể chạy cùng ứng dụng, nhưng không tự bật Docker Desktop hoặc media stack.

## Quy trình sử dụng

Tại Khám phá, tìm phim hoặc series rồi lọc theo loại, năm hay trạng thái thư viện. Lịch sử giữ tối đa mười truy vấn trong `%LOCALAPPDATA%\MediaControl\search-history.json`; nút xóa sẽ dọn file này. Chọn một kết quả rồi bấm **Tìm bản tải**. Media Control chỉ chuẩn bị Radarr hoặc Sonarr tại thời điểm đó. Với TV, chọn mùa trước khi tìm bản theo mùa, hoặc chọn luồng theo tập trước khi tải danh sách tập.

Downloads đọc `GET /v1/downloads/events`. Trạng thái hiển thị trực tiếp, đang kết nối lại hoặc dữ liệu cũ. Khi SSE rớt, client polling mỗi giây nếu có bản tải active và mỗi 5 giây khi idle, sau đó quay lại SSE khi kết nối được. Tạm dừng, tiếp tục, thử lại và xóa đều có label; xóa luôn yêu cầu xác nhận.

Vietsub đi theo Nội dung → mùa/tập → nguồn/kết quả. Bazarr là luồng mặc định. YIFY Direct nằm trong phần nâng cao opt-in và không hoạt động nếu gateway chưa bật cấu hình tương ứng.

Thư viện hiển thị poster, trạng thái đã xem/xem tiếp và mở Jellyfin tại `${jellyfinBaseUrl}/web/#/details?id=<jellyfinId>`. `jellyfinBaseUrl` mặc định là `http://localhost:8096` và có thể đổi trong cấu hình client cục bộ.

## Nhà cung cấp

Lần chạy đầu và repair reconcile tài nguyên hiện có thay vì tạo trùng:

- Preferences và category phim/series của qBittorrent.
- Root folder, qBittorrent client và kết nối Prowlarr của Radarr/Sonarr.
- Application, tag, FlareSolverr proxy và indexer đã cấu hình trong Prowlarr.
- Network, thư viện phim/series, API token và Arr notification của Jellyfin.
- Kết nối Arr và profile ngôn ngữ Việt/Anh của Bazarr.

Seerr là tùy chọn và có thể cấu hình thủ công; dữ liệu last-good vẫn có thể hỗ trợ discovery fallback. Endpoint phim và TV chính thức của YTS là nguồn công khai tùy chọn, điều khiển bằng `YTS_MOVIE_API_URL`, `YTS_OFFICIAL_TV_URL` và `YTS_OFFICIAL_TV_ENABLED`. YIFY Direct chỉ bật qua `YIFY_DIRECT_ENABLED` và `YIFY_DIRECT_BASE_URL`. OpenSubtitles chỉ tham gia Bazarr khi có `OPENSUBTITLES_USERNAME` và `OPENSUBTITLES_PASSWORD`. Tự động tìm phụ đề Việt được bật mặc định, chạy mỗi sáu giờ và có thể điều chỉnh bằng `SUBTITLE_AUTO_ENABLED`, `SUBTITLE_AUTO_INTERVAL_MS`, `SUBTITLE_AUTO_MAX_ITEMS` và `SUBTITLE_AUTO_CONCURRENCY`. Chỉ dùng nguồn và nội dung bạn được phép truy cập.

## Cấu hình

Thiết lập riêng tư nằm trong `.env`; Docker nhận bản đã chuẩn hóa ở `.env.compose`. Không commit hai file này. `MEDIA_ROOT` là đường dẫn WSL dùng cho provider container, còn `MEDIA_ROOT_DOCKER` là đường dẫn bind kiểu Windows/Docker Desktop dùng cho gateway. Cả hai phải trỏ tới cùng một thư mục.

Giá trị cục bộ bắt buộc gồm `PUID`, `PGID`, `TZ`, tài khoản admin cục bộ, host-controller token, subtitle token secret, TV download token secret, bản phân phối WSL và đường dẫn dự án. Bộ cài sinh secret thay placeholder ở lần cài mới và giữ nguyên khi cập nhật.

Giá trị tùy chọn gồm OpenSubtitles, Jellyfin API key có sẵn, YIFY Direct, các endpoint YTS và công tắc official-TV. Tài khoản service mặc định chỉ phù hợp với PC loopback; không mở port provider ra Internet khi vẫn dùng credential mặc định. Gateway bind tại `127.0.0.1:3000`, còn host controller dùng `127.0.0.1:3210` cùng token riêng.

## Docker

Compose chạy một Node gateway cùng qBittorrent, Prowlarr, Radarr, Sonarr, Bazarr, Jellyfin, Seerr tùy chọn và FlareSolverr. Image tag giữ đúng như `docker-compose.yml`; setup thông thường không chủ động pull hoặc nâng phiên bản provider.

Khởi động hoặc reconcile toàn bộ stack tại thư mục dự án:

```bash
docker compose --env-file .env.compose up -d --build --remove-orphans
```

Kiểm tra hoặc dừng mà không xóa dữ liệu:

```bash
docker compose --env-file .env.compose ps
docker compose --env-file .env.compose stop
```

Không dùng `docker compose down -v` hoặc `docker volume rm` trong lúc cài đặt, cập nhật, repair hay vận hành bình thường. Hai volume PostgreSQL và Redis cũ được chủ ý giữ nguyên dù service không còn trong Compose. Luồng repair khôi phục trạng thái chạy/dừng trước đó.

## Khắc phục sự cố

Chạy `docker compose --env-file .env.compose config` trước để phát hiện sai đường dẫn hoặc biến môi trường, sau đó dùng `docker compose --env-file .env.compose ps` và `docker compose --env-file .env.compose logs <service>`. Nếu Ubuntu không gọi được `docker`, bật WSL integration trong Docker Desktop; bootstrap cũng có thể dùng Windows CLI của Docker Desktop khi được cài ở vị trí chuẩn.

Nếu ứng dụng không dùng được nút nguồn, khởi động lại app và kiểm tra `%LOCALAPPDATA%\MediaControl\config.json` đang trỏ tới controller launcher đã cài. Nếu gateway sẵn sàng nhưng một nguồn lỗi, UI có thể trả kết quả partial hoặc `provider_unavailable`; chỉ kiểm tra provider đó thay vì tạo lại stack.

Kiểm tra gateway và stream download tại máy local:

```bash
curl http://localhost:3000/health
curl -N http://localhost:3000/v1/downloads/events
```

Để mở Jellyfin từ máy khác, đặt `jellyfinBaseUrl` thành URL LAN truy cập được. Vẫn giữ gateway và host controller ở loopback.

## Sửa chữa

Từ Ubuntu WSL tại stack đã cài hoặc source repository, chạy:

```bash
./scripts/bootstrap.sh --repair
```

Repair chỉ bật service khi cần, thực hiện reconcile GET → compare → update/create rồi khôi phục stack đã dừng trước đó. Nó không chạy wizard Jellyfin, seed cache hoặc batch tìm phụ đề thiếu của Bazarr. Chạy repair hai lần phải giữ nguyên cấu hình canonical và không tạo trùng client, application, tag, proxy, library hoặc profile.

Khi stack đang chạy, operator có thể chạy trực tiếp lệnh sau trong PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\auto-configure.ps1 -MediaRoot 'D:\Media'
```

Không thêm `-FirstRun` khi repair thông thường. Bản cập nhật installer yêu cầu cùng luồng repair sau khi lần chạy đầu đã hoàn tất.

## Gỡ cài đặt an toàn

Dừng stack hoặc repair không xóa media hay Docker volume. Nếu muốn giữ dữ liệu, dùng `docker compose --env-file .env.compose stop`, sao lưu `.env` cùng media root và không chạy uninstaller.

Uninstaller đóng gói được thiết kế để xóa triệt để. Nó yêu cầu nhập chính xác `XOA TOAN BO`, xác minh ownership marker `.media-control-root`, xóa container và image không còn dùng của bản cài này, xóa hai volume database cũ được giữ lại, rồi xóa vĩnh viễn media root đã chọn. Hãy sao lưu toàn bộ phim, series, download, phụ đề, cấu hình và secret trước khi xác nhận. Không thay bằng lệnh `down -v` hoặc `volume rm` thủ công vì các lệnh đó bỏ qua kiểm tra ownership.
