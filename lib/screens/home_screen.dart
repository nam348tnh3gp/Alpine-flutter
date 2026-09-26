import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:xterm/xterm.dart';
import '../services/proot_service.dart';
import '../models/distro.dart';

/// Đối tượng đại diện cho một phiên terminal (tab)
class TerminalTab {
  late final Terminal terminal;
  late final TerminalController controller;
  late final FocusNode focusNode;
  late final PRootService proot;
  final Distro distro;

  bool running = false;
  bool stopping = false;

  // Toggle modifier keys cho phiên này
  bool ctrlActive = false;
  bool altActive = false;

  // Cỡ chữ mặc định, có thể zoom bằng pinch
  double fontSize = 14.0;
  double pinchBaseFontSize = 14.0; // chỉ set 1 lần khi bắt đầu pinch

  TerminalTab({required this.distro, VoidCallback? onProcessExited}) {
    terminal = Terminal(maxLines: 5000);

    // Không ép bật bracketed paste. Để xterm tự bật khi shell hỗ trợ (nhận escape sequence).
    // Nếu ép true, BusyBox ash sẽ nhận các byte escape và làm hỏng dòng paste.

    controller = TerminalController();
    focusNode = FocusNode();
    proot = PRootService(
      distro: distro,
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

  // Trạng thái cài đặt của TỪNG distro (id -> đã cài xong hay chưa).
  final Map<String, bool> _installedMap = {};
  bool _checkingInstalled = true;
  bool _installing = false;
  double _progress = 0;
  Distro? _installingDistro;

  bool get _anyInstalled => _installedMap.values.any((v) => v);

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
    final results = <String, bool>{};
    for (final d in Distros.all) {
      final tempService = PRootService(distro: d, onLog: (_) {});
      results[d.id] = await tempService.isInstalled();
    }
    if (!mounted) return;
    setState(() {
      _installedMap
        ..clear()
        ..addAll(results);
      _checkingInstalled = false;
    });
    if (_anyInstalled && _tabs.isEmpty) {
      // Tự động tạo phiên CLI đầu tiên cho distro đã cài (ưu tiên theo thứ
      // tự Distros.all - nếu chỉ cài 1 distro thì luôn tự boot đúng distro đó).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _newSession();
      });
    }
  }

  // ========== BẢN VÁ: Sửa lỗi kẹt UI sau cài đặt ==========
  Future<void> _ensureInstalled(Distro distro, {StateSetter? sheetSetState}) async {
    if (_installedMap[distro.id] == true) return;

    // Cập nhật CẢ state chính lẫn state của bottom sheet "Quản lý Distro"
    // (nếu đang mở từ đó) - setState() của widget chính không tự kéo theo
    // rebuild của 1 modal đang mở, nên phải gọi thêm sheetSetState riêng.
    void update(VoidCallback fn) {
      if (mounted) setState(fn);
      sheetSetState?.call(fn);
    }

    update(() {
      _installing = true;
      _installingDistro = distro;
    });

    // Tạo một tab tạm để hiển thị log trong quá trình cài
    final tempTab = TerminalTab(distro: distro);
    setState(() {
      _tabs.add(tempTab);
      _currentTabIndex = _tabs.length - 1;
    });

    final service = PRootService(
      distro: distro,
      onLog: (l) => tempTab.terminal.write('$l\r\n'),
    );

    try {
      await service.bootstrap(onProgress: (p) {
        update(() => _progress = p);
      });

      if (mounted) {
        // Xóa tab tạm
        _tabs.remove(tempTab);
        // Nếu không còn tab nào, đặt _currentTabIndex = null
        if (_tabs.isEmpty) {
          _currentTabIndex = null;
        } else {
          _currentTabIndex = 0;
        }

        update(() {
          _installedMap[distro.id] = true;
          _installing = false;
          _installingDistro = null;
        });

        // Tạo một phiên thật đầu tiên cho distro vừa cài
        await _newSession(distro: distro);
      }
    } catch (e) {
      if (mounted) {
        tempTab.terminal.write('❌ LỖI cài đặt: $e\r\n');
        _showErrorSnackBar('Lỗi cài đặt: $e');
        // Xóa tab tạm và reset trạng thái
        _tabs.remove(tempTab);
        if (_tabs.isEmpty) _currentTabIndex = null;
        update(() {
          _installing = false;
          _installingDistro = null;
        });
      }
    } finally {
      service.stop();
      // Nếu có lỗi mà tab tạm vẫn còn, đảm bảo dispose
      if (_tabs.contains(tempTab)) {
        tempTab.dispose();
        _tabs.remove(tempTab);
        if (_tabs.isEmpty) _currentTabIndex = null;
      }
    }
  }

  // ==================== Quản lý tab & phiên ====================

  Future<TerminalTab> _createNewTab(Distro distro) async {
    late final TerminalTab tab;
    tab = TerminalTab(
      distro: distro,
      onProcessExited: () {
        if (mounted) {
          setState(() {
            tab.running = false;
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
        });
      }
    }
  }

  /// Tạo phiên mới. Nếu không truyền [distro]:
  /// - Chỉ 1 distro đã cài -> dùng luôn distro đó (giữ trải nghiệm "auto-boot"
  ///   không cần chọn gì, giống hệt hành vi cũ khi app chỉ có Alpine).
  /// - Nhiều distro đã cài -> hỏi nhanh muốn mở distro nào.
  /// - Chưa cài distro nào -> chuyển sang màn hình cài đặt thay vì tạo phiên.
  Future<void> _newSession({Distro? distro}) async {
    distro ??= await _resolveDistroForNewSession();
    if (distro == null) return; // chưa cài gì / người dùng huỷ chọn

    final tab = await _createNewTab(distro);
    await _launchCliForTab(tab);
  }

  Future<Distro?> _resolveDistroForNewSession() async {
    final installed =
        Distros.all.where((d) => _installedMap[d.id] == true).toList();
    if (installed.isEmpty) {
      setState(() {}); // đảm bảo _buildDistroPicker() hiện lên
      _showSnackBar('Chưa cài distro nào - chọn 1 distro bên dưới để cài.');
      return null;
    }
    if (installed.length == 1) return installed.first;
    return _pickInstalledDistro(installed);
  }

  Future<Distro?> _pickInstalledDistro(List<Distro> installed) async {
    if (!mounted) return null;
    return showModalBottomSheet<Distro>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Mở phiên mới với distro nào?',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ...installed.map((d) => ListTile(
                  leading: const Icon(Icons.terminal),
                  title: Text(d.displayName),
                  onTap: () => Navigator.pop(context, d),
                )),
          ],
        ),
      ),
    );
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

  Future<void> _showDistroManager() async {
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('🐧 Quản lý Distro',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 12),
                  ...Distros.all.map((d) => _buildDistroCard(d, sheetSetState: setSheetState)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ==================== Menu ngữ cảnh terminal (copy/paste) ====================

  Future<void> _showTerminalContextMenu(TerminalTab tab) async {
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
                    String rawText = clipboardData!.text!;
                    String cleanText = rawText
                        .replaceAll('\r\n', '\n')  // Windows -> Unix
                        .replaceAll('\r', '');     // Loại bỏ CR thừa

                    tab.terminal.paste(cleanText);
                    _showSnackBar('📥 Đã paste (đã chuẩn hóa)');
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
          if (_anyInstalled)
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => _newSession(),
              tooltip: 'Phiên mới',
            ),
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
          if (_checkingInstalled)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: SizedBox(
                  width: 24, height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            )
          else if (!_anyInstalled)
            _buildDistroPicker()
          else if (_tabs.isEmpty || _currentTabIndex == null)
            _buildBootingIndicator(),
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
                leading: const Icon(Icons.widgets_outlined),
                title: const Text('Quản lý Distro'),
                subtitle: const Text('Cài thêm / xem distro đã cài'),
                onTap: () {
                  Navigator.pop(context);
                  _showDistroManager();
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
                      '${tab.distro.displayName} ${index + 1}',
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
    return GestureDetector(
      onLongPress: () => _showTerminalContextMenu(tab),
      onScaleStart: (_) => tab.pinchBaseFontSize = tab.fontSize,
      onScaleUpdate: (details) {
        if (details.pointerCount < 2) return;
        setState(() {
          tab.fontSize = (tab.pinchBaseFontSize * details.scale).clamp(8.0, 32.0);
        });
      },
      child: TerminalView(
        tab.terminal,
        controller: tab.controller,
        focusNode: tab.focusNode,
        autofocus: true,
        textStyle: TerminalStyle(fontSize: tab.fontSize),
        onSecondaryTapDown: (details, offset) => _showTerminalContextMenu(tab),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Text('Chưa có phiên nào. Hãy tạo phiên mới.'),
    );
  }

  Widget _buildDistroPicker() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('🐧 Chọn distro để cài', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          ...Distros.all.map((d) => _buildDistroCard(d)),
        ],
      ),
    );
  }

  Widget _buildDistroCard(Distro d, {StateSetter? sheetSetState}) {
    final installed = _installedMap[d.id] == true;
    final isInstallingThis = _installing && _installingDistro?.id == d.id;
    final inSheet = sheetSetState != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(installed ? Icons.check_circle : Icons.terminal,
                    color: installed ? Colors.teal : null),
                const SizedBox(width: 8),
                Text(d.displayName,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 6),
            Text(d.description, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 10),
            if (isInstallingThis) ...[
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
              const SizedBox(height: 6),
              Text('${(_progress * 100).toStringAsFixed(0)}%'),
            ] else if (installed)
              OutlinedButton.icon(
                onPressed: () {
                  if (inSheet) Navigator.pop(context);
                  _newSession(distro: d);
                },
                icon: const Icon(Icons.play_arrow),
                label: const Text('Mở phiên'),
              )
            else
              FilledButton.icon(
                onPressed: _installing
                    ? null
                    : () => _ensureInstalled(d, sheetSetState: sheetSetState),
                icon: const Icon(Icons.download),
                label: const Text('Tải & cài'),
              ),
          ],
        ),
      ),
    );
  }

  /// Hiện trong khoảnh khắc ngắn giữa lúc xác nhận đã cài Alpine và lúc
  /// phiên CLI đầu tiên thực sự sẵn sàng (auto-boot) - trước đây khoảng
  /// trống này để trống/nhấp nháy màn hình chọn mode, giờ thay bằng loading
  /// rõ ràng để người dùng biết app đang tự khởi động, không phải bị treo.
  Widget _buildBootingIndicator() {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28, height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(height: 12),
          Text('🚀 Đang khởi động...'),
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
                _functionKey(tab, 'DEL', '\x1b[3~'),
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