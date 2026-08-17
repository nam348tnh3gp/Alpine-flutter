#!/bin/bash
# Tự động tải proot, busybox và các thư viện phụ thuộc từ Termux repo.
# Chạy trong GitHub Actions.
# Các binary được đặt vào jniLibs/<abi>/lib*.so để lách W^X.

set -euo pipefail

JNI_DIR="android/app/src/main/jniLibs"
WORK_DIR="$(mktemp -d)"
mkdir -p "$JNI_DIR/arm64-v8a" "$JNI_DIR/armeabi-v7a"

REPO_BASE="https://packages.termux.dev/apt/termux-main/dists/stable/main"

# Map Termux arch -> Android ABI
declare -A ARCH_MAP=( ["aarch64"]="arm64-v8a" ["arm"]="armeabi-v7a" )

# Danh sách package cần tải: mỗi entry: "pkg_name:binary_path:target_name"
# target_name sẽ là tên file trong jniLibs (thường là lib*.so)
PACKAGES=(
    "proot:bin/proot:libproot.so"
    "busybox:bin/busybox:libbusybox.so"
    "libtalloc:lib/libtalloc.so.2:libtalloc.so"
    # Có thể thêm libpcre, libutil nếu cần
)

# Hàm lấy URL của .deb từ Packages index
termux_deb_url() {
    local termux_arch="$1" pkg_name="$2"
    local idx="$WORK_DIR/Packages-$termux_arch"
    if [ ! -f "$idx" ]; then
        # Thử tải Packages (không nén) trước, nếu fail thì lấy gz
        curl -fsSL "$REPO_BASE/binary-$termux_arch/Packages" -o "$idx" 2>/dev/null || {
            curl -fsSL "$REPO_BASE/binary-$termux_arch/Packages.gz" | gunzip > "$idx"
        }
    fi
    awk -v pkg="$pkg_name" '
        /^Package: / { p = $2 }
        p == pkg && /^Filename: / { print $2; exit }
    ' "$idx"
}

# Tải và trích xuất một package
fetch_termux_pkg() {
    local termux_arch="$1" pkg_name="$2" bin_path="$3" out_so="$4"
    local abi="${ARCH_MAP[$termux_arch]}"
    local target_file="$JNI_DIR/$abi/$out_so"

    # Kiểm tra nếu file đã tồn tại và có kích thước > 0 → bỏ qua (tùy chọn)
    # Nếu muốn luôn tải mới, comment đoạn này
    if [ -f "$target_file" ] && [ -s "$target_file" ]; then
        echo "[$pkg_name/$termux_arch] Đã tồn tại, bỏ qua tải lại ($target_file)"
        return 0
    fi

    local filename
    filename="$(termux_deb_url "$termux_arch" "$pkg_name")"
    if [ -z "$filename" ]; then
        echo "!! Không tìm thấy package '$pkg_name' cho arch '$termux_arch'." >&2
        exit 1
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

    local src="$extract_dir/data/data/com.termux/files/usr/$bin_path"
    if [ ! -f "$src" ]; then
        echo "!! Không tìm thấy file $bin_path trong package $pkg_name." >&2
        exit 1
    fi

    cp -f "$src" "$target_file"
    chmod 755 "$target_file"
    echo "OK: $target_file ($(du -h "$target_file" | cut -f1))"
}

# Lặp qua từng arch
for termux_arch in aarch64 arm; do
    for pkg_entry in "${PACKAGES[@]}"; do
        IFS=':' read -r pkg_name bin_path out_so <<< "$pkg_entry"
        fetch_termux_pkg "$termux_arch" "$pkg_name" "$bin_path" "$out_so"
    done
done

# Kiểm tra ELF hợp lệ
echo "Kiểm tra file ELF..."
for f in "$JNI_DIR"/arm64-v8a/*.so "$JNI_DIR"/armeabi-v7a/*.so; do
    if [ -f "$f" ] && ! head -c4 "$f" | grep -q $'\x7fELF'; then
        echo "!! CẢNH BÁO: $f không phải ELF hợp lệ." >&2
        exit 1
    fi
    [ -f "$f" ] && echo "OK: $f ($(du -h "$f" | cut -f1))"
done

rm -rf "$WORK_DIR"
echo "Hoàn tất tải và chuẩn bị native binaries."