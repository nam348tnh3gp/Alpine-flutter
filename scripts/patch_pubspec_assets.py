#!/usr/bin/env python3
"""Thêm assets/rootfs-scripts/start-gui.sh vào pubspec.yaml nếu chưa có.
Gọi từ workflow: python3 scripts/patch_pubspec_assets.py build_workspace/pubspec.yaml
"""
import sys

def main():
    if len(sys.argv) != 2:
        print("Usage: patch_pubspec_assets.py <path-to-pubspec.yaml>", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    marker = "assets/rootfs-scripts/"
    if marker in content:
        print("pubspec.yaml đã có asset, bỏ qua.")
        return

    target = "flutter:\n  uses-material-design: true\n"
    replacement = (
        "flutter:\n"
        "  uses-material-design: true\n"
        "  assets:\n"
        "    - assets/rootfs-scripts/start-gui.sh\n"
    )

    if target in content:
        content = content.replace(target, replacement)
    else:
        # Fallback: nếu block flutter: khác định dạng mặc định, append an toàn
        content += "\n  assets:\n    - assets/rootfs-scripts/start-gui.sh\n"

    with open(path, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"Đã thêm asset vào {path}")

if __name__ == "__main__":
    main()
