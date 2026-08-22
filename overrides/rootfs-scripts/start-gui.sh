#!/bin/sh
# Chạy BÊN TRONG proot (Alpine). Được copy vào rootfs lúc bootstrap
# (xem lib/services/proot_service.dart -> nên copy file này vào
#  <rootfs>/usr/local/bin/start-gui.sh trong bước bootstrap, hoặc
#  cài qua apk add xvfb-run x11vnc lần đầu, tuỳ bạn chọn).
set -e

export DISPLAY=:1

# Cài gói cần thiết (chỉ chạy lần đầu, apk cache lại các lần sau)
if ! command -v Xvfb >/dev/null 2>&1; then
    apk update
    apk add --no-cache xvfb x11vnc icewm dbus xterm ttf-dejavu
fi

# Dọn socket X cũ nếu có (tránh proot đổi PID mỗi lần chạy)
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

echo "[*] Khởi động Xvfb :1 ..."
Xvfb :1 -screen 0 1280x720x24 -nolisten tcp &
XVFB_PID=$!
sleep 2

echo "[*] Khởi động window manager (icewm) ..."
icewm-session &
sleep 1

echo "[*] Khởi động x11vnc trên cổng 5900 (chỉ localhost) ..."
# FIX: thêm -noshm để tránh lỗi shmget trong proot
x11vnc -display :1 -nopw -forever -shared -localhost -rfbport 5900 -noshm -xkb

# Giữ shell sống (để proot không exit)
wait