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

echo "=== Tải libandroid-shmem từ Termux ==="
for termux_arch in aarch64 arm; do
    fetch_libandroid_shmem "$termux_arch" || exit 1
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

echo "=== Quét đệ quy NEEDED của TẤT CẢ file .so đã tải (không chỉ libproot) ==="
# Cho tới lúc này mới chỉ biết libproot.so cần libtalloc.so + libandroid-shmem.so.
# Nhưng bản thân libtalloc.so / libandroid-shmem.so có thể lại cần thêm lib
# khác (đệ quy nhiều tầng). Bước này quét NEEDED của MỌI file .so hiện có
# trong jniLibs, lặp lại nhiều lượt cho tới khi không phát sinh thêm gì mới.

# Thư viện chắc chắn có sẵn trên mọi Android (Bionic hệ thống) - không cần bundle.
SYSTEM_LIBS_WHITELIST=" libc.so libm.so libdl.so liblog.so "

# Map: tên .so được NEEDED tới -> tên package Termux cung cấp nó.
# Mở rộng bảng này nếu log báo "CẢNH BÁO" phát hiện lib lạ chưa map.
declare -A SO_TO_TERMUX_PKG=(
    ["libtalloc.so"]="libtalloc"
    ["libandroid-shmem.so"]="libandroid-shmem"
)

# Tải 1 package Termux tổng quát, tìm bất kỳ file .so nào khớp $so_glob bên
# trong, copy ra $target_name, rồi patch lại NEEDED trên MỌI file .so khác
# trong cùng abi có tham chiếu tên cũ (có version) sang tên mới.
fetch_termux_lib_generic() {
    local termux_arch="$1" pkg_name="$2" so_glob="$3" abi="$4" target_name="$5"
    local target_file="$JNI_DIR/$abi/$target_name"

    local filename
    filename="$(termux_deb_url "$termux_arch" "$pkg_name")"
    if [ -z "$filename" ]; then
        echo "!! Không tìm thấy package Termux '$pkg_name' cho '$termux_arch'." >&2
        return 1
    fi

    local deb_url="https://packages.termux.dev/apt/termux-main/${filename}"
    local deb_path="$WORK_DIR/${pkg_name}-${termux_arch}.deb"
    echo "[transitive/$abi] Tải '$pkg_name' <- $deb_url"
    curl -fsSL "$deb_url" -o "$deb_path"

    local extract_dir="$WORK_DIR/${pkg_name}-${termux_arch}-extracted"
    termux_extract_deb "$deb_path" "$extract_dir"

    local src
    src="$(find "$extract_dir/data/data/com.termux/files/usr/lib" -iname "$so_glob" -type f | head -n1)"
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        echo "!! Gói '$pkg_name' không chứa file khớp '$so_glob'." >&2
        return 1
    fi

    cp -f "$src" "$target_file"
    chmod 755 "$target_file"
    echo "OK: $target_file ($(du -h "$target_file" | cut -f1))"

    # Nếu tên file gốc trong gói có version (vd libfoo.so.3) khác với
    # target_name (vd libfoo.so), sửa lại NEEDED trên mọi consumer khác.
    local real_soname
    real_soname="$(patchelf --print-soname "$target_file" 2>/dev/null || basename "$src")"
    if [ -n "$real_soname" ] && [ "$real_soname" != "$target_name" ]; then
        for consumer in "$JNI_DIR/$abi"/*.so; do
            [ -f "$consumer" ] || continue
            if patchelf --print-needed "$consumer" 2>/dev/null | grep -qx "$real_soname"; then
                echo "[transitive/$abi] Đổi NEEDED trong $(basename "$consumer"): '$real_soname' -> '$target_name'"
                patchelf --replace-needed "$real_soname" "$target_name" "$consumer"
            fi
        done
    fi
}

resolve_transitive_needed() {
    local abi="$1" termux_arch="$2"
    local pass=0 changed=1
    while [ "$changed" -eq 1 ] && [ "$pass" -lt 6 ]; do
        changed=0
        pass=$((pass + 1))
        echo "[transitive/$abi] --- lượt quét $pass ---"
        for f in "$JNI_DIR/$abi"/*.so; do
            [ -f "$f" ] || continue
            local needed_list
            needed_list="$(patchelf --print-needed "$f" 2>/dev/null || true)"
            while IFS= read -r needed; do
                [ -z "$needed" ] && continue
                case "$SYSTEM_LIBS_WHITELIST" in
                    *" $needed "*) continue ;;
                esac
                if [ -f "$JNI_DIR/$abi/$needed" ]; then
                    continue
                fi
                local pkg="${SO_TO_TERMUX_PKG[$needed]:-}"
                if [ -n "$pkg" ]; then
                    echo "[transitive/$abi] $(basename "$f") cần '$needed' (chưa có) -> tải qua package '$pkg'"
                    fetch_termux_lib_generic "$termux_arch" "$pkg" "${needed%.so*}*.so*" "$abi" "$needed" \
                        && changed=1
                else
                    echo "!! CẢNH BÁO [transitive/$abi]: $(basename "$f") cần '$needed' nhưng KHÔNG có trong bảng SO_TO_TERMUX_PKG." >&2
                    echo "   -> Chưa tự tải được. Nếu proot/lib liên quan crash lúc chạy với lỗi" >&2
                    echo "      'cannot open shared object file: $needed', hãy thêm mapping cho nó" >&2
                    echo "      vào SO_TO_TERMUX_PKG trong scripts/fetch_native_binaries.sh" >&2
                fi
            done <<< "$needed_list"
        done
    done
    if [ "$pass" -ge 6 ] && [ "$changed" -eq 1 ]; then
        echo "!! CẢNH BÁO [transitive/$abi]: quét đủ 6 lượt vẫn còn thay đổi - có thể có vòng lặp phụ thuộc bất thường, kiểm tra thủ công." >&2
    fi
}

resolve_transitive_needed "arm64-v8a" "aarch64"
resolve_transitive_needed "armeabi-v7a" "arm"

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
