#!/bin/bash
# Tải proot, loader, và tất cả dependencies từ Termux.
# Patch RPATH và đổi tên NEEDED để tương thích trên Android (không version suffix).
# Chạy trong GitHub Actions.

set -euo pipefail

JNI_DIR="android/app/src/main/jniLibs"
WORK_DIR="$(mktemp -d)"
mkdir -p "$JNI_DIR/arm64-v8a" "$JNI_DIR/armeabi-v7a"

TERMUX_REPO_BASE="https://packages.termux.dev/apt/termux-main/dists/stable/main"
ALPINE_REPO_BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main"

declare -A ARCH_MAP=( ["aarch64"]="arm64-v8a" ["arm"]="armeabi-v7a" )
declare -A ALPINE_ARCH_MAP=( ["aarch64"]="aarch64" ["arm"]="armhf" )

# Hàm chuyển đổi ABI -> termux arch (ngược với ARCH_MAP)
abi_to_termux_arch() {
    case "$1" in
        arm64-v8a) echo "aarch64" ;;
        armeabi-v7a) echo "arm" ;;
        *) echo "" ;;
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

# ---- Tải các gói cơ bản ----
fetch_proot() {
    local termux_arch="$1"
    local abi="${ARCH_MAP[$termux_arch]}"
    local target_file="$JNI_DIR/$abi/libproot.so"
    local loader_check="$JNI_DIR/$abi/libproot-loader.so"

    if [ -f "$target_file" ] && [ -s "$target_file" ] && [ -f "$loader_check" ] && [ -s "$loader_check" ]; then
        echo "[proot/$termux_arch] Đã tồn tại (kèm loader), bỏ qua"
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

    # Copy proot binary
    local src="$extract_dir/data/data/com.termux/files/usr/bin/proot"
    if [ ! -f "$src" ]; then
        echo "!! Không thấy proot binary tại $src." >&2
        return 1
    fi
    cp -f "$src" "$target_file"
    chmod 755 "$target_file"
    echo "OK: $target_file ($(du -h "$target_file" | cut -f1))"

    # Copy loader
    local loader_src="$extract_dir/data/data/com.termux/files/usr/libexec/proot/loader"
    local loader_dst="$JNI_DIR/$abi/libproot-loader.so"
    if [ -f "$loader_src" ]; then
        cp -f "$loader_src" "$loader_dst"
        chmod 755 "$loader_dst"
        echo "OK: $loader_dst ($(du -h "$loader_dst" | cut -f1))"
    else
        echo "!! Không thấy loader tại $loader_src." >&2
        return 1
    fi

    # loader32 (optional)
    local loader32_src="$extract_dir/data/data/com.termux/files/usr/libexec/proot/loader32"
    local loader32_dst="$JNI_DIR/$abi/libproot-loader32.so"
    if [ -f "$loader32_src" ]; then
        cp -f "$loader32_src" "$loader32_dst"
        chmod 755 "$loader32_dst"
        echo "OK: $loader32_dst ($(du -h "$loader32_dst" | cut -f1))"
    else
        echo "!! Không thấy loader32 tại $loader32_src (bỏ qua)." >&2
    fi
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
    if [ -z "$filename" ]; then
        echo "!! Không tìm thấy libandroid-shmem cho arch '$termux_arch'." >&2
        return 1
    fi

    local deb_url="https://packages.termux.dev/apt/termux-main/${filename}"
    local deb_path="$WORK_DIR/libandroid-shmem-${termux_arch}.deb"
    echo "[libandroid-shmem/$termux_arch] Tải từ $deb_url"
    curl -fsSL "$deb_url" -o "$deb_path"

    local extract_dir="$WORK_DIR/libandroid-shmem-${termux_arch}-extracted"
    termux_extract_deb "$deb_path" "$extract_dir"

    local src
    src="$(find "$extract_dir/data/data/com.termux/files/usr/lib" -name 'libandroid-shmem.so*' -type f | head -n1)"
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        echo "!! Không tìm thấy libandroid-shmem.so* trong gói." >&2
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

# ---- Hàm phân tích NEEDED đệ quy và tải bổ sung ----
# Danh sách các thư viện hệ thống (không cần tải)
SYSTEM_LIBS=("libc.so" "libdl.so" "libm.so" "libpthread.so" "librt.so" "libresolv.so" "libutil.so" "libc++_shared.so" "liblog.so" "libz.so" "libstdc++.so")

is_system_lib() {
    local lib="$1"
    for sys in "${SYSTEM_LIBS[@]}"; do
        [[ "$lib" == "$sys" ]] && return 0
    done
    return 1
}

# Tải một thư viện từ Termux dựa trên tên file (không version)
fetch_library_by_name() {
    local termux_arch="$1"
    local lib_name="$2"   # ví dụ: libtalloc.so
    local abi="${ARCH_MAP[$termux_arch]}"
    local target_file="$JNI_DIR/$abi/$lib_name"

    # Nếu đã có thì bỏ qua
    if [ -f "$target_file" ] && [ -s "$target_file" ]; then
        return 0
    fi

    # Tìm tên gói từ tên thư viện (thường là libtalloc -> gói libtalloc)
    local pkg_name="${lib_name%.so}"   # bỏ .so
    pkg_name="${pkg_name#lib}"         # bỏ tiền tố lib
    # Một số trường hợp đặc biệt
    case "$pkg_name" in
        android-shmem) pkg_name="libandroid-shmem" ;;
        talloc) pkg_name="libtalloc" ;;
        *) pkg_name="lib$pkg_name" ;;
    esac

    echo "[fetch] Tìm gói $pkg_name cho $lib_name ($termux_arch)"

    local filename
    filename="$(termux_deb_url "$termux_arch" "$pkg_name")"
    if [ -z "$filename" ]; then
        echo "!! Không tìm thấy gói $pkg_name cho $lib_name" >&2
        return 1
    fi

    local deb_url="https://packages.termux.dev/apt/termux-main/${filename}"
    local deb_path="$WORK_DIR/${pkg_name}-${termux_arch}.deb"
    echo "[fetch] Tải $deb_url"
    curl -fsSL "$deb_url" -o "$deb_path" || return 1

    local extract_dir="$WORK_DIR/${pkg_name}-${termux_arch}-extracted"
    termux_extract_deb "$deb_path" "$extract_dir"

    local src
    src="$(find "$extract_dir/data/data/com.termux/files/usr/lib" -name "${lib_name}*" -type f | head -n1)"
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        echo "!! Không tìm thấy $lib_name trong gói." >&2
        return 1
    fi

    cp -f "$src" "$target_file"
    chmod 755 "$target_file"
    echo "OK: Đã tải $target_file ($(du -h "$target_file" | cut -f1))"
}

# Patch tất cả các file .so: đổi tên NEEDED versioned -> không version, set RPATH=$ORIGIN
patch_all_libs() {
    local abi="$1"
    local lib_dir="$JNI_DIR/$abi"

    # Tìm tất cả file .so
    for so in "$lib_dir"/*.so; do
        [ -f "$so" ] || continue

        echo "[patch] Đang xử lý $so"

        # Set RPATH=$ORIGIN nếu chưa có
        patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true

        # Lấy danh sách NEEDED
        local needed
        needed="$(patchelf --print-needed "$so" 2>/dev/null || true)"
        [ -z "$needed" ] && continue

        for lib in $needed; do
            # Nếu là thư viện hệ thống thì bỏ qua
            if is_system_lib "$lib"; then
                continue
            fi

            # Nếu tên có version suffix (ví dụ libtalloc.so.2) -> đổi thành không version
            if [[ "$lib" =~ \.so\.[0-9]+$ ]]; then
                local new_name="${lib%%.so*}.so"
                echo "[patch] Đổi NEEDED: $lib -> $new_name trong $so"
                patchelf --replace-needed "$lib" "$new_name" "$so"
            fi
        done
    done
}

# ---- Quy trình chính ----
echo "=== Tải proot, loader, libtalloc, libandroid-shmem, busybox ==="
for termux_arch in aarch64 arm; do
    fetch_proot "$termux_arch" || exit 1
    fetch_libtalloc "$termux_arch" || exit 1
    fetch_libandroid_shmem "$termux_arch" || exit 1
    fetch_busybox_alpine "$termux_arch" || exit 1
done

echo "=== Phân tích NEEDED đệ quy và tải bổ sung ==="
MAX_ITER=10
for ((iter=0; iter<MAX_ITER; iter++)); do
    changed=0
    for abi in arm64-v8a armeabi-v7a; do
        lib_dir="$JNI_DIR/$abi"
        for so in "$lib_dir"/*.so; do
            [ -f "$so" ] || continue
            needed="$(patchelf --print-needed "$so" 2>/dev/null || true)"
            for lib in $needed; do
                if is_system_lib "$lib"; then
                    continue
                fi
                # Loại bỏ version suffix nếu có để lấy tên cơ bản
                base_lib="${lib%%.so*}.so"
                # Bỏ qua nếu đã có file
                target="$lib_dir/$base_lib"
                if [ -f "$target" ] && [ -s "$target" ]; then
                    continue
                fi
                # Tải thư viện
                termux_arch="$(abi_to_termux_arch "$abi")"
                if [ -z "$termux_arch" ]; then
                    echo "!! Không xác định được termux_arch cho ABI $abi" >&2
                    continue
                fi
                if fetch_library_by_name "$termux_arch" "$base_lib"; then
                    changed=1
                else
                    echo "!! Không thể tải $base_lib cho $abi" >&2
                fi
            done
        done
    done
    if [ $changed -eq 0 ]; then
        echo "Không còn NEEDED mới, dừng vòng lặp."
        break
    fi
done

echo "=== Patch RPATH và đổi tên NEEDED cho tất cả .so ==="
for abi in arm64-v8a armeabi-v7a; do
    patch_all_libs "$abi"
done

echo "=== Kiểm tra cuối cùng ==="
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