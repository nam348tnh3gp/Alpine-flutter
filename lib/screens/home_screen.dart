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
  bool _stopping = false;

  String get _appBarTitle {
    if (!_installed) return 'Alpine Runner - Chưa cài';
    if (_installing) return 'Alpine Runner - Đang cài đặt...';
    if (_running) {
      return _mode == RunMode.cli
          ? 'Alpine Runner - CLI đang chạy'
          : 'Alpine Runner - GUI đang chạy';
    }
    return 'Alpine Runner (proot, no root)';
  }

  @override
  void initState() {
    super.initState();
    _proot = PRootService(
      onLog: (l) => _terminal.write('$l\r\n'),
      onProcessExited: () {
        if (mounted) {
          setState(() {
            _running = false;
            _mode = null;
            _stopping = false;
          });
        }
      },
    );
    _checkInstalled();

    _terminal.onOutput = (data) {
      _proot.sendInput(data);
    };

    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _proot.resizeTerminal(width, height);
    };
  }

  @override
  void dispose() {
    _proot.stop();
    _terminalFocusNode.dispose();
    super.dispose();
  }

  Future<void> _checkInstalled() async {
    final ok = await _proot.isInstalled();
    if (mounted) setState(() => _installed = ok);
  }

  Future<void> _ensureInstalled() async {
    if (_installed) return;
    setState(() => _installing = true);
    try {
      await _proot.bootstrap(onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) setState(() => _installed = true);
    } catch (e) {
      _terminal.write('❌ LỖI cài đặt: $e\r\n');
      _showErrorSnackBar('Lỗi cài đặt: $e');
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _copyLog() async {
    final logs = _proot.getLogs();
    if (logs.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: logs));
      _terminal.write('\r\n📋 Đã copy log vào clipboard!\r\n');
      _showSnackBar('📋 Đã copy log vào clipboard!');
    } else {
      _terminal.write('\r\n⚠️ Không có log để copy.\r\n');
      _showSnackBar('⚠️ Không có log để copy.');
    }
  }

  void _clearLog() {
    _proot.clearLogs();
    _terminal.write('\r\n🗑️ Đã xóa log.\r\n');
    _showSnackBar('🗑️ Đã xóa log.');
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.red)),
        backgroundColor: Colors.red.shade900,
        duration: const Duration(seconds: 3),
      ));
  }

  Future<void> _launchCli() async {
    if (_running || _stopping) return;
    setState(() {
      _mode = RunMode.cli;
      _running = true;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusScope.of(context).requestFocus(_terminalFocusNode);
    });

    // Chờ một chút để layout hoàn tất (an toàn nếu terminal chưa có kích thước)
    await Future.delayed(const Duration(milliseconds: 50));

    final rows = _terminal.viewHeight > 0 ? _terminal.viewHeight : 24;
    final cols = _terminal.viewWidth > 0 ? _terminal.viewWidth : 80;

    try {
      await _proot.start(
        command: ['/bin/sh', '-l'],
        onStdout: (s) => _terminal.write(s),
        onStderr: (s) => _terminal.write(s),
        rows: rows,
        cols: cols,
      );
    } catch (e) {
      _terminal.write('❌ LỖI khởi chạy CLI: $e\r\n');
      _showErrorSnackBar('Lỗi khởi chạy CLI: $e');
      if (mounted) {
        setState(() {
          _running = false;
          _mode = null;
        });
      }
    }
  }

  Future<void> _launchGui() async {
    if (_running || _stopping) return;
    setState(() {
      _mode = RunMode.gui;
      _running = true;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusScope.of(context).requestFocus(_terminalFocusNode);
    });

    await Future.delayed(const Duration(milliseconds: 50));

    final rows = _terminal.viewHeight > 0 ? _terminal.viewHeight : 24;
    final cols = _terminal.viewWidth > 0 ? _terminal.viewWidth : 80;

    try {
      final processFuture = _proot.start(
        command: ['/bin/sh', '/usr/local/bin/start-gui.sh'],
        onStdout: (s) => _terminal.write(s),
        onStderr: (s) => _terminal.write(s),
        rows: rows,
        cols: cols,
      );
      await Future.delayed(const Duration(seconds: 2));
      await _openRealVnc();
      await processFuture;
    } catch (e) {
      _terminal.write('❌ LỖI khởi chạy GUI: $e\r\n');
      _showErrorSnackBar('Lỗi khởi chạy GUI: $e');
      if (mounted) {
        setState(() {
          _running = false;
          _mode = null;
        });
      }
    }
  }

  Future<void> _openRealVnc() async {
    final uri = Uri.parse('vnc://127.0.0.1:5900');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _terminal.write(
          '\r\n📱 Không mở được RealVNC Viewer. Hãy cài app "RealVNC Viewer" '
          'từ Play Store rồi kết nối thủ công tới 127.0.0.1:5900\r\n');
      _showSnackBar('Không mở được RealVNC Viewer. Vui lòng kết nối thủ công.');
    }
  }

  void _stopProcess() {
    if (!_running || _stopping) return;
    setState(() {
      _stopping = true;
    });
    _proot.stop();
    _terminal.write('\r\n🛑 Đã yêu cầu dừng tiến trình.\r\n');
    // Fallback nếu onProcessExited không được gọi kịp
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _stopping) {
        setState(() {
          _stopping = false;
          _running = false;
          _mode = null;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_appBarTitle),
        actions: [
          if (_running || _stopping)
            IconButton(
              icon: _stopping
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.stop),
              onPressed: _stopping ? null : _stopProcess,
              tooltip: 'Dừng tiến trình',
            ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: _copyLog,
            tooltip: 'Copy log',
          ),
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
          if (_installed && _mode == null && !_running) _buildModePicker(),
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
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.terminal),
              title: const Text('CLI'),
              subtitle: const Text('Mở shell Alpine trong terminal'),
              onTap: _launchCli,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.desktop_windows),
              title: const Text('GUI (VNC)'),
              subtitle: const Text('Khởi động môi trường đồ họa và kết nối qua RealVNC'),
              onTap: _launchGui,
            ),
          ),
        ],
      ),
    );
  }
}