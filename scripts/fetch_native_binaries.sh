#!/bin/bash
# Tải proot + libtalloc từ Termux repo, busybox-static từ Alpine CDN.
# Đặt vào jniLibs/<abi>/lib*.so để lách W^X. Chạy trong GitHub Actions.

set -euo pipefail

JNI_DIR="android/app/src/main/jniLibs"
WORK_DIR="$(mktemp -d)"
mkdir -p "$JNI_DIR/arm64-v8a" "$JNI_DIR/armeabi-v7a"

TERMUX_REPO_BASE="https://packages.termux.dev/apt/termux-main/dists/stable/main"
ALPINE_REPO_BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main"

# Termux arch -> Android ABI
declare -A ARCH_MAP=( ["aarch64"]="arm64-v8a" ["arm"]="armeabi-v7a" )
# Termux arch -> tên arch dùng trong URL Alpine (Alpine gọi 32-bit ARM là "armhf")
declare -A ALPINE_ARCH_MAP=( ["aarch64"]="aarch64" ["arm"]="armhf" )

if ! command -v patchelf &>/dev/null; then
    echo "patchelf chưa có, đang cài đặt..."
    sudo apt-get update -qq && sudo apt-get install -y -qq patchelf
fi

# ---------- Termux: lấy URL .deb mới nhất của 1 package ----------
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

# ---------- proot (Termux) ----------
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

    # RPATH gốc trỏ tới /data/data/com.termux/... không tồn tại trong app của
    # ta. Đặt lại thành $ORIGIN để proot tìm thư viện phụ thuộc (libtalloc.so)
    # ngay trong cùng thư mục nativeLibraryDir lúc runtime, không cần
    # LD_LIBRARY_PATH đặc biệt.
    patchelf --set-rpath '$ORIGIN' "$target_file" \
        || echo "!! patchelf set-rpath thất bại cho $target_file (không chặn build)"

    echo "OK: $target_file ($(du -h "$target_file" | cut -f1))"
}

# ---------- libtalloc (Termux, proot phụ thuộc runtime) ----------
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

# ---------- busybox-static (Alpine) ----------
fetch_busybox_alpine() {
    local termux_arch="$1"   # dùng chung key với ARCH_MAP: aarch64 | arm
    local abi="${ARCH_MAP[$termux_arch]}"
    local alpine_arch="${ALPINE_ARCH_MAP[$termux_arch]}"
    local target_file="$JNI_DIR/$abi/libbusybox.so"

    if [ -f "$target_file" ] && [ -s "$target_file" ]; then
        echo "[busybox/$alpine_arch] Đã tồn tại, bỏ qua"
        return 0
    fi

    local apk_index="$WORK_DIR/APKINDEX-$alpine_arch"
    curl -fsSL "$ALPINE_REPO_BASE/$alpine_arch/APKINDEX.tar.gz" | gunzip > "$apk_index"

    # APKINDEX KHÔNG có field "F:" (filename). Tên file thật là "<P>-<V>.apk",
    # dựng lại từ field P: (tên gói) và V: (version) của đúng record.
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

    # QUAN TRỌNG: file .apk của Alpine là NHIỀU stream gzip/tar nối liền nhau
    # (control segment rồi tới data segment). Không có --ignore-zeros, tar
    # dừng ngay sau segment đầu (chỉ có .PKGINFO...) và sẽ không bao giờ lấy
    # được bin/busybox.static nằm ở segment data.
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
