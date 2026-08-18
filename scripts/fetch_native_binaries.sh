#!/bin/bash
# Tải proot từ Termux repo và busybox từ Alpine CDN
# Busybox Alpine được đặt vào jniLibs/<abi>/libbusybox.so
# Chạy trong GitHub Actions

set -euo pipefail

JNI_DIR="android/app/src/main/jniLibs"
WORK_DIR="$(mktemp -d)"
mkdir -p "$JNI_DIR/arm64-v8a" "$JNI_DIR/armeabi-v7a"

# Termux repo cho proot
TERMUX_REPO_BASE="https://packages.termux.dev/apt/termux-main/dists/stable/main"

# Alpine repo cho busybox-static
ALPINE_REPO_BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main"

# Map Termux arch -> Android ABI
declare -A ARCH_MAP=( ["aarch64"]="arm64-v8a" ["arm"]="armeabi-v7a" )
# Map Alpine arch
declare -A ALPINE_ARCH_MAP=( ["aarch64"]="aarch64" ["arm"]="armhf" )

# ---------- Hàm tải proot từ Termux ----------
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

fetch_proot() {
    local termux_arch="$1"
    local abi="${ARCH_MAP[$termux_arch]}"
    local target_file="$JNI_DIR/$abi/libproot.so"
    local target_loader="$JNI_DIR/$abi/libprootloader.so"

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
    mkdir -p "$extract_dir"
    ( cd "$extract_dir" && ar x "$deb_path" )
    local data_tar
    data_tar="$(ls "$extract_dir"/data.tar.* | head -n1)"
    tar -xf "$data_tar" -C "$extract_dir"

    local src="$extract_dir/data/data/com.termux/files/usr/bin/proot"
    if [ ! -f "$src" ]; then
        echo "!! Không thấy proot binary tại $src." >&2
        return 1
    fi

    cp -f "$src" "$target_file"
    chmod 755 "$target_file"
    echo "OK: $target_file ($(du -h "$target_file" | cut -f1))"

    # Tạo libprootloader.so (fake loader)
    echo "Tạo libprootloader.so cho $abi..."
    cat > "$target_loader" << 'EOF'
#!/system/bin/sh
# Fake proot loader - bypass
exec "$@"
EOF
    chmod 755 "$target_loader"
}

# ---------- Hàm tải busybox-static từ Alpine ----------
fetch_busybox_alpine() {
    local alpine_arch="$1"
    local abi="${ARCH_MAP[$alpine_arch]}"
    local target_file="$JNI_DIR/$abi/libbusybox.so"

    if [ -f "$target_file" ] && [ -s "$target_file" ]; then
        echo "[busybox/$alpine_arch] Đã tồn tại, bỏ qua"
        return 0
    fi

    # Tải APK index để tìm phiên bản mới nhất
    local apk_index="$WORK_DIR/APKINDEX-$alpine_arch"
    curl -fsSL "$ALPINE_REPO_BASE/$alpine_arch/APKINDEX.tar.gz" | gunzip > "$apk_index"

    # Lấy tên file APK của busybox-static
    local apk_file
    apk_file=$(awk -v pkg="busybox-static" '
        /^P:busybox-static$/ { found=1 }
        found && /^F:busybox-static-/ { print $2; exit }
    ' "$apk_index")

    if [ -z "$apk_file" ]; then
        echo "!! Không tìm thấy busybox-static cho arch '$alpine_arch'." >&2
        return 1
    fi

    local apk_url="$ALPINE_REPO_BASE/$alpine_arch/$apk_file"
    local apk_path="$WORK_DIR/busybox-static-${alpine_arch}.apk"
    echo "[busybox/$alpine_arch] Tải từ $apk_url"
    curl -fsSL "$apk_url" -o "$apk_path"

    # Giải nén APK (là archive tar.gz)
    local extract_dir="$WORK_DIR/busybox-${alpine_arch}-extracted"
    mkdir -p "$extract_dir"
    tar -xzf "$apk_path" -C "$extract_dir"

    local src="$extract_dir/bin/busybox.static"
    if [ ! -f "$src" ]; then
        echo "!! Không thấy busybox.static trong APK." >&2
        return 1
    fi

    cp -f "$src" "$target_file"
    chmod 755 "$target_file"
    echo "OK: $target_file ($(du -h "$target_file" | cut -f1))"
}

# ---------- Bước 1: Cài patchelf ----------
if ! command -v patchelf &>/dev/null; then
    echo "patchelf chưa có, đang cài đặt..."
    sudo apt-get update && sudo apt-get install -y patchelf
fi

# ---------- Bước 2: Tải proot từ Termux ----------
echo "=== Tải proot từ Termux ==="
for termux_arch in aarch64 arm; do
    fetch_proot "$termux_arch" || exit 1
done

# ---------- Bước 3: Tải busybox-static từ Alpine ----------
echo "=== Tải busybox-static từ Alpine ==="
for alpine_arch in aarch64 arm; do
    fetch_busybox_alpine "$alpine_arch" || exit 1
done

# ---------- Bước 4: Patch libproot.so để tìm libtalloc ----------
# Tải libtalloc từ Termux repo (nếu cần)
echo "=== Tải libtalloc từ Termux ==="
for termux_arch in aarch64 arm; do
    local abi="${ARCH_MAP[$termux_arch]}"
    local target_file="$JNI_DIR/$abi/libtalloc.so"
    
    if [ ! -f "$target_file" ] || [ ! -s "$target_file" ]; then
        local filename
        filename="$(termux_deb_url "$termux_arch" "libtalloc")"
        if [ -n "$filename" ]; then
            local deb_url="https://packages.termux.dev/apt/termux-main/${filename}"
            local deb_path="$WORK_DIR/libtalloc-${termux_arch}.deb"
            echo "[libtalloc/$termux_arch] Tải từ $deb_url"
            curl -fsSL "$deb_url" -o "$deb_path"

            local extract_dir="$WORK_DIR/libtalloc-${termux_arch}-extracted"
            mkdir -p "$extract_dir"
            ( cd "$extract_dir" && ar x "$deb_path" )
            local data_tar
            data_tar="$(ls "$extract_dir"/data.tar.* | head -n1)"
            tar -xf "$data_tar" -C "$extract_dir"

            local src="$extract_dir/data/data/com.termux/files/usr/lib/libtalloc.so.2"
            if [ -f "$src" ]; then
                cp -f "$src" "$target_file"
                chmod 755 "$target_file"
                echo "OK: $target_file ($(du -h "$target_file" | cut -f1))"
            else
                echo "!! Không tìm thấy libtalloc.so.2" >&2
            fi
        fi
    fi
done

# ---------- Bước 5: Kiểm tra ELF ----------
echo "=== Kiểm tra file ELF ==="
for f in "$JNI_DIR"/*/*.so; do
    if [ -f "$f" ] && ! head -c4 "$f" | grep -q $'\x7fELF'; then
        echo "!! CẢNH BÁO: $f không phải ELF hợp lệ." >&2
        exit 1
    fi
    [ -f "$f" ] && echo "OK: $f ($(du -h "$f" | cut -f1))"
done

rm -rf "$WORK_DIR"
echo "=== Hoàn tất tải và chuẩn bị native binaries ==="