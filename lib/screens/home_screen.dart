import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
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
  final TerminalController _terminalController = TerminalController();
  final FocusNode _terminalFocusNode = FocusNode();

  bool _installed = false;
  bool _installing = false;
  double _progress = 0;
  RunMode? _mode;
  bool _running = false;
  bool _stopping = false;

  // Toggle modifier keys
  bool _ctrlActive = false;
  bool _altActive = false;

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
      if (_ctrlActive) {
        _proot.sendInput(_applyCtrl(data));
      } else if (_altActive) {
        _proot.sendInput(_applyAlt(data));
      } else {
        _proot.sendInput(data);
      }
    };

    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _proot.resizeTerminal(width, height);
    };
  }

  @override
  void dispose() {
    _proot.stop();
    _terminalController.dispose();
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

    await Future.delayed(const Duration(milliseconds: 50));

    final rows = _terminal.viewHeight > 0 ? _terminal.viewHeight : 24;
    final cols = _terminal.viewWidth > 0 ? _terminal.viewWidth : 80;

    try {
      await _proot.start(
        command: ['/bin/sh', '-l'],
        onStdout: (s) => _terminal.write(s),
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
              controller: _terminalController,
              focusNode: _terminalFocusNode,
              autofocus: true,
              onSecondaryTapDown: _handleSecondaryTapDown,
            ),
          ),
          if (_running) _buildExtraKeysBar(),
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

  // ==================== EXTRA KEYS BAR (gọn gàng) ====================

  Widget _buildExtraKeysBar() {
    if (!_running) return const SizedBox.shrink();

    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _modifierKey('CTRL', _ctrlActive),
            _modifierKey('ALT', _altActive),
            _functionKey('ESC', '\x1b'),
            _functionKey('TAB', '\t'),
            _functionKey('ENTER', '\r'),
            _functionKey('SPACE', ' '),
            _functionKey('BACKSPACE', '\x7f'),
            _functionKey('▲', '\x1b[A', ctrl: '\x1b[1;5A', alt: '\x1b[1;3A'),
            _functionKey('▼', '\x1b[B', ctrl: '\x1b[1;5B', alt: '\x1b[1;3B'),
            _functionKey('◀', '\x1b[D', ctrl: '\x1b[1;5D', alt: '\x1b[1;3D'),
            _functionKey('▶', '\x1b[C', ctrl: '\x1b[1;5C', alt: '\x1b[1;3C'),
            _functionKey('HOME', '\x1b[H'),
            _functionKey('END', '\x1b[F'),
            _functionKey('PGUP', '\x1b[5~'),
            _functionKey('PGDN', '\x1b[6~'),
            _functionKey('DEL', '\x7f'),
          ],
        ),
      ),
    );
  }

  Widget _modifierKey(String label, bool active) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: () => _toggleModifier(label),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: active ? Colors.teal : Colors.grey.shade800,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? Colors.tealAccent : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  Widget _functionKey(String label, String normal, {String? ctrl, String? alt}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: () => _sendKey(label, normal: normal, ctrl: ctrl, alt: alt),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.grey.shade800,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }

  void _toggleModifier(String mod) {
    setState(() {
      if (mod == 'CTRL') {
        _ctrlActive = !_ctrlActive;
      } else if (mod == 'ALT') {
        _altActive = !_altActive;
      }
    });
  }

  void _sendKey(String label, {String? normal, String? ctrl, String? alt}) {
    String value = '';
    if (_ctrlActive && ctrl != null) {
      value = ctrl;
    } else if (_altActive && alt != null) {
      value = alt;
    } else if (normal != null) {
      value = normal;
    }

    if (value.isNotEmpty) {
      _proot.sendInput(value);
    }
  }

  // ==================== Xử lý modifier cho bàn phím vật lý ====================

  /// Chuyển đổi chuỗi nhập từ bàn phím khi CTRL active.
  /// Chỉ áp dụng cho các ký tự a-z hoặc A-Z. Các ký tự khác (escape, enter, v.v.) giữ nguyên.
  String _applyCtrl(String input) {
    if (input.length == 1) {
      final code = input.codeUnitAt(0);
      if (code >= 65 && code <= 90) {
        return String.fromCharCode(code - 64); // A=65 -> 1
      } else if (code >= 97 && code <= 122) {
        return String.fromCharCode(code - 96); // a=97 -> 1
      }
    }
    return input;
  }

  /// Chuyển đổi chuỗi nhập từ bàn phím khi ALT active.
  /// Thêm tiền tố ESC vào trước ký tự (chuỗi) để tạo Alt+key.
  String _applyAlt(String input) {
    if (input.isNotEmpty) {
      return '\x1b$input';
    }
    return input;
  }

  // ==================== Xử lý selection/copy/paste ====================

  Future<void> _handleSecondaryTapDown(TapDownDetails details, CellOffset offset) async {
    final selection = _terminalController.selection;
    final hasSelection = selection != null;

    final clipboardData = await Clipboard.getData('text/plain');
    final hasClipboard = clipboardData?.text?.isNotEmpty ?? false;

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy'),
                enabled: hasSelection,
                onTap: () {
                  if (hasSelection) {
                    final text = _terminal.buffer.getText(selection!);
                    Clipboard.setData(ClipboardData(text: text));
                    _terminalController.clearSelection();
                    _showSnackBar('📋 Đã copy');
                  }
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.paste),
                title: const Text('Paste'),
                enabled: hasClipboard,
                onTap: () {
                  if (hasClipboard) {
                    _terminal.paste(clipboardData!.text!);
                    _showSnackBar('📥 Đã paste');
                  }
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.clear),
                title: const Text('Clear Selection'),
                enabled: hasSelection,
                onTap: () {
                  _terminalController.clearSelection();
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}