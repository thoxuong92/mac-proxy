# mac-proxy

Script cài proxy toàn hệ thống cho macOS chỉ bằng cách dán thông tin proxy. Dùng để tách IP cho từng máy (Mac mini host và các máy ảo macOS).

Script dùng lõi [mihomo](https://github.com/MetaCubeX/mihomo) (Clash Meta) ở chế độ **TUN**, nên mọi app (Safari, Discord, Xcode, App Store Connect...) đều đi qua proxy, kể cả app không hỗ trợ proxy.

## Tính năng

- Nhận proxy dạng `ip:port:user:pass`, `ip:port` hoặc `user:pass@ip:port`
- Tự nhận diện SOCKS5 hay HTTP và kiểm tra proxy trước khi cài
- Tự tải lõi mihomo đúng kiến trúc (Apple Silicon / Intel)
- Chạy nền dưới dạng LaunchDaemon, tự khởi động cùng máy, tự chạy lại nếu bị tắt
- Tắt proxy cũ trong System Settings và tắt IPv6 để tránh lộ IP
- Tùy chọn cho Chrome Remote Desktop đi thẳng, không qua proxy
- Menu: cài / đổi proxy, kiểm tra trạng thái và IP, gỡ bỏ

## Cách dùng

1. Chép `proxy-setup.command` vào máy Mac (ví dụ vào thư mục Downloads).
2. Mở Terminal và chạy:
   ```bash
   bash ~/Downloads/proxy-setup.command
   ```
3. Nhập mật khẩu máy Mac khi được hỏi, chọn `1` rồi dán thông tin proxy.
4. Tắt iCloud Private Relay: System Settings → [Tên bạn] → iCloud → Private Relay → Off.

Làm lần lượt trên từng máy, mỗi máy một proxy riêng.

## Vị trí file trên Mac

| File | Đường dẫn |
|---|---|
| Lõi mihomo, log, thông tin proxy | `/Library/Application Support/ProxySetup/` |
| Cấu hình | `/Library/Application Support/ProxySetup/config/config.yaml` |
| Dịch vụ chạy nền | `/Library/LaunchDaemons/com.proxysetup.mihomo.plist` |

## Lưu ý

- Nên dùng proxy **SOCKS5 tĩnh**. Proxy HTTP không hỗ trợ UDP nên voice/video Discord có thể không chạy.
- Nếu tiến trình proxy bị dừng, máy sẽ tạm dùng IP thật cho tới khi dịch vụ tự khởi động lại.
- Máy ảo nên đặt network là **Bridged** để traffic không đi qua TUN của máy host.
- Repo có `.gitattributes` ép file script dùng xuống dòng LF. Nếu file bị đổi sang CRLF (Windows), bash trên Mac sẽ báo lỗi.
