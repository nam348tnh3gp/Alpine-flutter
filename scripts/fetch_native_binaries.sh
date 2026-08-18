#!/bin/bash
# Tải proot + libtalloc từ Termux repo, busybox-static từ Alpine CDN.
# Đặt vào jniLibs/<abi>/lib*.so để lách W^X. Chạy trong GitHub Actions.

set -euo pipefail

JNI_DIR="android/app/src/main/jniLibs"
WORK_DIR="$(mktemp -d)"
mkdir -p "$JNI_DIR/arm64-v8a" "$JNI_DIR/armeabi-v7a"

TERMUX_REPO_BASE="https://packages.termux.dev/apt/termux-main/dists/stable/main"
ALPINE_REPO_BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main"

declare -A ARCH_MAP=( ["aarch64"]="arm64-v8a" ["arm"]="armeabi-v7a" )
declare -A ALPINE_ARCH_MAP=( ["aarch64"]="aarch64" ["arm"]="armhf" )

if ! command -v patchelf &>/dev/null; then
    echo "patchelf chưa có, đang cài đặt..."
    sudo apt-get update -qq && sudo apt-get install -y -qq patchelf
fi

termux_deb_url() {
    local termux_arch="$1" pkg_name="$2"
    local idx="$WORK_DIR/Packages-$termux_arch"
    if [ ! -f "$idx" ]; then
        curl -fsSL "$TERMUX_REPO_BASE/binary-$termux_arch/Packages" -o "$idx" 2>/dev/null || {
            curl -fsSL "$TERMUX_REPO_BASE/binary-$termux_arch/Packages.gz" | gunzip > "$idx"
        }
    fi
    awk -v pkg="$pkg_name" '
        /^Package: / { p = $2 }
        p == pkg && /^Filename: / { print $2; exit }
    ' "$idx"
}

termux_extract_deb() {
    local deb_path="$1" extract_dir="$2"
    mkdir -p "$extract_dir"
    ( cd "$extract_dir" && ar x "$deb_path" )
    local data_tar
    data_tar="$(ls "$extract_dir"/data.tar.* | head -n1)"
    tar -xf "$data_tar" -C "$extract_dir"
}

fetch_proot() {
    local termux_arch="$1"
    local abi="${ARCH_MAP[$termux_arch]}"
    local target_file="$JNI_DIR/$abi/libproot.so"

    if [ -f "$target_file" ] && [ -s "$target_file" ]; then
        echo "[proot/$termux_arch] Đã tồn tại, bỏ qua"
        return 0
    fi

    local filename
    filename="$(termux_deb_url "$termux_arch" "proot")"
    if [ -z "$filename" ]; then
        echo "!! Không tìm thấy proot cho arch '$termux_arch'." >&2
        return 1
    fi

    local deb_url="https://packages.termux.dev/apt/termux-main/${filename}"
    local deb_path="$WORK_DIR/proot-${termux_arch}.deb"
    echo "[proot/$termux_arch] Tải từ $deb_url"
    curl -fsSL "$deb_url" -o "$deb_path"

    local extract_dir="$WORK_DIR/proot-${termux_arch}-extracted"
    termux_extract_deb "$deb_path" "$extract_dir"

    local src="$extract_dir/data/data/com.termux/files/usr/bin/proot"
    if [ ! -f "$src" ]; then
        echo "!! Không thấy proot binary tại $src." >&2
        return 1
    fi

    cp -f "$src" "$target_file"
    chmod 755 "$target_file"

    patchelf --set-rpath '$ORIGIN' "$target_file" \
        || echo "!! patchelf set-rpath thất bại cho $target_file (không chặn build)"

    echo "OK: $target_file ($(du -h "$target_file" | cut -f1))"
}

fetch_libtalloc() {
    local termux_arch="$1"
    local abi="${ARCH_MAP[$termux_arch]}"
    local target_file="$JNI_DIR/$abi/libtalloc.so"

    if [ -f "$target_file" ] && [ -s "$target_file" ]; then
        echo "[libtalloc/$termux_arch] Đã tồn tại, bỏ qua"
        return 0
    fi

    local filename
    filename="$(termux_deb_url "$termux_arch" "libtalloc")"
    if [ -z "$filename" ]; then
        echo "!! Không tìm thấy libtalloc cho arch '$termux_arch'." >&2
        return 1
    fi

    local deb_url="https://packages.termux.dev/apt/termux-main/${filename}"
    local deb_path="$WORK_DIR/libtalloc-${termux_arch}.deb"
    echo "[libtalloc/$termux_arch] Tải từ $deb_url"
    curl -fsSL "$deb_url" -o "$deb_path"

    local extract_dir="$WORK_DIR/libtalloc-${termux_arch}-extracted"
    termux_extract_deb "$deb_path" "$extract_dir"

    local src
    src="$(find "$extract_dir/data/data/com.termux/files/usr/lib" -name 'libtalloc.so*' -type f | head -n1)"
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        echo "!! Không tìm thấy libtalloc.so* trong gói." >&2
        return 1
    fi

    cp -f "$src" "$target_file"
    chmod 755 "$target_file"
    echo "OK: $target_file ($(du -h "$target_file" | cut -f1))"
}

fetch_busybox_alpine() {
    local termux_arch="$1"
    local abi="${ARCH_MAP[$termux_arch]}"
    local alpine_arch="${ALPINE_ARCH_MAP[$termux_arch]}"
    local target_file="$JNI_DIR/$abi/libbusybox.so"

    if [ -f "$target_file" ] && [ -s "$target_file" ]; then
        echo "[busybox/$alpine_arch] Đã tồn tại, bỏ qua"
        return 0
    fi

    local apk_index="$WORK_DIR/APKINDEX-$alpine_arch"
    curl -fsSL "$ALPINE_REPO_BASE/$alpine_arch/APKINDEX.tar.gz" | gunzip > "$apk_index"

    local apk_file
    apk_file=$(awk -v pkg="busybox-static" '
        /^P:/ { p = substr($0, 3) }
        /^V:/ { v = substr($0, 3) }
        p == pkg && v != "" { print p "-" v ".apk"; exit }
    ' "$apk_index")

    if [ -z "$apk_file" ]; then
        echo "!! Không tìm thấy busybox-static cho arch '$alpine_arch'." >&2
        return 1
    fi

    local apk_url="$ALPINE_REPO_BASE/$alpine_arch/$apk_file"
    local apk_path="$WORK_DIR/busybox-static-${alpine_arch}.apk"
    echo "[busybox/$alpine_arch] Tải từ $apk_url"
    curl -fsSL "$apk_url" -o "$apk_path"

    local extract_dir="$WORK_DIR/busybox-${alpine_arch}-extracted"
    mkdir -p "$extract_dir"
    tar --ignore-zeros -xzf "$apk_path" -C "$extract_dir"

    local src="$extract_dir/bin/busybox.static"
    if [ ! -f "$src" ]; then
        echo "!! Không thấy busybox.static trong APK (đã giải nén tại $extract_dir)." >&2
        return 1
    fi

    cp -f "$src" "$target_file"
    chmod 755 "$target_file"
    echo "OK: $target_file ($(du -h "$target_file" | cut -f1))"
}

echo "=== Tải proot từ Termux ==="
for termux_arch in aarch64 arm; do
    fetch_proot "$termux_arch" || exit 1
done

echo "=== Tải libtalloc từ Termux ==="
for termux_arch in aarch64 arm; do
    fetch_libtalloc "$termux_arch" || exit 1
done

echo "=== Cưỡng chế đổi tên NEEDED trong libproot.so cho khớp libtalloc.so ==="
# libproot.so ghi cứng tên thư viện phụ thuộc trong ELF dynamic section
# (thường là "libtalloc.so.2" có số version). File ta đặt trong jniLibs lại
# PHẢI tên "libtalloc.so" (không version) vì Android chỉ extract file khớp
# đúng pattern lib*.so. Nếu không sửa NEEDED, linker tìm đúng chuỗi cũ
# "libtalloc.so.2", không thấy, proot crash ngay lúc khởi động dù rpath đã
# đúng. patchelf --replace-needed ép đổi chuỗi đó cho khớp tên file thật.
fix_proot_needed() {
    local abi="$1"
    local proot_file="$JNI_DIR/$abi/libproot.so"
    [ -f "$proot_file" ] || return 0

    local needed_list
    needed_list="$(patchelf --print-needed "$proot_file")"
    echo "[$abi] NEEDED hiện tại của libproot.so:"
    echo "$needed_list" | sed 's/^/    /'

    local old_name
    old_name="$(echo "$needed_list" | grep -E '^libtalloc\.so' || true)"

    if [ -z "$old_name" ]; then
        echo "[$abi] Không thấy NEEDED nào bắt đầu bằng libtalloc.so, bỏ qua."
        return 0
    fi

    if [ "$old_name" = "libtalloc.so" ]; then
        echo "[$abi] NEEDED đã đúng 'libtalloc.so', không cần đổi."
        return 0
    fi

    echo "[$abi] Cưỡng chế đổi NEEDED: '$old_name' -> 'libtalloc.so'"
    patchelf --replace-needed "$old_name" "libtalloc.so" "$proot_file"

    echo "[$abi] NEEDED sau khi patch:"
    patchelf --print-needed "$proot_file" | sed 's/^/    /'
}

for abi in arm64-v8a armeabi-v7a; do
    fix_proot_needed "$abi"
done

echo "=== Tải busybox-static từ Alpine ==="
for termux_arch in aarch64 arm; do
    fetch_busybox_alpine "$termux_arch" || exit 1
done

echo "=== Kiểm tra file ELF ==="
for f in "$JNI_DIR"/*/*.so; do
    [ -f "$f" ] || continue
    if ! head -c4 "$f" | grep -q $'\x7fELF'; then
        echo "!! CẢNH BÁO: $f không phải ELF hợp lệ." >&2
        exit 1
    fi
    echo "OK: $f ($(du -h "$f" | cut -f1))"
done

rm -rf "$WORK_DIR"
echo "=== Hoàn tất tải và chuẩn bị native binaries ==="
