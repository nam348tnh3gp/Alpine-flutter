import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';
import '../services/proot_service.dart';

enum RunMode { cli, gui }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final PRootService _proot;
  final Terminal _terminal = Terminal(maxLines: 5000);
  final FocusNode _terminalFocusNode = FocusNode();
  bool _installed = false;
  bool _installing = false;
  double _progress = 0;
  RunMode? _mode;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _proot = PRootService(
      onLog: (l) => _terminal.write('$l\r\n'),
      onProcessExited: () {
        // Khi process kết thúc, reset mode để hiển thị lại nút chọn
        if (mounted) {
          setState(() {
            _running = false;
            _mode = null;
          });
        }
      },
    );
    _checkInstalled();

    // Nhận input từ bàn phím và gửi xuống PTY
    _terminal.onOutput = (data) {
      _proot.sendInput(data);
    };

    // Khi terminal thay đổi kích thước, gửi sang PTY
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _proot.resizeTerminal(width, height);
    };
  }

  @override
  void dispose() {
    // Dừng tiến trình nếu còn chạy
    _proot.stop();
    _terminalFocusNode.dispose();
    super.dispose();
  }

  Future<void> _checkInstalled() async {
    final ok = await _proot.isInstalled();
    setState(() => _installed = ok);
  }

  Future<void> _ensureInstalled() async {
    if (_installed) return;
    setState(() => _installing = true);
    try {
      await _proot.bootstrap(onProgress: (p) => setState(() => _progress = p));
      setState(() => _installed = true);
    } catch (e) {
      _terminal.write('❌ LỖI cài đặt: $e\r\n');
    } finally {
      setState(() => _installing = false);
    }
  }

  Future<void> _copyLog() async {
    final logs = _proot.getLogs();
    if (logs.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: logs));
      _terminal.write('\r\n📋 Đã copy log vào clipboard!\r\n');
    } else {
      _terminal.write('\r\n⚠️ Không có log để copy.\r\n');
    }
  }

  void _clearLog() {
    _proot.clearLogs();
    _terminal.write('\r\n🗑️ Đã xóa log.\r\n');
  }

  Future<void> _launchCli() async {
    setState(() {
      _mode = RunMode.cli;
      _running = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).requestFocus(_terminalFocusNode);
    });
    try {
      await _proot.start(
        command: ['/bin/sh', '-l'],
        onStdout: (s) => _terminal.write(s),
        onStderr: (s) => _terminal.write(s),
        rows: _terminal.viewHeight,  // Truyền kích thước thực tế
        cols: _terminal.viewWidth,   // Truyền kích thước thực tế
      );
    } catch (e) {
      _terminal.write('❌ LỖI khởi chạy: $e\r\n');
      setState(() {
        _running = false;
        _mode = null;
      });
    }
  }

  Future<void> _launchGui() async {
    setState(() {
      _mode = RunMode.gui;
      _running = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).requestFocus(_terminalFocusNode);
    });
    try {
      // start() sẽ trả về khi process kết thúc, nhưng GUI cần chạy lâu dài.
      // Vì thế ta chạy start trong một future riêng, và chờ VNC sau 2s.
      final processFuture = _proot.start(
        command: ['/bin/sh', '/usr/local/bin/start-gui.sh'],
        onStdout: (s) => _terminal.write(s),
        onStderr: (s) => _terminal.write(s),
        rows: _terminal.viewHeight,  // Truyền kích thước thực tế
        cols: _terminal.viewWidth,   // Truyền kích thước thực tế
      );
      // Chờ 2 giây để VNC server khởi động
      await Future.delayed(const Duration(seconds: 2));
      await _openRealVnc();
      // Bây giờ chờ process kết thúc (nếu có lỗi, UI sẽ hiển thị)
      await processFuture;
    } catch (e) {
      _terminal.write('❌ LỖI khởi chạy GUI: $e\r\n');
      setState(() {
        _running = false;
        _mode = null;
      });
    }
  }

  Future<void> _openRealVnc() async {
    final uri = Uri.parse('vnc://127.0.0.1:5900');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _terminal.write(
          '\r\n📱 Không mở được RealVNC Viewer. Hãy cài app "RealVNC Viewer" '
          'từ Play Store rồi kết nối thủ công tới 127.0.0.1:5900\r\n');
    }
  }

  /// Dừng tiến trình đang chạy (nếu có)
  void _stopProcess() {
    _proot.stop();
    setState(() {
      _running = false;
      _mode = null;
    });
    _terminal.write('\r\n🛑 Đã yêu cầu dừng tiến trình.\r\n');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alpine Runner (proot, no root)'),
        actions: [
          // Nút Stop luôn hiện khi đang chạy
          if (_running)
            IconButton(
              icon: const Icon(Icons.stop),
              onPressed: _stopProcess,
              tooltip: 'Dừng tiến trình',
            ),
          // Nút Copy Log luôn bấm được (không phụ thuộc _running)
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: _copyLog,
            tooltip: 'Copy log',
          ),
          // Nút Clear Log luôn bấm được
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: _clearLog,
            tooltip: 'Clear log',
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_installed) _buildInstallPanel(),
          // Chỉ hiển thị nút chọn mode khi đã cài và chưa chạy
          if (_installed && _mode == null && !_running) _buildModePicker(),
          // Khi đang chạy, hiển thị terminal
          if (_running)
            Expanded(
              child: TerminalView(
                _terminal,
                focusNode: _terminalFocusNode,
                autofocus: true,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInstallPanel() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Text('📥 Chưa cài Alpine rootfs.'),
          const SizedBox(height: 12),
          if (_installing) ...[
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            const SizedBox(height: 8),
            Text('${(_progress * 100).toStringAsFixed(0)}%'),
          ] else
            FilledButton.icon(
              onPressed: _ensureInstalled,
              icon: const Icon(Icons.download),
              label: const Text('Tải & cài Alpine ngay bây giờ'),
            ),
        ],
      ),
    );
  }

  Widget _buildModePicker() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Wrap(
        spacing: 16,
        runSpacing: 16,
        alignment: WrapAlignment.center,
        children: [
          FilledButton.icon(
            onPressed: _launchCli,
            icon: const Icon(Icons.terminal),
            label: const Text('CLI'),
          ),
          FilledButton.icon(
            onPressed: _launchGui,
            icon: const Icon(Icons.desktop_windows),
            label: const Text('GUI (VNC)'),
          ),
        ],
      ),
    );
  }
}