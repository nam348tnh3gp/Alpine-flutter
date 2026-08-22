import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';
import '../services/proot_service.dart';

enum RunMode { cli, gui }

/// Đối tượng đại diện cho một phiên terminal (tab)
class TerminalTab {
  late final Terminal terminal;
  late final TerminalController controller;
  late final FocusNode focusNode;
  late final PRootService proot;

  bool running = false;
  bool stopping = false;
  RunMode? mode;

  // Toggle modifier keys cho phiên này
  bool ctrlActive = false;
  bool altActive = false;

  TerminalTab({VoidCallback? onProcessExited}) {
    terminal = Terminal(maxLines: 5000);
    controller = TerminalController();
    focusNode = FocusNode();
    proot = PRootService(
      onLog: (l) => terminal.write('$l\r\n'),
      onProcessExited: onProcessExited,
    );
  }

  void dispose() {
    proot.stop();
    controller.dispose();
    focusNode.dispose();
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<TerminalTab> _tabs = [];
  int? _currentTabIndex;

  bool _installed = false;
  bool _installing = false;
  double _progress = 0;

  String get _appBarTitle => 'Alpine Runner';

  @override
  void initState() {
    super.initState();
    _checkInstalled();
  }

  @override
  void dispose() {
    for (var tab in _tabs) {
      tab.dispose();
    }
    super.dispose();
  }

  // ==================== Kiểm tra & cài đặt rootfs ====================

  Future<void> _checkInstalled() async {
    final tempService = PRootService(onLog: (_) {});
    final ok = await tempService.isInstalled();
    if (mounted) {
      setState(() => _installed = ok);
      if (_installed && _tabs.isEmpty) {
        // Tự động tạo phiên CLI đầu tiên
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _newSession();
        });
      }
    }
  }

  Future<void> _ensureInstalled() async {
    if (_installed) return;
    setState(() => _installing = true);
    final tempService = PRootService(
      onLog: (l) {
        if (_tabs.isNotEmpty) {
          _tabs.first.terminal.write('$l\r\n');
        } else {
          final tab = TerminalTab();
          setState(() {
            _tabs.add(tab);
            _currentTabIndex = _tabs.length - 1;
          });
          tab.terminal.write('$l\r\n');
        }
      },
    );
    try {
      await tempService.bootstrap(onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) setState(() => _installed = true);
    } catch (e) {
      if (_tabs.isNotEmpty) {
        _tabs.first.terminal.write('❌ LỖI cài đặt: $e\r\n');
      }
      _showErrorSnackBar('Lỗi cài đặt: $e');
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  // ==================== Quản lý tab & phiên ====================

  Future<TerminalTab> _createNewTab() async {
    late final TerminalTab tab;
    tab = TerminalTab(
      onProcessExited: () {
        if (mounted) {
          setState(() {
            tab.running = false;
            tab.mode = null;
            tab.stopping = false;
          });
        }
      },
    );
    setState(() {
      _tabs.add(tab);
      _currentTabIndex = _tabs.length - 1;
    });

    tab.terminal.onOutput = (data) {
      if (tab.ctrlActive) {
        tab.proot.sendInput(_applyCtrl(data));
        setState(() => tab.ctrlActive = false); // Tự tắt sau khi gửi
      } else if (tab.altActive) {
        tab.proot.sendInput(_applyAlt(data));
        setState(() => tab.altActive = false); // Tự tắt sau khi gửi
      } else {
        tab.proot.sendInput(data);
      }
    };

    tab.terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      tab.proot.resizeTerminal(width, height);
    };

    return tab;
  }

  Future<void> _launchCliForTab(TerminalTab tab) async {
    if (tab.running || tab.stopping) return;
    setState(() {
      tab.running = true;
      tab.mode = RunMode.cli;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusScope.of(context).requestFocus(tab.focusNode);
    });

    await Future.delayed(const Duration(milliseconds: 50));

    final rows = tab.terminal.viewHeight > 0 ? tab.terminal.viewHeight : 24;
    final cols = tab.terminal.viewWidth > 0 ? tab.terminal.viewWidth : 80;

    try {
      await tab.proot.start(
        command: ['/bin/sh', '-l'],
        onStdout: (s) => tab.terminal.write(_sanitizeTerminalOutput(s)),
        rows: rows,
        cols: cols,
      );
    } catch (e) {
      tab.terminal.write('❌ LỖI khởi chạy CLI: $e\r\n');
      _showErrorSnackBar('Lỗi khởi chạy CLI: $e');
      if (mounted) {
        setState(() {
          tab.running = false;
          tab.mode = null;
        });
      }
    }
  }

  Future<void> _launchGuiForTab(TerminalTab tab) async {
    if (tab.running || tab.stopping) return;
    setState(() {
      tab.running = true;
      tab.mode = RunMode.gui;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusScope.of(context).requestFocus(tab.focusNode);
    });

    await Future.delayed(const Duration(milliseconds: 50));

    final rows = tab.terminal.viewHeight > 0 ? tab.terminal.viewHeight : 24;
    final cols = tab.terminal.viewWidth > 0 ? tab.terminal.viewWidth : 80;

    try {
      final processFuture = tab.proot.start(
        command: ['/bin/sh', '/usr/local/bin/start-gui.sh'],
        onStdout: (s) => tab.terminal.write(_sanitizeTerminalOutput(s)),
        rows: rows,
        cols: cols,
      );
      await Future.delayed(const Duration(seconds: 2));
      await _openRealVnc();
      await processFuture;
    } catch (e) {
      tab.terminal.write('❌ LỖI khởi chạy GUI: $e\r\n');
      _showErrorSnackBar('Lỗi khởi chạy GUI: $e');
      if (mounted) {
        setState(() {
          tab.running = false;
          tab.mode = null;
        });
      }
    }
  }

  Future<void> _openRealVnc() async {
    final uri = Uri.parse('vnc://127.0.0.1:5900');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      final tab = _tabs.isNotEmpty ? _tabs[_currentTabIndex!] : null;
      tab?.terminal.write(
          '\r\n📱 Không mở được RealVNC Viewer. Hãy cài app "RealVNC Viewer" '
          'từ Play Store rồi kết nối thủ công tới 127.0.0.1:5900\r\n');
      _showSnackBar('Không mở được RealVNC Viewer. Vui lòng kết nối thủ công.');
    }
  }

  Future<void> _newSession() async {
    final tab = await _createNewTab();
    await _launchCliForTab(tab);
  }

  void _stopCurrentTab() {
    if (_currentTabIndex == null || _tabs.isEmpty) return;
    final tab = _tabs[_currentTabIndex!];
    if (!tab.running || tab.stopping) return;
    setState(() {
      tab.stopping = true;
    });
    tab.proot.stop();
    tab.terminal.write('\r\n🛑 Đã yêu cầu dừng tiến trình.\r\n');
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && tab.stopping) {
        setState(() {
          tab.stopping = false;
          tab.running = false;
          tab.mode = null;
        });
      }
    });
  }

  void _closeCurrentTab() {
    if (_currentTabIndex == null || _tabs.isEmpty) return;
    final tab = _tabs[_currentTabIndex!];
    tab.dispose();
    setState(() {
      _tabs.removeAt(_currentTabIndex!);
      if (_tabs.isEmpty) {
        _currentTabIndex = null;
      } else {
        _currentTabIndex = (_currentTabIndex! >= _tabs.length)
            ? _tabs.length - 1
            : _currentTabIndex;
      }
    });
  }

  // ==================== Các tiện ích UI ====================

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

  Future<void> _copyLog() async {
    if (_currentTabIndex == null) return;
    final tab = _tabs[_currentTabIndex!];
    final logs = tab.proot.getLogs();
    if (logs.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: logs));
      tab.terminal.write('\r\n📋 Đã copy log vào clipboard!\r\n');
      _showSnackBar('📋 Đã copy log vào clipboard!');
    } else {
      tab.terminal.write('\r\n⚠️ Không có log để copy.\r\n');
      _showSnackBar('⚠️ Không có log để copy.');
    }
  }

  void _clearLog() {
    if (_currentTabIndex == null) return;
    final tab = _tabs[_currentTabIndex!];
    tab.proot.clearLogs();
    tab.terminal.write('\r\n🗑️ Đã xóa log.\r\n');
    _showSnackBar('🗑️ Đã xóa log.');
  }

  // ==================== Xử lý modifier & sanitize ====================

  String _applyCtrl(String input) {
    if (input.length == 1) {
      final code = input.codeUnitAt(0);
      if (code >= 65 && code <= 90) {
        return String.fromCharCode(code - 64);
      } else if (code >= 97 && code <= 122) {
        return String.fromCharCode(code - 96);
      }
    }
    return input;
  }

  String _applyAlt(String input) {
    if (input.isNotEmpty) {
      return '\x1b$input';
    }
    return input;
  }

  String _sanitizeTerminalOutput(String data) {
    String processed = data;
    processed = processed.replaceAll('\x1b[2J\x1b[H', '\x1b[2J\x1b[H\x1b[3J');
    processed = processed.replaceAll('\x1b[H\x1b[2J', '\x1b[H\x1b[2J\x1b[3J');
    processed = processed.replaceAll('\x1b[2J', '\x1b[2J\x1b[3J');
    processed = processed.replaceAll('\x0c', '\x1b[3J\x0c');
    return processed;
  }

  // ==================== Xử lý copy/paste ====================

  Future<void> _handleSecondaryTapDown(
      TerminalTab tab, TapDownDetails details, CellOffset offset) async {
    final selection = tab.controller.selection;
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
                    final text = tab.terminal.buffer.getText(selection!);
                    Clipboard.setData(ClipboardData(text: text));
                    tab.controller.clearSelection();
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
                    tab.terminal.paste(clipboardData!.text!);
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
                  tab.controller.clearSelection();
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // ==================== Build giao diện ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alpine Runner'),
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: _showMainMenu,
          tooltip: 'Menu',
        ),
        actions: [
          if (_currentTabIndex != null && _tabs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.stop),
              onPressed: _stopCurrentTab,
              tooltip: 'Dừng tiến trình',
            ),
        ],
      ),
      body: Column(
        children: [
          if (!_installed) _buildInstallPanel(),
          if (_installed && (_tabs.isEmpty || _currentTabIndex == null))
            _buildModePicker(),
          if (_tabs.isNotEmpty) _buildTabBar(),
          Expanded(
            child: _tabs.isEmpty
                ? _buildEmptyState()
                : IndexedStack(
                    index: _currentTabIndex ?? 0,
                    children: _tabs
                        .map(
                          (tab) => _buildTerminalView(tab),
                        )
                        .toList(),
                  ),
          ),
          if (_tabs.isNotEmpty) _buildExtraKeysBar(),
        ],
      ),
    );
  }

  // ==================== Menu chính (hamburger) ====================

  void _showMainMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('Sessions', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              ..._tabs.asMap().entries.map((entry) {
                final index = entry.key;
                final tab = entry.value;
                return ListTile(
                  leading: Icon(
                    index == _currentTabIndex ? Icons.check : Icons.terminal,
                    color: index == _currentTabIndex ? Colors.teal : null,
                  ),
                  title: Text('Term ${index + 1}'),
                  onTap: () {
                    Navigator.pop(context);
                    setState(() => _currentTabIndex = index);
                    FocusScope.of(context).requestFocus(tab.focusNode);
                  },
                );
              }),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.add_box),
                title: const Text('New Session'),
                onTap: () {
                  Navigator.pop(context);
                  _newSession();
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy Log'),
                onTap: () {
                  Navigator.pop(context);
                  _copyLog();
                },
              ),
              ListTile(
                leading: const Icon(Icons.clear),
                title: const Text('Clear Log'),
                onTap: () {
                  Navigator.pop(context);
                  _clearLog();
                },
              ),
              if (_currentTabIndex != null && _tabs.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.stop),
                  title: const Text('Stop Current'),
                  onTap: () {
                    Navigator.pop(context);
                    _stopCurrentTab();
                  },
                ),
              if (_currentTabIndex != null && _tabs.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.close),
                  title: const Text('Close Current Tab'),
                  onTap: () {
                    Navigator.pop(context);
                    _closeCurrentTab();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  // ==================== Tab bar ====================

  Widget _buildTabBar() {
    return Container(
      color: Colors.grey.shade900,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: List.generate(_tabs.length, (index) {
            final tab = _tabs[index];
            final isSelected = index == _currentTabIndex;
            return GestureDetector(
              onTap: () {
                setState(() => _currentTabIndex = index);
                FocusScope.of(context).requestFocus(tab.focusNode);
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                color: isSelected ? Colors.teal : Colors.grey.shade800,
                child: Row(
                  children: [
                    Text(
                      'Term ${index + 1}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    if (isSelected)
                      const SizedBox(width: 4),
                    if (isSelected)
                      GestureDetector(
                        onTap: () => _closeCurrentTab(),
                        child: const Icon(Icons.close,
                            size: 14, color: Colors.white),
                      ),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildTerminalView(TerminalTab tab) {
    return TerminalView(
      tab.terminal,
      controller: tab.controller,
      focusNode: tab.focusNode,
      autofocus: true,
      onSecondaryTapDown: (details, offset) =>
          _handleSecondaryTapDown(tab, details, offset),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Text('Chưa có phiên nào. Hãy tạo phiên mới.'),
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
              onTap: _newSession,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.desktop_windows),
              title: const Text('GUI (VNC)'),
              subtitle:
                  const Text('Khởi động môi trường đồ họa và kết nối qua RealVNC'),
              onTap: () async {
                final tab = await _createNewTab();
                await _launchGuiForTab(tab);
              },
            ),
          ),
        ],
      ),
    );
  }

  // ==================== Extra keys bar ====================

  Widget _buildExtraKeysBar() {
    if (_tabs.isEmpty || _currentTabIndex == null) return const SizedBox.shrink();
    final tab = _tabs[_currentTabIndex!];
    if (!tab.running) return const SizedBox.shrink();

    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Hàng 1: menu, CTRL, ALT, ESC, TAB, ENTER, BACKSPACE, SPACE, DEL
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _menuKey(tab),
                _modifierKey(tab, 'CTRL', tab.ctrlActive),
                _modifierKey(tab, 'ALT', tab.altActive),
                _functionKey(tab, 'ESC', '\x1b'),
                _functionKey(tab, 'TAB', '\t'),
                _functionKey(tab, 'ENTER', '\r'),
                _functionKey(tab, 'SPACE', ' '),
                _functionKey(tab, 'BACKSPACE', '\x7f'),
                _functionKey(tab, 'DEL', '\x1b[3~'),  // Sửa DEL đúng escape sequence
              ],
            ),
          ),
          const SizedBox(height: 4),
          // Hàng 2: phím điều hướng
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _functionKey(tab, '▲', '\x1b[A', ctrl: '\x1b[1;5A', alt: '\x1b[1;3A'),
                _functionKey(tab, '▼', '\x1b[B', ctrl: '\x1b[1;5B', alt: '\x1b[1;3B'),
                _functionKey(tab, '◀', '\x1b[D', ctrl: '\x1b[1;5D', alt: '\x1b[1;3D'),
                _functionKey(tab, '▶', '\x1b[C', ctrl: '\x1b[1;5C', alt: '\x1b[1;3C'),
                _functionKey(tab, 'HOME', '\x1b[H'),
                _functionKey(tab, 'END', '\x1b[F'),
                _functionKey(tab, 'PGUP', '\x1b[5~'),
                _functionKey(tab, 'PGDN', '\x1b[6~'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _menuKey(TerminalTab tab) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: () => _showMainMenu(),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.grey.shade800,
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Icon(Icons.menu, color: Colors.white, size: 18),
        ),
      ),
    );
  }

  Widget _modifierKey(TerminalTab tab, String label, bool active) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: () => _toggleModifier(tab, label),
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

  Widget _functionKey(TerminalTab tab, String label, String normal,
      {String? ctrl, String? alt}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: () => _sendKey(tab, label, normal: normal, ctrl: ctrl, alt: alt),
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

  void _toggleModifier(TerminalTab tab, String mod) {
    setState(() {
      if (mod == 'CTRL') {
        tab.ctrlActive = !tab.ctrlActive;
      } else if (mod == 'ALT') {
        tab.altActive = !tab.altActive;
      }
    });
  }

  void _sendKey(TerminalTab tab, String label,
      {String? normal, String? ctrl, String? alt}) {
    String value = '';
    if (tab.ctrlActive && ctrl != null) {
      value = ctrl;
    } else if (tab.altActive && alt != null) {
      value = alt;
    } else if (normal != null) {
      value = normal;
    }

    if (value.isNotEmpty) {
      tab.proot.sendInput(value);
      // Tự tắt modifier sau khi gửi (giống hành vi phím tắt thông thường)
      setState(() {
        tab.ctrlActive = false;
        tab.altActive = false;
      });
    }
  }
}