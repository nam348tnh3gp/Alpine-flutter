#!/bin/bash
# Tự build proot + loader từ source (oonid/pr) và tải busybox-static từ Alpine.
# Đặt vào jniLibs/<abi>/lib*.so để lách W^X.
# Chạy trong GitHub Actions.

set -euo pipefail

JNI_DIR="android/app/src/main/jniLibs"
mkdir -p "$JNI_DIR/arm64-v8a" "$JNI_DIR/armeabi-v7a"

ALPINE_REPO_BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main"
declare -A ALPINE_ARCH_MAP=( ["arm64-v8a"]="aarch64" ["armeabi-v7a"]="armhf" )

# ---- Kiểm tra công cụ ----
for cmd in git make python3 curl unzip; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "!! Cần cài đặt $cmd" >&2
        exit 1
    fi
done

# ---- Build proot và loader từ oonid/pr ----
echo "=== Build proot + loader từ oonid/pr ==="

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cd "$WORK_DIR"

# Chuyển SSH -> HTTPS để clone submodule
git config --global url."https://github.com/".insteadOf git@github.com:
if [ -n "${GITHUB_TOKEN:-}" ]; then
    git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf git@github.com:
fi

git clone --depth 1 https://github.com/oonid/pr.git proot-builder
cd proot-builder

# Chỉ update 2 submodule cần thiết (proot và samba cho talloc)
git submodule update --init vendor/proot vendor/samba

# 🔥 Build cả arm64 và arm bằng script có sẵn của oonid/pr
# KHÔNG patch, KHÔNG sed, KHÔNG thêm bất cứ thứ gì
echo "[build] Build cho arm64 và arm..."
./scripts/build.sh --arch=all

# Copy vào jniLibs
cp build/out/arm64/proot "$OLDPWD/$JNI_DIR/arm64-v8a/libproot.so"
cp build/out/arm64/loader "$OLDPWD/$JNI_DIR/arm64-v8a/libproot-loader.so"
cp build/out/arm/proot "$OLDPWD/$JNI_DIR/armeabi-v7a/libproot.so"
cp build/out/arm/loader "$OLDPWD/$JNI_DIR/armeabi-v7a/libproot-loader.so"

chmod 755 "$OLDPWD/$JNI_DIR/arm64-v8a/libproot.so" \
        "$OLDPWD/$JNI_DIR/arm64-v8a/libproot-loader.so" \
        "$OLDPWD/$JNI_DIR/armeabi-v7a/libproot.so" \
        "$OLDPWD/$JNI_DIR/armeabi-v7a/libproot-loader.so"

echo "✅ Build proot + loader hoàn tất"

# ---- Tải busybox-static từ Alpine ----
echo "=== Tải busybox-static từ Alpine ==="

fetch_busybox_alpine() {
    local abi="$1"
    local alpine_arch="${ALPINE_ARCH_MAP[$abi]}"
    local target_file="$JNI_DIR/$abi/libbusybox.so"

    if [ -f "$target_file" ] && [ -s "$target_file" ] && head -c4 "$target_file" | grep -q $'\x7fELF'; then
        echo "[busybox/$alpine_arch] Đã tồn tại và hợp lệ, bỏ qua"
        return 0
    fi

    local apk_index="$WORK_DIR/APKINDEX-$alpine_arch"
    curl -fsSL "$ALPINE_REPO_BASE/$alpine_arch/APKINDEX.tar.gz" | gunzip > "$apk_index" 2>/dev/null

    local apk_file
    apk_file=$(awk -v pkg="busybox-static" '
        /^P:/ { p = substr($0, 3) }
        /^V:/ { v = substr($0, 3) }
        p == pkg && v != "" { print p "-" v ".apk"; exit }
    ' "$apk_index")
    [ -z "$apk_file" ] && apk_file="busybox-static-1.36.1-r29.${alpine_arch}.apk"

    local apk_url="$ALPINE_REPO_BASE/$alpine_arch/$apk_file"
    local apk_path="$WORK_DIR/busybox-static-${alpine_arch}.apk"
    echo "[busybox/$alpine_arch] Tải từ $apk_url"
    curl -fsSL "$apk_url" -o "$apk_path" || {
        apk_url="https://dl-cdn.alpinelinux.org/alpine/edge/main/${alpine_arch}/busybox-static-1.36.1-r29.${alpine_arch}.apk"
        curl -fsSL "$apk_url" -o "$apk_path"
    }

    if [ ! -f "$apk_path" ] || [ ! -s "$apk_path" ]; then
        echo "!! Không tải được busybox-static." >&2
        return 1
    fi

    local extract_dir="$WORK_DIR/busybox-${alpine_arch}-extracted"
    mkdir -p "$extract_dir"
    tar -xzf "$apk_path" -C "$extract_dir" 2>/dev/null || tar -xJf "$apk_path" -C "$extract_dir" 2>/dev/null

    local src
    src=$(find "$extract_dir" -name "busybox.static" -type f 2>/dev/null | head -1)
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        echo "!! Không thấy busybox.static trong APK." >&2
        return 1
    fi

    cp -f "$src" "$target_file"
    chmod 755 "$target_file"
    echo "✅ OK: $target_file (ELF binary, $(du -h "$target_file" | cut -f1))"
}

for abi in arm64-v8a armeabi-v7a; do
    fetch_busybox_alpine "$abi" || exit 1
done

# ---- Kiểm tra cuối ----
echo "=== Kiểm tra file ELF ==="
for f in "$JNI_DIR"/*/*.so; do
    [ -f "$f" ] || continue
    if ! head -c4 "$f" | grep -q $'\x7fELF'; then
        echo "!! CẢNH BÁO: $f không phải ELF hợp lệ." >&2
        exit 1
    fi
    echo "OK: $f ($(du -h "$f" | cut -f1))"
done

echo "=== Hoàn tất tải và chuẩn bị native binaries ==="