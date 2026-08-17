import 'package:flutter/material.dart';
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
  final FocusNode _terminalFocus = FocusNode(); // Thêm FocusNode
  bool _installed = false;
  bool _installing = false;
  double _progress = 0;
  RunMode? _mode;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _proot = PRootService(onLog: (l) => _terminal.write('$l\r\n'));
    _checkInstalled();
  }

  @override
  void dispose() {
    _terminalFocus.dispose();
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
      _terminal.write('LỖI cài đặt: $e\r\n');
    } finally {
      setState(() => _installing = false);
    }
  }

  Future<void> _launchCli() async {
    setState(() {
      _mode = RunMode.cli;
      _running = true;
    });
    // Yêu cầu focus ngay khi terminal hiện
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).requestFocus(_terminalFocus);
    });
    await _proot.start(
      command: ['/bin/sh', '-l'],
      onStdout: (s) => _terminal.write(s),
      onStderr: (s) => _terminal.write(s),
    );
  }

  Future<void> _launchGui() async {
    setState(() {
      _mode = RunMode.gui;
      _running = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).requestFocus(_terminalFocus);
    });
    await _proot.start(
      command: ['/bin/sh', '/usr/local/bin/start-gui.sh'],
      onStdout: (s) => _terminal.write(s),
      onStderr: (s) => _terminal.write(s),
    );
    await Future.delayed(const Duration(seconds: 2));
    await _openRealVnc();
  }

  Future<void> _openRealVnc() async {
    final uri = Uri.parse('vnc://127.0.0.1:5900');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _terminal.write(
          '\r\nKhông mở được RealVNC Viewer. Hãy cài app "RealVNC Viewer" '
          'từ Play Store rồi kết nối thủ công tới 127.0.0.1:5900\r\n');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alpine Runner (proot, no root)')),
      body: Column(
        children: [
          if (!_installed) _buildInstallPanel(),
          if (_installed && _mode == null) _buildModePicker(),
          if (_running)
            Expanded(
              child: Focus(
                focusNode: _terminalFocus,
                onKey: (node, event) {
                  // Gửi sự kiện phím vào terminal
                  if (event is RawKeyDownEvent) {
                    _terminal.input(event);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TerminalView(_terminal),
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
          const Text('Chưa cài Alpine rootfs.'),
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
            label: const Text('Chế độ CLI'),
          ),
          FilledButton.icon(
            onPressed: _launchGui,
            icon: const Icon(Icons.desktop_windows),
            label: const Text('Chế độ GUI (qua RealVNC)'),
          ),
        ],
      ),
    );
  }
}