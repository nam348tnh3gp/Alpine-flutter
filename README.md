# Alpine Runner (Flutter + proot, không cần root)

## Cấu trúc repo (đúng như bạn yêu cầu — chỉ cần chuẩn bị 2 thứ)
```
lib/                     <- Dart source (bạn chỉnh sửa ở đây)
pubspec.yaml
overrides/                <- Android config sẽ được workflow copy-đè vào project mới
  android/app/build.gradle
  android/build.gradle
  android/app/src/main/AndroidManifest.xml
  android/app/src/main/kotlin/.../MainActivity.kt
  rootfs-scripts/start-gui.sh
scripts/
  fetch_native_binaries.sh
.github/workflows/build.yml   <- toàn bộ pipeline
```
Workflow tự chạy `flutter create`, copy `lib/` + `pubspec.yaml` vào, ghi đè
`android/` bằng `overrides/`, sed Kotlin = 1.8.22, tải proot/busybox, build APK.

## Cơ chế "lách" W^X (giải thích để bạn hiểu, không phải khai thác lỗ hổng)
Từ Android 10 (W^X), hệ thống chặn thực thi file từ các thư mục app tự ghi
(`filesDir`, `cacheDir`...). Ngoại lệ DUY NHẤT là `nativeLibraryDir`
(`applicationInfo.nativeLibraryDir`) — nơi hệ thống tự giải nén các file
`lib*.so` khai báo trong `jniLibs/<abi>/` lúc **cài đặt APK**, và cấp quyền
thực thi hợp lệ. Đây là cơ chế Android hỗ trợ sẵn (không phải bug), được
Termux, UserLAnd, AnLinux... dùng công khai. App chỉ cần:
1. Đặt binary (proot, busybox...) vào `jniLibs/<abi>/libXXX.so`
2. Set `android:extractNativeLibs="true"` + `useLegacyPackaging = true`
3. Lúc runtime, lấy đường dẫn qua `applicationInfo.nativeLibraryDir` rồi exec thẳng.

## NHỮNG CHỖ BẠN BẮT BUỘC PHẢI TỰ KIỂM TRA
Tôi không có mạng để chạy thử pipeline này thật, nên các điểm sau có rủi ro
cần bạn test trên máy/CI thật rồi chỉnh lại:

1. **URL asset proot/busybox** trong `scripts/fetch_native_binaries.sh` —
   dò tự động qua GitHub API `releases/latest`, nhưng tên asset có thể đổi.
   Nếu script báo lỗi "Không tìm thấy asset", vào thẳng trang release, copy
   URL rồi gán cứng.
2. **Tương thích proot binary với Android/Bionic**: nhiều bản build proot
   sẵn (kể cả của Termux) được compile với glibc/prefix riêng, có thể lỗi
   `no such file or directory` khi chạy ngoài môi trường gốc. Nếu bản
   static từ `proot-me/proot-static-build` không chạy được, phương án chắc
   ăn nhất là **tự cross-compile proot bằng musl** (proot hỗ trợ build
   static) trong một job Docker riêng rồi nhúng — tôi có thể viết thêm job
   đó nếu bản build sẵn không chạy.
3. **PROOT_LOADER**: proot cần một "loader" binary phụ để ptrace hoạt động
   đúng trên vài kernel Android; nếu proot log lỗi liên quan `loader`, cần
   tải thêm `proot-loader` static tương ứng và trỏ `PROOT_LOADER` đúng file.
4. **RealVNC deep link**: `vnc://host:port` là scheme phổ biến nhưng cần
   xác nhận đúng với version RealVNC Viewer hiện tại trên Play Store; nếu
   không mở được, làm nút "Copy địa chỉ 127.0.0.1:5900" để người dùng dán
   thủ công.
5. **minSdkVersion 26**: proot cần ptrace ổn định hơn trên Android 8+; máy
   Android 7 trở xuống sẽ không cài được app (as-designed).
6. **Kích thước rootfs Alpine + gói Xvfb/x11vnc**: tải lần đầu có thể vài
   chục MB, cần xử lý mất mạng giữa chừng (resume) — hiện code chưa resume,
   chỉ tải lại từ đầu nếu lỗi.

## proot-distro-style: chuyển đổi nhiều distro
Vì kiến trúc đã tách rời "rootfs" (`filesDir/alpine-rootfs`) khỏi
"executor" (`libproot.so` cố định trong nativeLibraryDir), bạn có thể thêm
các profile khác (Ubuntu, Debian minirootfs...) bằng cách thêm map arch→URL
tương tự `_alpineArchMap` trong `proot_service.dart`, rồi cho UI chọn
distro trước bước bootstrap — logic proot khởi chạy giữ nguyên.
