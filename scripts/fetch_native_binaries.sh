#!/bin/bash
# Chạy trong GitHub Actions. Tải proot (static) + busybox (static) cho
# arm64-v8a và armeabi-v7a, đặt vào android/app/src/main/jniLibs/<abi>/
# với tên "lib*.so" để hệ thống Android tự cấp quyền exec (W^X exemption)
# khi extract vào nativeLibraryDir lúc cài APK.
#
# NGUỒN BINARY (cần bạn xác nhận định kỳ vì release asset có thể đổi tên):
#   - proot static:  https://github.com/proot-me/proot-static-build/releases
#   - busybox static: https://github.com/meefik/busybox/releases
#
# Nếu asset name đổi, sửa PROOT_PATTERN / BUSYBOX_PATTERN bên dưới.

set -euo pipefail

JNI_DIR="android/app/src/main/jniLibs"
mkdir -p "$JNI_DIR/arm64-v8a" "$JNI_DIR/armeabi-v7a"

# --- 1. Lấy URL asset mới nhất từ GitHub API ---------------------------------
gh_latest_asset_url() {
    local repo="$1" pattern="$2"
    curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
        | grep -oE '"browser_download_url": *"[^"]+"' \
        | cut -d'"' -f4 \
        | grep -E "$pattern" \
        | head -n1
}

# --- 2. proot ------------------------------------------------------------
PROOT_AARCH64_URL=$(gh_latest_asset_url "proot-me/proot-static-build" "aarch64.*static|static.*aarch64")
PROOT_ARMV7_URL=$(gh_latest_asset_url "proot-me/proot-static-build" "arm(v7)?[^6][^4].*static|static.*armv7")

if [ -z "$PROOT_AARCH64_URL" ] || [ -z "$PROOT_ARMV7_URL" ]; then
    echo "!! Không tìm thấy asset proot static tự động."
    echo "!! Hãy vào https://github.com/proot-me/proot-static-build/releases"
    echo "!! và set PROOT_AARCH64_URL / PROOT_ARMV7_URL thủ công trong workflow."
    exit 1
fi

echo "[proot] arm64-v8a  <- $PROOT_AARCH64_URL"
curl -fsSL "$PROOT_AARCH64_URL" -o "$JNI_DIR/arm64-v8a/libproot.so"

echo "[proot] armeabi-v7a <- $PROOT_ARMV7_URL"
curl -fsSL "$PROOT_ARMV7_URL" -o "$JNI_DIR/armeabi-v7a/libproot.so"

# --- 3. busybox (dùng làm shell + coreutils tối thiểu trước khi vào Alpine) --
BUSYBOX_ARM64_URL=$(gh_latest_asset_url "meefik/busybox" "arm64|aarch64")
BUSYBOX_ARM_URL=$(gh_latest_asset_url "meefik/busybox" "(^|[^6])arm($|[^6])|armv7")

if [ -n "$BUSYBOX_ARM64_URL" ]; then
    echo "[busybox] arm64-v8a <- $BUSYBOX_ARM64_URL"
    curl -fsSL "$BUSYBOX_ARM64_URL" -o "$JNI_DIR/arm64-v8a/libbusybox.so"
fi
if [ -n "$BUSYBOX_ARM_URL" ]; then
    echo "[busybox] armeabi-v7a <- $BUSYBOX_ARM_URL"
    curl -fsSL "$BUSYBOX_ARM_URL" -o "$JNI_DIR/armeabi-v7a/libbusybox.so"
fi

# --- 4. Cấp quyền thực thi + kiểm tra ELF hợp lệ -----------------------------
for f in "$JNI_DIR"/arm64-v8a/*.so "$JNI_DIR"/armeabi-v7a/*.so; do
    chmod 755 "$f"
    if ! head -c4 "$f" | grep -q $'\x7fELF'; then
        echo "!! CẢNH BÁO: $f không phải file ELF hợp lệ (có thể tải nhầm trang HTML lỗi)."
        exit 1
    fi
    echo "OK: $f ($(du -h "$f" | cut -f1))"
done

echo "Hoàn tất tải native binaries."
