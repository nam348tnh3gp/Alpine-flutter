#!/bin/bash
# Chạy trong GitHub Actions. Tải proot + busybox từ TERMUX PACKAGE REPO
# (dạng .deb), giải nén lấy binary, đặt vào jniLibs/<abi>/lib*.so để lách
# W^X (hệ thống Android tự cấp quyền exec khi extract vào nativeLibraryDir).
#
# LƯU Ý QUAN TRỌNG: binary Termux được build với RUNPATH trỏ tới
# /data/data/com.termux/files/usr/lib. Nếu proot log lỗi "cannot open
# shared object file" khi chạy trong app của bạn, cần patchelf lại RUNPATH
# hoặc set LD_LIBRARY_PATH trỏ tới thư mục chứa libtalloc.so đi kèm.

set -euo pipefail

JNI_DIR="android/app/src/main/jniLibs"
WORK_DIR="$(mktemp -d)"
mkdir -p "$JNI_DIR/arm64-v8a" "$JNI_DIR/armeabi-v7a"

REPO_BASE="https://packages.termux.dev/apt/termux-main/dists/stable/main"

# arch Termux -> abi Android
declare -A ARCH_MAP=( ["aarch64"]="arm64-v8a" ["arm"]="armeabi-v7a" )

# Lấy Filename (.deb) mới nhất của 1 package từ Packages index của Termux repo
termux_deb_url() {
    local termux_arch="$1" pkg_name="$2"
    local idx="$WORK_DIR/Packages-$termux_arch"
    if [ ! -f "$idx" ]; then
        curl -fsSL "$REPO_BASE/binary-$termux_arch/Packages" -o "$idx" \
            || curl -fsSL "$REPO_BASE/binary-$termux_arch/Packages.gz" | gunzip > "$idx"
    fi
    awk -v pkg="$pkg_name" '
        /^Package: / { p = $2 }
        p == pkg && /^Filename: / { print $2; exit }
    ' "$idx"
}

# Tải .deb, giải nén data.tar.* (không cần dpkg-deb), copy binary ra jniLibs
fetch_termux_pkg() {
    local termux_arch="$1" pkg_name="$2" bin_path="$3" out_so="$4"
    local abi="${ARCH_MAP[$termux_arch]}"

    local filename
    filename="$(termux_deb_url "$termux_arch" "$pkg_name")"
    if [ -z "$filename" ]; then
        echo "!! Không tìm thấy package '$pkg_name' cho arch '$termux_arch' trong Termux repo." >&2
        exit 1
    fi

    local deb_url="$REPO_BASE/../../../$filename"   # Filename đã là path tương đối từ dists/../..
    deb_url="https://packages.termux.dev/apt/termux-main/${filename}"

    local deb_path="$WORK_DIR/${pkg_name}-${termux_arch}.deb"
    echo "[$pkg_name/$termux_arch] <- $deb_url"
    curl -fsSL "$deb_url" -o "$deb_path"

    local extract_dir="$WORK_DIR/${pkg_name}-${termux_arch}-extracted"
    mkdir -p "$extract_dir"
    ( cd "$extract_dir" && ar x "$deb_path" )
    local data_tar
    data_tar="$(ls "$extract_dir"/data.tar.* | head -n1)"
    tar -xf "$data_tar" -C "$extract_dir"

    local src="$extract_dir/data/data/com.termux/files/usr/$bin_path"
    if [ ! -f "$src" ]; then
        echo "!! Không thấy binary tại $src sau khi giải nén $pkg_name." >&2
        exit 1
    fi

    cp -f "$src" "$JNI_DIR/$abi/$out_so"
    chmod 755 "$JNI_DIR/$abi/$out_so"
}

for termux_arch in aarch64 arm; do
    fetch_termux_pkg "$termux_arch" "proot"   "bin/proot"    "libproot.so"
    fetch_termux_pkg "$termux_arch" "busybox" "bin/busybox"  "libbusybox.so"
done

# Kiểm tra ELF hợp lệ
for f in "$JNI_DIR"/arm64-v8a/*.so "$JNI_DIR"/armeabi-v7a/*.so; do
    if ! head -c4 "$f" | grep -q $'\x7fELF'; then
        echo "!! CẢNH BÁO: $f không phải file ELF hợp lệ." >&2
        exit 1
    fi
    echo "OK: $f ($(du -h "$f" | cut -f1))"
done

rm -rf "$WORK_DIR"
echo "Hoàn tất tải native binaries từ Termux repo."
