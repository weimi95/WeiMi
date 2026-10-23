import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'framework/bootstrap.dart';
import 'framework/module_registry.dart';
import 'framework/setting_store.dart';
import 'modules/language_module.dart';
import 'modules/quick_search_module.dart';
import 'services/tray_service.dart';
import 'services/trusted_devices_service.dart';
import 'services/hotkey_service.dart';
import 'services/quick_search_window.dart';
import 'services/file_operations_service.dart';
import 'services/encryption_service.dart';
import 'services/file_viewer_service.dart';
import 'services/file_association_service.dart';
import 'services/localization_service.dart';
import 'services/history_service.dart';
import 'widgets/progress_dialog.dart';
import 'screens/about_screen.dart';
import 'screens/language_screen.dart';
import 'screens/wei_mi_vault_screen.dart';
import 'screens/vault_browser_screen.dart';
import 'screens/operation_history_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/quick_search_popup.dart';
import 'services/lan_transfer_service.dart';
import 'services/view_prefs_service.dart';
import 'services/share_receive_service.dart';
import 'services/receive_notify_service.dart';
import 'services/daemon_service.dart';
import 'screens/lan_transfer_screen.dart';
import 'widgets/file_thumbnail.dart';
import 'package:path_provider/path_provider.dart';

// 密码长度限制常量
const int kPasswordMinLength = 4;
const int kPasswordMaxLength = 32;

// 上次加密/解密输出目录的 SharedPreferences key
const String kLastOutputDirKey = 'last_output_dir';

// 桌面端单进程常驻托盘：窗口关闭 = 收托盘（见 tray_service.dart），由 TrayService 管理。


void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 深链必须在窗口创建前检测：initDesktop 的 waitUntilReadyToShow 会决定
  // 窗口要不要 show——冷启浮窗若先 show 再 hide，就会闪一下空白大窗。
  final deepPopupStart = args.contains('--page=popup');

  // 开机自启「进托盘不进窗口」（设置→通用→桌面端）：注册表自启条目带
  // --tray 参数，与用户手动双击（无参数，正常出窗口）区分。
  final trayStart = args.contains('--tray');

  if (deepPopupStart) {
    // ===== 冷启浮窗极简路径（秒开，v1.0.69）=====
    // 守护进程代听双击 Ctrl 拉起的临时会话：只做浮窗必需的初始化，
    // 注册表/飞传/托盘/索引/目录监视/通知全部跳过——那些属于常驻会话，
    // 不属于一次性弹窗。此前这些串行 await 是双击到上屏 ~0.5s 的主因。
    await Future.wait([
      LocalizationService.getInstance(),
      SettingStore.init(),
    ]);
    bootstrapModules();
    if (!Platform.isAndroid && !Platform.isIOS) {
      try {
        // 只建隐藏窗口 + 标记守护会话，不起飞传/托盘/索引
        await TrayService.instance.initPopupSession();
      } catch (e) {
        debugPrint('popup session init failed: $e');
      }
    }
  } else {
    // ===== 常驻会话完整初始化 =====
    // Initialize localization service before running the app
    await LocalizationService.getInstance();

    // 加载全局视图偏好（列表/宫格/瀑布流）
    await ViewPrefsService.instance.load();

    // 桌面端：加载关闭按钮行为设置（收托盘/退出/询问）
    await TrayService.instance.loadPrefs();

    // 统一设置层 + 功能模块注册表（设置中心/文件动作的单一数据源）
    await SettingStore.init();
    bootstrapModules();

    // 局域网接收文件的兜底目录（用户未设置加密目录时用）
    try {
      final docs = await getApplicationDocumentsDirectory();
      LanTransferService.instance.fallbackDir = docs.path;
    } catch (_) {}

    // 启动时自动开启微密飞传接收（仅 Android，默认开；桌面端由 initDesktop 常驻启动）
    if (Platform.isAndroid) {
      try {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getBool('lan_autostart') ?? true) {
          LanTransferService.instance.applyDiscoverSetting();
        }
      } catch (_) {}
      // Android 全局接收确认：未信任设备发来弹窗（带超时倒计时）。
      // 桌面端在 initDesktop 挂同款；App 在后台时对话框等回到前台再渲染，
      // 超时由 _decideAccept 的 timeout 兜底自动拒收。
      // ctx 未就绪（后台刚被拉起）只拒本条、不拉黑（batchDefault=false），
      // 避免用户没被问到就连带 2 分钟静默拒后续（v1.2.13）
      LanTransferService.instance.confirmHandler = (req) async {
        BuildContext? ctx;
        for (var i = 0; i < 8; i++) {
          final c = ShareReceiveService.navigatorKey.currentContext;
          if (c != null && c.mounted) {
            ctx = c;
            break;
          }
          await Future.delayed(const Duration(milliseconds: 250));
        }
        if (ctx == null) {
          return const IncomingDecision(accepted: false, batchDefault: false);
        }
        final activeCtx = ctx!;
        final d = await showIncomingConfirmDialog(
          activeCtx,
          senderName: req.senderName,
          content: req.fileName,
          sizeBytes: req.fileSize,
          isText: req.fileName == '一条文本消息',
          countdownSec: LanTransferService.confirmTimeoutSecs(),
          verifCode: req.verifCode,
          trustable: req.trustable,
        );
        // 勾选信任 → 按设备 ID 持久化（LANDrop 为 secp256k1 公钥 base64）
        if (d.accepted && d.trust && req.trustable && req.senderId.isNotEmpty) {
          await TrustedDevices.instance.add(req.senderId, req.senderName);
        }
        return d;
      };
    }

    // 系统分享接收（Android SEND/SEND_MULTIPLE → 飞传页）
    await ShareReceiveService.instance.init();

    // 接收完成通知（PC 系统通知 / 安卓应用内横幅）
    await ReceiveNotifyService.instance.init();

    if (Platform.isWindows) {
      await FileAssociationService.registerFileAssociation();
    }

    // 桌面端：单进程常驻托盘，主程序自身跑飞传 + 托盘（见 tray_service.dart）
    if (!Platform.isAndroid && !Platform.isIOS) {
      try {
        await TrayService.instance
            .initDesktop(startHidden: trayStart);
      } catch (e) {
        debugPrint('desktop init failed: $e');
      }
      // 全局「双击 Ctrl」呼出快捷搜索浮窗（仅 Windows：GetAsyncKeyState 轮询）
      if (Platform.isWindows) {
        HotkeyService.instance.onDoubleCtrl = () =>
            unawaited(WindowModeService.instance.togglePopup());
        QuickSearchActions.onEnabledChanged = (enabled) {
          if (enabled) {
            HotkeyService.instance.start();
          } else {
            HotkeyService.instance.stop();
          }
        };
        HotkeyService.instance.start();
      }
    }
  }

  runApp(const MyApp());

  // ===== 守护进程深链（weimi_daemon.exe 拉起 UI 时带参）=====
  // --page=transfer：点收包通知 → 打开传输记录页
  // --page=popup  ：双击 Ctrl → 直接进快捷搜索浮窗（守护进程浮窗会话）
  final deepTransfer = args.contains('--page=transfer');
  final deepPopup = args.contains('--page=popup');
  if (deepPopup) {
    WindowModeService.instance.popupMode.value = true;
    WindowModeService.daemonPopupSession = true;
    WindowModeService.onPopupDismissed = () =>
        TrayService.instance.handOffToDaemon();
    // 冷启路径：窗口一起动就上屏会先露一手空白再切小窗。
    // 先藏住，等首帧渲染完由下方 showPopup() 统一 show。
    try {
      await windowManager.hide();
    } catch (_) {}
  }
  if (deepTransfer) {
    unawaited(() async {
      await WidgetsBinding.instance.endOfFrame;
      try {
        final ctx = ShareReceiveService.navigatorKey.currentContext;
        if (ctx != null) {
        Navigator.of(ctx).push(MaterialPageRoute(
            builder: (_) => const LanTransferScreen()));
        }
      } catch (_) {}
    }());
  }
  if (deepPopup) {
    unawaited(() async {
      await WidgetsBinding.instance.endOfFrame;
      try {
        await WindowModeService.instance.showPopup();
      } catch (_) {}
    }());
  }
  // 合并守护进程期间的收包记录进传输历史（按偏移增量，幂等）
  if (Platform.isWindows) {
    unawaited(DaemonService.mergeDaemonHistory());
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late Future<LocalizationService> _localizationService;

  @override
  void initState() {
    super.initState();
    _localizationService = LocalizationService.getInstance();
    // 语言模块挂接整机刷新回调：设置中心切语言后 UI 立即生效
    final lang = ModuleRegistry.module('language');
    if (lang is LanguageModule) lang.onLanguageChanged = _onLanguageChanged;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LocalizationService>(
      future: _localizationService,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return MaterialApp(
            title: '微密文件',
            home: const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        final localizationService = snapshot.data!;

        return MaterialApp(
          title: localizationService.translate('appTitle'),
          navigatorKey: ShareReceiveService.navigatorKey,
          locale: localizationService.currentLocale,
          localizationsDelegates: const [],
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
            useMaterial3: true,
          ),
          home: ValueListenableBuilder<bool>(
            valueListenable: WindowModeService.instance.popupMode,
            builder: (ctx, popup, _) => popup
                ? const QuickSearchPopup()
                : HomePage(
                    localizationService: localizationService,
                    onLanguageChanged: _onLanguageChanged,
                  ),
          ),
        );
      },
    );
  }

  void _onLanguageChanged() {
    setState(() {
      _localizationService = LocalizationService.getInstance();
    });
  }
}

class HomePage extends StatefulWidget {
  final LocalizationService localizationService;
  final VoidCallback onLanguageChanged;

  const HomePage({
    super.key,
    required this.localizationService,
    required this.onLanguageChanged,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  int _currentTab = 0;
  bool _isProcessing = false;
  bool _isDragging = false;
  late TabController _tabController;
  final GlobalKey<WeiMiVaultScreenState> _filesKey =
      GlobalKey<WeiMiVaultScreenState>();

  // Helper to get translations
  String t(String key) => widget.localizationService.translate(key);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_currentTab != _tabController.index) {
        setState(() => _currentTab = _tabController.index);
      }
    });
    _checkInitialFile();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退到后台时飞传无法弹确认框：信任设备直收、非信任拒收
    LanTransferService.instance.backgroundMode =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    if (Platform.isAndroid) {
      _cleanupFilePickerCache();
    }
    super.dispose();
  }

  Future<void> _cleanupFilePickerCache() async {
    try {
      await FilePicker.platform.clearTemporaryFiles();
    } catch (e) {
      debugPrint('Failed to clear file_picker cache: $e');
    }
  }

  Future<void> _checkInitialFile() async {
    final filePath = await FileAssociationService.getInitialFile();
    // 跳过命令行旗标（--page=transfer / --page=popup 等深链参数）
    if (filePath != null &&
        filePath.isNotEmpty &&
        !filePath.startsWith('-')) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) {
        _openFile(filePath);
      }
    }
  }

  Future<void> _openFile(String filePath) async {
    if (_isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      final fileExists =
          FileSystemEntity.typeSync(filePath) != FileSystemEntityType.notFound;
      if (!fileExists) {
        _showMessage('${t('fileNotFound')}$filePath', isError: true);
        setState(() => _isProcessing = false);
        return;
      }

      final isEncrypted = await EncryptionService.isEncryptedFile(filePath);
      String? password;

      if (isEncrypted) {
        final hint = await EncryptionService.getPasswordHint(filePath);
        password = await _showPasswordDialog(hint: hint);
        if (password == null) {
          setState(() => _isProcessing = false);
          return;
        }
      }

      if (mounted) {
        await FileViewerService.openFile(
          context,
          filePath,
          password: password,
          isEncrypted: isEncrypted,
        );
      }
    } catch (e) {
      _showMessage('${t('openFileFailed')}$e', isError: true);
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  Future<Map<String, String?>?> _showEncryptPasswordDialog() async {
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    final hintController = TextEditingController();

    return showDialog<Map<String, String?>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(t('setPassword')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: passwordController,
                obscureText: true,
                maxLength: kPasswordMaxLength,
                decoration: InputDecoration(
                  labelText: t('password'),
                  hintText: t('passwordPlaceholder'),
                  counterText: t('passwordLengthHint'),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: confirmController,
                obscureText: true,
                maxLength: kPasswordMaxLength,
                decoration: InputDecoration(
                  labelText: t('confirmPassword'),
                  hintText: t('confirmPasswordPlaceholder'),
                  counterText: t('passwordLengthHint'),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: hintController,
                decoration: InputDecoration(
                  labelText: t('passwordHint'),
                  hintText: t('passwordHintPlaceholder'),
                ),
                maxLength: 32,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('cancel')),
            ),
            TextButton(
              onPressed: () {
                if (passwordController.text.isEmpty) {
                  _showMessage(t('passwordEmpty'), isError: true);
                  return;
                }
                final passwordLength = passwordController.text.length;
                if (passwordLength < kPasswordMinLength ||
                    passwordLength > kPasswordMaxLength) {
                  _showMessage(t('passwordLengthInvalid'), isError: true);
                  return;
                }
                if (passwordController.text != confirmController.text) {
                  _showMessage(t('passwordMismatch'), isError: true);
                  return;
                }
                Navigator.pop(context, {
                  'password': passwordController.text,
                  'hint': hintController.text.isNotEmpty
                      ? hintController.text
                      : null,
                });
              },
              child: Text(t('confirm')),
            ),
          ],
        );
      },
    );
  }

  Future<String?> _showPasswordDialog({String? hint}) async {
    final passwordController = TextEditingController();

    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(t('enterPassword')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hint != null && hint.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.lightbulb_outline,
                        color: Colors.blue.shade700,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${t('hint')}$hint',
                          style: TextStyle(
                            color: Colors.blue.shade700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: passwordController,
                obscureText: true,
                maxLength: kPasswordMaxLength,
                decoration: InputDecoration(
                  labelText: t('password'),
                  hintText: t('passwordPlaceholder'),
                  counterText: t('passwordLengthHint'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('cancel')),
            ),
            TextButton(
              onPressed: () {
                if (passwordController.text.isEmpty) {
                  _showMessage(t('passwordEmpty'), isError: true);
                  return;
                }
                final passwordLength = passwordController.text.length;
                if (passwordLength < kPasswordMinLength ||
                    passwordLength > kPasswordMaxLength) {
                  _showMessage(t('passwordLengthInvalid'), isError: true);
                  return;
                }
                Navigator.pop(context, passwordController.text);
              },
              child: Text(t('confirm')),
            ),
          ],
        );
      },
    );
  }

  // ============ 删除原文件对话框 ============

  /// 加密完成后弹出"是否删除原始文件"对话框
  Future<void> _showDeleteOriginalDialog(
      List<Map<String, String>> encryptResults) async {
    if (encryptResults.isEmpty) return;

    final savedPref = await DeletePreferenceService.getSavedPreference();
    if (savedPref != null) {
      await _executeDelete(encryptResults, savedPref, rememberChoice: false);
      return;
    }

    if (!mounted) return;

    DeleteAction? selectedAction;
    bool rememberChoice = false;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(t('encryptSuccess')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t('deleteOriginalFileQuestion')),
                  const SizedBox(height: 8),
                  Text(
                    '${t('encryptedFileCount')}: ${encryptResults.length}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Checkbox(
                        value: rememberChoice,
                        onChanged: (v) {
                          setDialogState(() {
                            rememberChoice = v ?? false;
                          });
                        },
                      ),
                      GestureDetector(
                        onTap: () {
                          setDialogState(() {
                            rememberChoice = !rememberChoice;
                          });
                        },
                        child: Text(t('rememberMyChoice')),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    selectedAction = DeleteAction.keep;
                    Navigator.pop(dialogContext, true);
                  },
                  child: Text(t('keep')),
                ),
                TextButton(
                  onPressed: () {
                    selectedAction = DeleteAction.recycleBin;
                    Navigator.pop(dialogContext, true);
                  },
                  child: Text(t('moveToRecycleBin')),
                ),
                TextButton(
                  onPressed: () async {
                    final secondConfirm = await showDialog<bool>(
                      context: dialogContext,
                      builder: (ctx) => AlertDialog(
                        title: Text(t('permanentDeleteWarning')),
                        content: Text(t('permanentDeleteConfirm')),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: Text(t('cancel')),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: Text(t('confirm')),
                          ),
                        ],
                      ),
                    );
                    if (secondConfirm == true) {
                      selectedAction = DeleteAction.permanent;
                      if (dialogContext.mounted) {
                        Navigator.pop(dialogContext, true);
                      }
                    }
                  },
                  child: Text(
                    t('permanentDelete'),
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed == true && selectedAction != null) {
      await DeletePreferenceService.savePreference(
          rememberChoice, selectedAction);
      await _executeDelete(encryptResults, selectedAction!,
          rememberChoice: rememberChoice);
    }
  }

  /// 执行文件删除操作
  Future<void> _executeDelete(
    List<Map<String, String>> encryptResults,
    DeleteAction action, {
    required bool rememberChoice,
  }) async {
    if (action == DeleteAction.keep) return;

    int deletedCount = 0;
    for (final result in encryptResults) {
      final originalPath = result['originalPath']!;
      final identifier = result['identifier'] ?? '';
      try {
        final ok = await FileOperationsService.deleteOriginal(
          originalPath,
          identifier: identifier.isEmpty ? null : identifier,
        );
        if (ok) deletedCount++;
      } catch (e) {
        debugPrint('Failed to delete $originalPath: $e');
      }
    }
    if (deletedCount > 0 && mounted) {
      _showMessage('${t('deletedFiles')}: $deletedCount');
    }
  }

  // ============ 拖拽处理 ============

  Future<void> _handleDroppedFiles(List<XFile> files) async {
    if (_isProcessing || files.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _isDragging = false;
    });

    try {
      final decryptFiles = <String>[];
      final packDirs = <String>[];
      final encryptFiles = <String>[];

      for (final xfile in files) {
        final path = xfile.path;
        if (await FileSystemEntity.isDirectory(path)) {
          packDirs.add(path);
        } else if (path.toLowerCase().endsWith('.wemi')) {
          decryptFiles.add(path);
        } else {
          final isEnc = await EncryptionService.isEncryptedFile(path);
          if (isEnc) {
            decryptFiles.add(path);
          } else {
            encryptFiles.add(path);
          }
        }
      }

      for (final dir in packDirs) {
        if (!mounted) return;
        await _filesKey.currentState?.packFolderFlow(dir);
      }
      if (decryptFiles.isNotEmpty) {
        await _processDecryptFiles(decryptFiles);
      }
      if (encryptFiles.isNotEmpty) {
        await _processEncryptFiles(
            encryptFiles.map((p) => {'path': p, 'identifier': null}).toList());
      }
    } catch (e) {
      _showMessage('${t('dropProcessFailed')}$e', isError: true);
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  /// 选择输出目录：优先「加密文件存放目录」（用户设置过则默认直接用），
  /// 其次上次选择，都没有时打开目录选择器。成功选择后记录为「上次位置」。
  Future<String?> _chooseOutputDirectory() async {
    final prefs = await SharedPreferences.getInstance();

    // 加密文件存放目录优先
    final vaultDir = prefs.getString('weimi_vault_dir');
    if (vaultDir != null && vaultDir.isNotEmpty) {
      try {
        if (await Directory(vaultDir).exists()) return vaultDir;
      } catch (_) {}
    }

    final lastDir = prefs.getString(kLastOutputDirKey);

    if (lastDir != null &&
        lastDir.isNotEmpty &&
        await Directory(lastDir).exists()) {
      if (!mounted) return null;
      final useLast = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t('selectOutputDirectory')),
          content: Text('${t('lastLocation')}: $lastDir'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t('chooseOtherLocation')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t('useLastLocation')),
            ),
          ],
        ),
      );
      if (useLast == true) return lastDir;
    }

    final dir = await FileOperationsService.pickOutputDirectory();
    if (dir != null && dir.isNotEmpty) {
      await prefs.setString(kLastOutputDirKey, dir);
    }
    return dir;
  }

  Future<void> _processEncryptFiles(
      List<Map<String, String?>> pickedFiles) async {
    final result = await _showEncryptPasswordDialog();
    if (result == null) return;

    if (!mounted) return;

    // 已设置「加密文件存放目录」时直接使用，不再询问输出位置
    final prefs = await SharedPreferences.getInstance();
    final vaultDir = prefs.getString('weimi_vault_dir');
    var hasVaultDir = false;
    if (vaultDir != null && vaultDir.isNotEmpty) {
      try {
        hasVaultDir = await Directory(vaultDir).exists();
      } catch (_) {}
    }

    String? outputDirectory;
    if (hasVaultDir && vaultDir != null) {
      outputDirectory = vaultDir;
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: Text(t('selectOutputDirectory')),
            content: Text(
                '${t('aboutToEncrypt')}${pickedFiles.length}${t('filesSelectOutputDir')}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(t('cancel')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(t('confirm')),
              ),
            ],
          );
        },
      );

      if (confirmed != true) return;

      outputDirectory = await _chooseOutputDirectory();
      if (outputDirectory == null) return;
    }

    final encryptResults = <Map<String, String>>[];
    final historyRecords = <HistoryRecord>[];
    final now = DateTime.now();

    for (int i = 0; i < pickedFiles.length; i++) {
      final filePath = pickedFiles[i]['path']!;
      final fileIdentifier = pickedFiles[i]['identifier'] ?? '';
      final fileName = filePath.split(Platform.pathSeparator).last;

      if (mounted) {
        if (i == 0) {
          ProgressDialog.show(
            context,
            title: t('batchEncrypt'),
            currentProgress: i,
            totalProgress: pickedFiles.length,
            currentFileName: fileName,
          );
        } else {
          ProgressDialog.update(
            context,
            title: t('batchEncrypt'),
            currentProgress: i,
            totalProgress: pickedFiles.length,
            currentFileName: fileName,
          );
        }
      }

      try {
        final isEncrypted =
            await EncryptionService.isEncryptedFile(filePath);
        if (isEncrypted) continue;

        await FileOperationsService.encryptFile(
          filePath,
          outputDirectory,
          result['password']!,
          hint: result['hint'],
        );

        final outputName =
            EncryptionService.addEncryptedExtension(fileName);
        final encryptedPath =
            '$outputDirectory${Platform.pathSeparator}$outputName';

        encryptResults.add({
          'originalPath': filePath,
          'encryptedPath': encryptedPath,
          'identifier': fileIdentifier,
          'hint': result['hint'] ?? '',
        });

        historyRecords.add(HistoryRecord(
          id: now.millisecondsSinceEpoch + i,
          filePath: filePath,
          operation: 'encrypt',
          timestamp: now.toIso8601String(),
          hint: result['hint'] ?? '',
          encryptedPath: encryptedPath,
          status: 'success',
        ));
      } catch (e) {
        continue;
      }
    }

    if (mounted) {
      ProgressDialog.hide(context);
      _showMessage(
          '${t('encryptCompleted')}${encryptResults.length}${t('filesSuccess')}');
    }

    if (historyRecords.isNotEmpty) {
      await HistoryService.addRecords(historyRecords);
    }

    if (encryptResults.isNotEmpty && mounted) {
      await _showDeleteOriginalDialog(encryptResults);
    }
  }

  Future<void> _processDecryptFiles(List<String> filePaths) async {
    final encryptedFiles = <String>[];
    final archiveFiles = <String>[];
    for (final filePath in filePaths) {
      // 归档容器（WEMI_FARC）走独立解包流程（列清单/勾选/进度）
      if (await EncryptionService.isArchiveFile(filePath)) {
        archiveFiles.add(filePath);
        continue;
      }
      final isEncrypted = await EncryptionService.isEncryptedFile(filePath);
      if (isEncrypted) {
        encryptedFiles.add(filePath);
      } else {
        _showMessage(
          '${filePath.split(Platform.pathSeparator).last} ${t('notEncryptedFile')}',
          isError: true,
        );
      }
    }

    for (final archivePath in archiveFiles) {
      if (!mounted) return;
      await _filesKey.currentState?.openArchiveFlow(archivePath);
    }

    if (encryptedFiles.isEmpty) return;

    final firstFilePath = encryptedFiles[0];
    final hint = await EncryptionService.getPasswordHint(firstFilePath);
    final password = await _showPasswordDialog(hint: hint);
    if (password == null) return;

    final outputDirectory = await _chooseOutputDirectory();
    if (outputDirectory == null) return;

    final historyRecords = <HistoryRecord>[];
    final now = DateTime.now();
    int successFiles = 0;
    int failedFiles = 0;

    for (int i = 0; i < encryptedFiles.length; i++) {
      final filePath = encryptedFiles[i];
      final fileName = filePath.split(Platform.pathSeparator).last;

      if (mounted) {
        if (i == 0) {
          ProgressDialog.show(
            context,
            title: t('batchDecrypt'),
            currentProgress: i,
            totalProgress: encryptedFiles.length,
            currentFileName: fileName,
          );
        } else {
          ProgressDialog.update(
            context,
            title: t('batchDecrypt'),
            currentProgress: i,
            totalProgress: encryptedFiles.length,
            currentFileName: fileName,
          );
        }
      }

      try {
        await FileOperationsService.decryptFile(
          filePath,
          outputDirectory,
          password,
        );
        successFiles++;

        final existingRecord =
            await HistoryService.findByEncryptedPath(filePath);
        final recordHint = existingRecord?.hint ?? '';

        historyRecords.add(HistoryRecord(
          id: now.millisecondsSinceEpoch + i,
          filePath: filePath,
          operation: 'decrypt',
          timestamp: now.toIso8601String(),
          hint: recordHint,
          encryptedPath: filePath,
          status: 'success',
        ));
      } catch (e) {
        failedFiles++;
        final outputName =
            EncryptionService.removeEncryptedExtension(fileName);
        final outputPath =
            '$outputDirectory${Platform.pathSeparator}$outputName';
        final failedFile = File(outputPath);
        if (await failedFile.exists()) {
          try {
            await failedFile.delete();
          } catch (_) {}
        }
      }
    }

    if (mounted) {
      ProgressDialog.hide(context);
      _showMessage(
          '${t('decryptCompleted')}$successFiles${t('failed')}$failedFiles${t('filesCount')}');
    }

    if (historyRecords.isNotEmpty) {
      await HistoryService.addRecords(historyRecords);
    }
  }

  // ============ 按钮处理 ============

  Future<void> _handleOpenFile() async {
    if (_isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      final filePath = await FileOperationsService.pickFile();
      if (filePath == null) {
        setState(() => _isProcessing = false);
        return;
      }

      final isEncrypted = await EncryptionService.isEncryptedFile(filePath);
      String? password;

      if (isEncrypted) {
        final hint = await EncryptionService.getPasswordHint(filePath);
        password = await _showPasswordDialog(hint: hint);
        if (password == null) {
          setState(() => _isProcessing = false);
          return;
        }
      }

      if (mounted) {
        await FileViewerService.openFile(
          context,
          filePath,
          password: password,
          isEncrypted: isEncrypted,
        );
      }
    } catch (e) {
      _showMessage('${t('openFileFailed')}$e', isError: true);
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleEncryptFile() async {
    if (_isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      final pickedFiles = await FileOperationsService.pickMultipleFilesWithOrigin();
      if (pickedFiles.isEmpty) {
        setState(() => _isProcessing = false);
        return;
      }

      await _processEncryptFiles(pickedFiles);
    } catch (e) {
      if (mounted) {
        ProgressDialog.hide(context);
        _showMessage('${t('encryptFailed')}$e', isError: true);
      }
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleDecryptFile() async {
    if (_isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      final filePaths = await FileOperationsService.pickFilesForDecryption();
      if (filePaths.isEmpty) {
        setState(() => _isProcessing = false);
        return;
      }

      await _processDecryptFiles(filePaths);
    } catch (e) {
      if (mounted) {
        ProgressDialog.hide(context);
        _showMessage('${t('decryptFailed')}$e', isError: true);
      }
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  // ============ 构建 UI ============

  @override
  Widget build(BuildContext context) {
    final bool isDesktop = !Platform.isAndroid && !Platform.isIOS;
    final bool supportDragDrop = isDesktop;

    final filesTab = _buildFilesTab();
    final transferTab = LanTransferScreen(standalone: false);
    Widget filesBody = filesTab;
    if (_isProcessing) {
      filesBody = const Center(child: CircularProgressIndicator());
    } else if (supportDragDrop) {
      filesBody = DropTarget(
        onDragDone: (detail) {
          if (!_isProcessing) {
            _handleDroppedFiles(detail.files);
          }
        },
        onDragEntered: (_) => setState(() => _isDragging = true),
        onDragExited: (_) => setState(() => _isDragging = false),
        child: Container(
          decoration: BoxDecoration(
            border: _isDragging
                ? Border.all(color: Colors.blueAccent, width: 3)
                : null,
            color: _isDragging ? Colors.blueAccent.withAlpha(20) : null,
          ),
          child: filesTab,
        ),
      );
    }
    final Widget bodyContent = TabBarView(
      controller: _tabController,
      children: [filesBody, transferTab],
    );

    // 系统返回键：文件页在子目录/多选状态时先内部消化（逐级返回/清选择），
    // 到根视图才放行退出应用
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        final handled = _filesKey.currentState?.handleSystemBack() ?? false;
        if (!handled) {
          SystemNavigator.pop(); // 退出到手机桌面
        }
      },
      child: Scaffold(
      appBar: AppBar(
        // v1.2.18：标题行与 TabBar 合并成一排——当前页签加粗放大做强调，
        // 右上角按钮（加解密历史/菜单）保留在本排右侧
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        titleSpacing: 0,
        title: TabBar(
          controller: _tabController,
          labelStyle:
              const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          unselectedLabelStyle: const TextStyle(fontSize: 14),
          tabs: [
            GestureDetector(
              onDoubleTap: () {}, // 文件页暂不响应双击回顶
              child: const Tab(text: '微密文件'),
            ),
            GestureDetector(
              onDoubleTap: () =>
                  LanTransferScreen.scrollToTopSignal.value++,
              child: const Tab(text: '微密飞传'),
            ),
          ],
        ),
        actions: [
          // 加解密历史（文件页专属；飞传页已自带聊天式历史，无需此入口）
          if (_currentTab == 0)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: '加解密历史',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => const OperationHistoryScreen()),
                );
              },
            ),
          // 竖三点：视图 / 语言 / 关于
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: '更多',
            onSelected: (value) {
              switch (value) {
                case 'view_list':
                  ViewPrefsService.instance.setMode(ViewMode.list);
                  break;
                case 'view_grid':
                  ViewPrefsService.instance.setMode(ViewMode.grid);
                  break;
                case 'view_waterfall':
                  ViewPrefsService.instance.setMode(ViewMode.waterfall);
                  break;
                case 'thumb_small':
                  ViewPrefsService.instance
                      .setThumbSize(ThumbSize.small);
                  break;
                case 'thumb_medium':
                  ViewPrefsService.instance
                      .setThumbSize(ThumbSize.medium);
                  break;
                case 'thumb_large':
                  ViewPrefsService.instance
                      .setThumbSize(ThumbSize.large);
                  break;
                case 'settings':
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => const SettingsScreen()),
                  );
                  break;
                case 'language':
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => LanguageScreen(
                              onLanguageChanged: widget.onLanguageChanged,
                            )),
                  );
                  break;
                case 'vault':
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => const VaultBrowserScreen()),
                  );
                  break;
                case 'about':
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => const AboutScreen()),
                  );
                  break;
              }
            },
            itemBuilder: (ctx) {
              final mode = ViewPrefsService.instance.mode;
              final thumb = ViewPrefsService.instance.thumbSize;
              PopupMenuEntry<String> item(String value, IconData icon,
                  String label,
                  {bool checked = false}) {
                return PopupMenuItem<String>(
                  value: value,
                  child: Row(
                    children: [
                      Icon(icon, size: 20, color: Colors.grey.shade700),
                      const SizedBox(width: 10),
                      Expanded(child: Text(label)),
                      if (checked)
                        const Icon(Icons.check,
                            size: 18, color: Colors.blue),
                    ],
                  ),
                );
              }

              return [
                item('view_list', Icons.view_list, '列表视图',
                    checked: mode == ViewMode.list),
                item('view_grid', Icons.grid_view, '宫格视图',
                    checked: mode == ViewMode.grid),
                item('view_waterfall', Icons.dashboard_outlined, '瀑布流视图',
                    checked: mode == ViewMode.waterfall),
                const PopupMenuDivider(),
                item('thumb_small', Icons.photo_size_select_small,
                    '缩略图：小',
                    checked: thumb == ThumbSize.small),
                item('thumb_medium', Icons.photo_size_select_actual,
                    '缩略图：中',
                    checked: thumb == ThumbSize.medium),
                item('thumb_large', Icons.photo_size_select_large,
                    '缩略图：大',
                    checked: thumb == ThumbSize.large),
                const PopupMenuDivider(),
                item('settings', Icons.settings_outlined, '设置'),
                item('language', Icons.language, t('language')),
                item('vault', Icons.lock_outline, '微密保险箱'),
                item('about', Icons.info_outline, t('about')),
              ];
            },
          ),
        ],
      ),
      body: bodyContent,
      ),
    );
  }

  Widget _buildFilesTab() {
    return WeiMiVaultScreen(
      key: _filesKey,
      showSystemDirs: true,
      onEncryptFiles: _handleEncryptFile,
      onDecryptFiles: _handleDecryptFile,
    );
  }
}
