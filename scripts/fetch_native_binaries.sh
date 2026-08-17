#!/bin/bash
# fetch_native_binaries.sh
# Tự động tải proot, busybox và toàn bộ thư viện phụ thuộc từ Termux repo.
# Các binary được đặt vào jniLibs/<abi>/lib*.so để Android có thể load.

set -euo pipefail

JNI_DIR="android/app/src/main/jniLibs"
WORK_DIR="$(mktemp -d)"
mkdir -p "$JNI_DIR/arm64-v8a" "$JNI_DIR/armeabi-v7a"

REPO_BASE="https://packages.termux.dev/apt/termux-main/dists/stable/main"

# Map Termux arch -> Android ABI
declare -A ARCH_MAP=( ["aarch64"]="arm64-v8a" ["arm"]="armeabi-v7a" )

# Các thư viện hệ thống của Android (không cần tải)
SYSTEM_LIBS=("libc.so" "libdl.so" "libm.so" "liblog.so" "libz.so"
             "libandroid.so" "libc++_shared.so" "libstdc++.so" "libOpenSLES.so")

# Danh sách package cần tải ban đầu
INITIAL_PACKAGES=(
    "proot:bin/proot:libproot.so"
    "busybox:bin/busybox:libbusybox.so"
    "libtalloc:lib/libtalloc.so.2:libtalloc.so"
)

# ---------- Hàm tiện ích ----------
termux_deb_url() {
    local termux_arch="$1" pkg_name="$2"
    local idx="$WORK_DIR/Packages-$termux_arch"
    if [ ! -f "$idx" ]; then
        curl -fsSL "$REPO_BASE/binary-$termux_arch/Packages" -o "$idx" 2>/dev/null || {
            curl -fsSL "$REPO_BASE/binary-$termux_arch/Packages.gz" | gunzip > "$idx"
        }
    fi
    awk -v pkg="$pkg_name" '
        /^Package: / { p = $2 }
        p == pkg && /^Filename: / { print $2; exit }
    ' "$idx"
}

# Tải và trích xuất một package, trả về đường dẫn file đã giải nén
fetch_package_file() {
    local termux_arch="$1" pkg_name="$2" file_path_in_pkg="$3"
    local abi="${ARCH_MAP[$termux_arch]}"
    local target_dir="$JNI_DIR/$abi"
    local target_name="$(basename "$file_path_in_pkg")"
    # Đổi tên .so.xyz -> .so nếu cần
    if [[ "$target_name" =~ ^(.*)\.so\.[0-9]+$ ]]; then
        target_name="${BASH_REMATCH[1]}.so"
    fi
    local target_file="$target_dir/$target_name"

    # Kiểm tra nếu đã có file với cùng tên .so (có thể bỏ qua)
    if [ -f "$target_file" ] && [ -s "$target_file" ]; then
        echo "$target_file"
        return 0
    fi

    local filename
    filename="$(termux_deb_url "$termux_arch" "$pkg_name")"
    if [ -z "$filename" ]; then
        echo "!! Không tìm thấy package '$pkg_name' cho arch '$termux_arch'." >&2
        return 1
    fi

    local deb_url="https://packages.termux.dev/apt/termux-main/${filename}"
    local deb_path="$WORK_DIR/${pkg_name}-${termux_arch}.deb"
    echo "[$pkg_name/$termux_arch] Tải từ $deb_url"
    curl -fsSL "$deb_url" -o "$deb_path"

    local extract_dir="$WORK_DIR/${pkg_name}-${termux_arch}-extracted"
    mkdir -p "$extract_dir"
    ( cd "$extract_dir" && ar x "$deb_path" )
    local data_tar
    data_tar="$(ls "$extract_dir"/data.tar.* | head -n1)"
    tar -xf "$data_tar" -C "$extract_dir"

    local src="$extract_dir/data/data/com.termux/files/usr/$file_path_in_pkg"
    if [ ! -f "$src" ]; then
        echo "!! Không tìm thấy file $file_path_in_pkg trong package $pkg_name." >&2
        return 1
    fi

    cp -f "$src" "$target_file"
    chmod 755 "$target_file"
    echo "OK: $target_file ($(du -h "$target_file" | cut -f1))"
    echo "$target_file"
}

# Lấy danh sách NEEDED của một file ELF
get_needed_libs() {
    local file="$1"
    readelf -d "$file" 2>/dev/null | grep NEEDED | sed -E 's/.*\[(.*)\]/\1/'
}

# Kiểm tra xem một thư viện có phải hệ thống không
is_system_lib() {
    local lib="$1"
    for sys in "${SYSTEM_LIBS[@]}"; do
        if [ "$lib" = "$sys" ]; then
            return 0
        fi
    done
    return 1
}

# Xác định package chứa một thư viện (bằng cách suy đoán)
resolve_package_for_lib() {
    local lib_name="$1"
    # Loại bỏ phần .so.* để lấy tên cơ bản
    local base="${lib_name%%.so*}"        # ví dụ libtalloc
    local pkg_candidate="${base#lib}"     # talloc
    # Thử package có tên libpkg (thường gặp)
    if termux_deb_url "$termux_arch" "lib$pkg_candidate" >/dev/null 2>&1; then
        echo "lib$pkg_candidate"
        return 0
    elif termux_deb_url "$termux_arch" "$pkg_candidate" >/dev/null 2>&1; then
        echo "$pkg_candidate"
        return 0
    else
        # Một số ngoại lệ: libutil -> package libutil, libpcre -> libpcre, ...
        # Thử thêm một số ánh xạ cứng
        case "$lib_name" in
            libutil.so.*) echo "libutil" ;;
            libpcre.so.*) echo "libpcre" ;;
            libcrypto.so.*) echo "openssl" ;;
            libssl.so.*) echo "openssl" ;;
            *) echo "" ;;
        esac
    fi
}

# ---------- Bước 1: Cài patchelf (nếu chưa có) ----------
if ! command -v patchelf &>/dev/null; then
    echo "patchelf chưa có, đang cài đặt..."
    sudo apt-get update && sudo apt-get install -y patchelf
fi

# ---------- Bước 2: Tải các package ban đầu ----------
echo "=== Tải các package ban đầu ==="
for termux_arch in aarch64 arm; do
    for pkg_entry in "${INITIAL_PACKAGES[@]}"; do
        IFS=':' read -r pkg_name file_path target_name <<< "$pkg_entry"
        fetch_package_file "$termux_arch" "$pkg_name" "$file_path" || exit 1
    done
done

# ---------- Bước 3: Xử lý đệ quy các NEEDED ----------
echo "=== Xử lý các thư viện phụ thuộc ==="
# Mảng lưu các file đã được patch (tránh patch lại)
declare -A PATCHED_FILES

# Vòng lặp vô hạn, sẽ dừng khi không còn NEEDED mới
while true; do
    CHANGED=false
    # Duyệt tất cả file .so trong JNI_DIR
    for file in "$JNI_DIR"/*/*.so; do
        [ -f "$file" ] || continue
        local abi_dir="$(dirname "$file")"
        local abi="$(basename "$abi_dir")"
        local termux_arch
        for k in "${!ARCH_MAP[@]}"; do
            if [ "${ARCH_MAP[$k]}" = "$abi" ]; then
                termux_arch="$k"
                break
            fi
        done

        local needed_libs=( $(get_needed_libs "$file") )
        for need in "${needed_libs[@]}"; do
            # Bỏ qua thư viện hệ thống
            if is_system_lib "$need"; then
                continue
            fi

            # Kiểm tra xem đã có file .so nào khớp trong cùng thư mục chưa
            # Tên need có thể là libtalloc.so.2, ta so sánh với các file có tên libtalloc.so
            local base_name="${need%%.so*}"   # libtalloc
            local found_file=""
            for existing in "$abi_dir"/*.so; do
                local existing_base="${existing%%.so*}"
                if [ "$(basename "$existing_base")" = "$base_name" ]; then
                    found_file="$existing"
                    break
                fi
            done

            if [ -n "$found_file" ]; then
                # Đã có file, nhưng nếu tên NEEDED khác tên file, cần patch
                local target_name="$(basename "$found_file")"
                if [ "$need" != "$target_name" ]; then
                    # Patch file hiện tại để tham chiếu đến tên đúng
                    if [ -z "${PATCHED_FILES[$file]}" ]; then
                        echo "Patch $file: thay $need -> $target_name"
                        patchelf --replace-needed "$need" "$target_name" "$file"
                        PATCHED_FILES["$file"]=1
                    fi
                fi
                continue
            fi

            # Chưa có, cần tải package chứa thư viện này
            echo "Cần tải thư viện: $need"
            local pkg_name
            pkg_name="$(resolve_package_for_lib "$need")"
            if [ -z "$pkg_name" ]; then
                echo "!! Không xác định được package cho $need, bỏ qua." >&2
                continue
            fi

            # Xác định đường dẫn file trong package (thường là lib/ + tên thư viện)
            local file_path="lib/$need"
            local new_file
            if new_file="$(fetch_package_file "$termux_arch" "$pkg_name" "$file_path")"; then
                CHANGED=true
                # Sau khi tải xong, patch file hiện tại để tham chiếu đến tên mới (nếu khác)
                local new_name="$(basename "$new_file")"
                if [ "$need" != "$new_name" ]; then
                    if [ -z "${PATCHED_FILES[$file]}" ]; then
                        echo "Patch $file: thay $need -> $new_name"
                        patchelf --replace-needed "$need" "$new_name" "$file"
                        PATCHED_FILES["$file"]=1
                    fi
                fi
            else
                echo "!! Không tải được package $pkg_name cho $need." >&2
            fi
        done
    done

    # Nếu không có thay đổi mới, thoát vòng lặp
    if [ "$CHANGED" = false ]; then
        break
    fi
done

# ---------- Bước 4: Kiểm tra ELF hợp lệ ----------
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