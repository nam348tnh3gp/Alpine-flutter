#!/bin/bash
# Tải proot + loader/loader32, libtalloc, libandroid-shmem từ Termux.
# Patch RPATH và đổi tên NEEDED để tương thích trên Android.
# Chạy trong GitHub Actions.
#
# targetSdk=28 giải quyết SELinux W^X nhưng KHÔNG đủ:
# Alpine binary dùng musl ELF interpreter (/lib/ld-musl-*.so.1) không tồn tại
# trên Android → kernel không exec được dù SELinux cho phép.
# Loader (từ gói proot Termux) giải quyết bằng cách tự map ELF vào memory,
# hoàn toàn bỏ qua kernel execve + ELF interpreter → BẮT BUỘC trên mọi Android.

set -euo pipefail

JNI_DIR="android/app/src/main/jniLibs"
WORK_DIR="$(mktemp -d)"
mkdir -p "$JNI_DIR/arm64-v8a" "$JNI_DIR/armeabi-v7a"

TERMUX_REPO_BASE="https://packages.termux.dev/apt/termux-main/dists/stable/main"

declare -A ARCH_MAP=( ["aarch64"]="arm64-v8a" ["arm"]="armeabi-v7a" )

abi_to_termux_arch() {
    case "$1" in
        arm64-v8a)   echo "aarch64" ;;
        armeabi-v7a) echo "arm" ;;
        *)           echo "" ;;
    esac
}

if ! command -v patchelf &>/dev/null; then
    echo "patchelf chưa có, đang cài đặt..."
    sudo apt-get update -qq && sudo apt-get install -y -qq patchelf
fi

# ---- Hàm tiện ích ----

termux_deb_url() {
    local termux_arch="$1" pkg_name="$2"
    local idx="$WORK_DIR/Packages-$termux_arch"
    if [ ! -f "$idx" ]; then
        curl -fsSL "$TERMUX_REPO_BASE/binary-$termux_arch/Packages" -o "$idx" 2>/dev/null || \
            curl -fsSL "$TERMUX_REPO_BASE/binary-$termux_arch/Packages.gz" | gunzip > "$idx"
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

# ---- proot + loader/loader32 ----

fetch_proot() {
    local termux_arch="$1"
    local abi="${ARCH_MAP[$termux_arch]}"
    local proot_dst="$JNI_DIR/$abi/libproot.so"
    local loader_dst="$JNI_DIR/$abi/libproot-loader.so"

    if [ -f "$proot_dst" ] && [ -s "$proot_dst" ] \
    && [ -f "$loader_dst" ] && [ -s "$loader_dst" ]; then
        echo "[proot/$termux_arch] Đã tồn tại (kèm loader), bỏ qua"
        return 0
    fi

    local filename
    filename="$(termux_deb_url "$termux_arch" "proot")"
    [ -z "$filename" ] && { echo "!! proot không tìm thấy cho $termux_arch" >&2; return 1; }

    local deb_url="https://packages.termux.dev/apt/termux-main/${filename}"
    local deb_path="$WORK_DIR/proot-${termux_arch}.deb"
    echo "[proot/$termux_arch] Tải từ $deb_url"
    curl -fsSL "$deb_url" -o "$deb_path"

    local extract_dir="$WORK_DIR/proot-${termux_arch}-extracted"
    termux_extract_deb "$deb_path" "$extract_dir"

    # proot binary
    local src="$extract_dir/data/data/com.termux/files/usr/bin/proot"
    [ -f "$src" ] || { echo "!! Không thấy proot binary" >&2; return 1; }
    cp -f "$src" "$proot_dst"
    chmod 755 "$proot_dst"
    echo "OK: $proot_dst ($(du -h "$proot_dst" | cut -f1))"

    # loader — bắt buộc, xử lý musl ELF interpreter mà Android không có
    local loader_src="$extract_dir/data/data/com.termux/files/usr/libexec/proot/loader"
    [ -f "$loader_src" ] || { echo "!! Không thấy loader tại $loader_src" >&2; return 1; }
    cp -f "$loader_src" "$loader_dst"
    chmod 755 "$loader_dst"
    echo "OK: $loader_dst ($(du -h "$loader_dst" | cut -f1))"

    # loader32 — tùy chọn, chỉ cần cho process 32-bit bên trong rootfs
    local loader32_src="$extract_dir/data/data/com.termux/files/usr/libexec/proot/loader32"
    local loader32_dst="$JNI_DIR/$abi/libproot-loader32.so"
    if [ -f "$loader32_src" ]; then
        cp -f "$loader32_src" "$loader32_dst"
        chmod 755 "$loader32_dst"
        echo "OK: $loader32_dst ($(du -h "$loader32_dst" | cut -f1))"
    else
        echo "[proot/$termux_arch] loader32 không có trong gói (bỏ qua, ok nếu rootfs thuần 64-bit)"
    fi
}

# ---- libtalloc (dependency bắt buộc của proot) ----

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
    [ -z "$filename" ] && { echo "!! libtalloc không tìm thấy" >&2; return 1; }

    local deb_url="https://packages.termux.dev/apt/termux-main/${filename}"
    local deb_path="$WORK_DIR/libtalloc-${termux_arch}.deb"
    echo "[libtalloc/$termux_arch] Tải từ $deb_url"
    curl -fsSL "$deb_url" -o "$deb_path"

    local extract_dir="$WORK_DIR/libtalloc-${termux_arch}-extracted"
    termux_extract_deb "$deb_path" "$extract_dir"

    local src
    src="$(find "$extract_dir/data/data/com.termux/files/usr/lib" \
        -name 'libtalloc.so*' -type f | head -n1)"
    [ -z "$src" ] && { echo "!! libtalloc.so không tìm thấy trong gói" >&2; return 1; }
    cp -f "$src" "$target_file"
    chmod 755 "$target_file"
    echo "OK: $target_file ($(du -h "$target_file" | cut -f1))"
}

# ---- libandroid-shmem (cho Xvfb/X11 ở chế độ GUI) ----

fetch_libandroid_shmem() {
    local termux_arch="$1"
    local abi="${ARCH_MAP[$termux_arch]}"
    local target_file="$JNI_DIR/$abi/libandroid-shmem.so"

    if [ -f "$target_file" ] && [ -s "$target_file" ]; then
        echo "[libandroid-shmem/$termux_arch] Đã tồn tại, bỏ qua"
        return 0
    fi

    local filename
    filename="$(termux_deb_url "$termux_arch" "libandroid-shmem")"
    [ -z "$filename" ] && { echo "!! libandroid-shmem không tìm thấy" >&2; return 1; }

    local deb_url="https://packages.termux.dev/apt/termux-main/${filename}"
    local deb_path="$WORK_DIR/libandroid-shmem-${termux_arch}.deb"
    echo "[libandroid-shmem/$termux_arch] Tải từ $deb_url"
    curl -fsSL "$deb_url" -o "$deb_path"

    local extract_dir="$WORK_DIR/libandroid-shmem-${termux_arch}-extracted"
    termux_extract_deb "$deb_path" "$extract_dir"

    local src
    src="$(find "$extract_dir/data/data/com.termux/files/usr/lib" \
        -name 'libandroid-shmem.so*' -type f | head -n1)"
    [ -z "$src" ] && { echo "!! libandroid-shmem.so không tìm thấy trong gói" >&2; return 1; }
    cp -f "$src" "$target_file"
    chmod 755 "$target_file"
    echo "OK: $target_file ($(du -h "$target_file" | cut -f1))"
}

# ---- NEEDED đệ quy ----

SYSTEM_LIBS=("libc.so" "libdl.so" "libm.so" "libpthread.so" "librt.so"
             "libresolv.so" "libutil.so" "libc++_shared.so" "liblog.so"
             "libz.so" "libstdc++.so")

is_system_lib() {
    local lib="$1"
    for sys in "${SYSTEM_LIBS[@]}"; do
        [[ "$lib" == "$sys" ]] && return 0
    done
    return 1
}

fetch_library_by_name() {
    local termux_arch="$1" lib_name="$2"
    local abi="${ARCH_MAP[$termux_arch]}"
    local target_file="$JNI_DIR/$abi/$lib_name"

    [ -f "$target_file" ] && [ -s "$target_file" ] && return 0

    local pkg_name="${lib_name%.so}"
    pkg_name="${pkg_name#lib}"
    case "$pkg_name" in
        android-shmem) pkg_name="libandroid-shmem" ;;
        talloc)        pkg_name="libtalloc" ;;
        *)             pkg_name="lib$pkg_name" ;;
    esac

    echo "[fetch] $pkg_name -> $lib_name ($termux_arch)"
    local filename
    filename="$(termux_deb_url "$termux_arch" "$pkg_name")" || return 1
    [ -z "$filename" ] && return 1

    local deb_url="https://packages.termux.dev/apt/termux-main/${filename}"
    local deb_path="$WORK_DIR/${pkg_name}-${termux_arch}.deb"
    curl -fsSL "$deb_url" -o "$deb_path" || return 1

    local extract_dir="$WORK_DIR/${pkg_name}-${termux_arch}-extracted"
    termux_extract_deb "$deb_path" "$extract_dir"

    local src
    src="$(find "$extract_dir/data/data/com.termux/files/usr/lib" \
        -name "${lib_name}*" -type f | head -n1)"
    [ -z "$src" ] && return 1
    cp -f "$src" "$target_file"
    chmod 755 "$target_file"
    echo "OK: $target_file ($(du -h "$target_file" | cut -f1))"
}

patch_all_libs() {
    local abi="$1"
    for so in "$JNI_DIR/$abi"/*.so; do
        [ -f "$so" ] || continue
        echo "[patch] $so"
        patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true
        local needed
        needed="$(patchelf --print-needed "$so" 2>/dev/null || true)"
        for lib in $needed; do
            is_system_lib "$lib" && continue
            if [[ "$lib" =~ \.so\.[0-9]+$ ]]; then
                local new="${lib%%.so*}.so"
                echo "  NEEDED: $lib -> $new"
                patchelf --replace-needed "$lib" "$new" "$so"
            fi
        done
    done
}

# ---- Main ----

echo "=== Tải proot (+ loader), libtalloc, libandroid-shmem ==="
for termux_arch in aarch64 arm; do
    fetch_proot            "$termux_arch" || exit 1
    fetch_libtalloc        "$termux_arch" || exit 1
    fetch_libandroid_shmem "$termux_arch" || exit 1
done

echo "=== Phân tích NEEDED đệ quy ==="
for ((iter=0; iter<10; iter++)); do
    changed=0
    for abi in arm64-v8a armeabi-v7a; do
        for so in "$JNI_DIR/$abi"/*.so; do
            [ -f "$so" ] || continue
            needed="$(patchelf --print-needed "$so" 2>/dev/null || true)"
            for lib in $needed; do
                is_system_lib "$lib" && continue
                base="${lib%%.so*}.so"
                target="$JNI_DIR/$abi/$base"
                [ -f "$target" ] && [ -s "$target" ] && continue
                tarch="$(abi_to_termux_arch "$abi")"
                [ -z "$tarch" ] && continue
                fetch_library_by_name "$tarch" "$base" && changed=1 || true
            done
        done
    done
    [ $changed -eq 0 ] && { echo "Không còn NEEDED mới, dừng."; break; }
done

echo "=== Patch RPATH + NEEDED ==="
for abi in arm64-v8a armeabi-v7a; do patch_all_libs "$abi"; done

echo "=== Kiểm tra ELF ==="
all_ok=true
for f in "$JNI_DIR"/*/*.so; do
    [ -f "$f" ] || continue
    if ! head -c4 "$f" | grep -q $'\x7fELF'; then
        echo "!! $f không phải ELF" >&2; all_ok=false
    else
        echo "OK: $f ($(du -h "$f" | cut -f1))"
    fi
done
$all_ok || exit 1

rm -rf "$WORK_DIR"
echo "=== Hoàn tất ==="