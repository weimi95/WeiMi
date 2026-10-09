import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';
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
import 'screens/recent_files_screen.dart';
import 'screens/settings_screen.dart';
import 'services/lan_transfer_service.dart';
import 'services/view_prefs_service.dart';
import 'services/share_receive_service.dart';
import 'widgets/file_thumbnail.dart';
import 'package:path_provider/path_provider.dart';

// 密码长度限制常量
const int kPasswordMinLength = 4;
const int kPasswordMaxLength = 32;

// 上次加密/解密输出目录的 SharedPreferences key
const String kLastOutputDirKey = 'last_output_dir';

/// 桌面端窗口关闭拦截：enabled（关闭时最小化到托盘）时点关闭只隐藏窗口
class _WindowCloseHandler extends WindowListener {
  @override
  void onWindowClose() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('desk_close_to_tray') ?? true) {
      await windowManager.hide();
    } else {
      await windowManager.destroy();
    }
  }
}

final _windowCloseHandler = _WindowCloseHandler();

/// 从 assets 解出托盘图标到临时目录（system_tray 需要文件路径）
Future<String?> _extractTrayIcon() async {
  try {
    final dir = await getTemporaryDirectory();
    final name = Platform.isWindows ? 'tray_icon.ico' : 'tray_icon.png';
    final data = await rootBundle.load('assets/images/$name');
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    await f.writeAsBytes(data.buffer.asUint8List());
    return f.path;
  } catch (e) {
    debugPrint('extract tray icon failed: $e');
    return null;
  }
}

/// 初始化系统托盘（桌面端）：左键显示主窗口，右键菜单 显示/退出
Future<void> _initSystemTray() async {
  try {
    final iconPath = await _extractTrayIcon();
    if (iconPath == null) return;
    final tray = SystemTray();
    await tray.initSystemTray(
      title: '微密文件',
      iconPath: iconPath,
      toolTip: '微密文件',
    );
    final menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: '显示主窗口', onClicked: (_) async {
        await windowManager.show();
        await windowManager.focus();
      }),
      MenuItemLabel(label: '设置', onClicked: (_) async {
        await windowManager.show();
        await windowManager.focus();
        final ctx = ShareReceiveService.navigatorKey.currentContext;
        if (ctx != null) {
          Navigator.push(ctx,
              MaterialPageRoute(builder: (_) => const SettingsScreen()));
        }
      }),
      MenuItemLabel(label: '关于', onClicked: (_) async {
        await windowManager.show();
        await windowManager.focus();
        final ctx = ShareReceiveService.navigatorKey.currentContext;
        if (ctx != null) {
          Navigator.push(ctx,
              MaterialPageRoute(builder: (_) => const AboutScreen()));
        }
      }),
      MenuSeparator(),
      MenuItemLabel(label: '退出', onClicked: (_) async {
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
      }),
    ]);
    await tray.setContextMenu(menu);
    tray.registerSystemTrayEventHandler((eventName) {
      if (eventName == kSystemTrayEventClick) {
        windowManager.show();
        windowManager.focus();
      }
    });
  } catch (e) {
    debugPrint('init system tray failed: $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize localization service before running the app
  await LocalizationService.getInstance();

  // 加载全局视图偏好（列表/宫格/瀑布流）
  await ViewPrefsService.instance.load();

  // 局域网接收文件的兜底目录（用户未设置加密目录时用）
  try {
    final docs = await getApplicationDocumentsDirectory();
    LanTransferService.instance.fallbackDir = docs.path;
  } catch (_) {}

  // 启动时自动开启微密飞传接收（设置项）
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('lan_autostart') == true) {
      LanTransferService.instance.startReceiving();
    }
  } catch (_) {}

  // 系统分享接收（Android SEND/SEND_MULTIPLE → 飞传页）
  await ShareReceiveService.instance.init();

  if (Platform.isWindows) {
    await FileAssociationService.registerFileAssociation();
  }

  // 桌面端：窗口管理（关闭最小化到托盘）+ 系统托盘
  if (!Platform.isAndroid && !Platform.isIOS) {
    try {
      await windowManager.ensureInitialized();
      const opts = WindowOptions(
        size: Size(1100, 800),
        minimumSize: Size(700, 500),
        title: '微密文件',
      );
      final prefs = await SharedPreferences.getInstance();
      final closeToTray = prefs.getBool('desk_close_to_tray') ?? true;
      await windowManager.waitUntilReadyToShow(opts, () async {
        await windowManager.show();
        await windowManager.setPreventClose(closeToTray);
      });
      windowManager.addListener(_windowCloseHandler);
      _initSystemTray();
    } catch (e) {
      debugPrint('window/tray init failed: $e');
    }
  }

  runApp(const MyApp());
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
          home: HomePage(
            localizationService: localizationService,
            onLanguageChanged: _onLanguageChanged,
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

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _currentTab = 0;
  bool _isProcessing = false;
  bool _isDragging = false;
  final GlobalKey<RecentFilesScreenState> _recentKey =
      GlobalKey<RecentFilesScreenState>();
  final GlobalKey<WeiMiVaultScreenState> _filesKey =
      GlobalKey<WeiMiVaultScreenState>();

  // Helper to get translations
  String t(String key) => widget.localizationService.translate(key);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    if (filePath != null && filePath.isNotEmpty) {
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
      final fileExists = await File(filePath).exists();
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
      final encryptFiles = <String>[];

      for (final xfile in files) {
        final path = xfile.path;
        if (path.toLowerCase().endsWith('.wemi')) {
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
    for (final filePath in filePaths) {
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

    Widget bodyContent;
    switch (_currentTab) {
      case 0:
        bodyContent = _buildRecentTab();
        break;
      case 1:
      default:
        bodyContent = _buildFilesTab();
    }

    // 系统返回键：文件页在子目录/多选状态时先内部消化（逐级返回/清选择），
    // 到根视图才放行退出应用
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        final handled =
            _currentTab == 1 && (_filesKey.currentState?.handleSystemBack() ?? false);
        if (!handled) {
          SystemNavigator.pop(); // 退出到手机桌面
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(t('appTitle'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // 竖三点：筛选 / 视图 / 日期分区 / 语言 / 关于
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: '更多',
            onSelected: (value) {
              switch (value) {
                case 'filter':
                  _showFilterSheet();
                  break;
                case 'view_list':
                  ViewPrefsService.instance.setMode(ViewMode.list);
                  break;
                case 'view_grid':
                  ViewPrefsService.instance.setMode(ViewMode.grid);
                  break;
                case 'view_waterfall':
                  ViewPrefsService.instance.setMode(ViewMode.waterfall);
                  break;
                case 'group_none':
                  ViewPrefsService.instance.setGroup(GroupMode.none);
                  break;
                case 'group_day':
                  ViewPrefsService.instance.setGroup(GroupMode.day);
                  break;
                case 'group_month':
                  ViewPrefsService.instance.setGroup(GroupMode.month);
                  break;
                case 'group_year':
                  ViewPrefsService.instance.setGroup(GroupMode.year);
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
              final group = ViewPrefsService.instance.group;
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
                PopupMenuItem(
                  value: 'filter',
                  child: Row(
                    children: [
                      const Icon(Icons.filter_list,
                          size: 20, color: Colors.grey),
                      const SizedBox(width: 10),
                      const Expanded(child: Text('按类型筛选')),
                      if (_recentKey.currentState?.filter !=
                          FileCategory.all)
                        const Icon(Icons.circle,
                            size: 8, color: Colors.blue),
                    ],
                  ),
                ),
                item('view_list', Icons.view_list, '列表视图',
                    checked: mode == ViewMode.list),
                item('view_grid', Icons.grid_view, '宫格视图',
                    checked: mode == ViewMode.grid),
                item('view_waterfall', Icons.dashboard_outlined, '瀑布流视图',
                    checked: mode == ViewMode.waterfall),
                // 最近页日期分区
                item('group_none', Icons.calendar_today_outlined, '最近页：不分区',
                    checked: group == GroupMode.none),
                item('group_day', Icons.today_outlined, '最近页：按天分区',
                    checked: group == GroupMode.day),
                item('group_month', Icons.date_range_outlined, '最近页：按月分区',
                    checked: group == GroupMode.month),
                item('group_year', Icons.calendar_view_month_outlined,
                    '最近页：按年分区',
                    checked: group == GroupMode.year),
                const PopupMenuDivider(),
                item('settings', Icons.settings_outlined, '设置'),
                item('language', Icons.language, t('language')),
                item('about', Icons.info_outline, t('about')),
              ];
            },
          ),
        ],
      ),
      body: supportDragDrop
          ? DropTarget(
              onDragDone: (detail) {
                if (!_isProcessing) {
                  _handleDroppedFiles(detail.files);
                }
              },
              onDragEntered: (detail) {
                setState(() => _isDragging = true);
              },
              onDragExited: (detail) {
                setState(() => _isDragging = false);
              },
              child: Container(
                decoration: BoxDecoration(
                  border: _isDragging
                      ? Border.all(color: Colors.blueAccent, width: 3)
                      : null,
                  color: _isDragging
                      ? Colors.blueAccent.withAlpha(20)
                      : null,
                ),
                child: _isProcessing
                    ? const Center(child: CircularProgressIndicator())
                    : bodyContent,
              ),
            )
          : _isProcessing
              ? const Center(child: CircularProgressIndicator())
              : bodyContent,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTab,
        onTap: (index) {
          setState(() => _currentTab = index);
        },
        type: BottomNavigationBarType.fixed,
        items: [
          BottomNavigationBarItem(
            icon: const Icon(Icons.access_time),
            label: t('tabRecent'),
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.folder),
            label: t('tabFiles'),
          ),
        ],
      ),
      ),
    );
  }

  /// 类型筛选弹窗（作用于「最近」页）
  void _showFilterSheet() {
    final current = _recentKey.currentState?.filter ?? FileCategory.all;
    showModalBottomSheet<FileCategory>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('按类型筛选',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: const Icon(Icons.apps),
              title: const Text('全部'),
              trailing: current == FileCategory.all
                  ? const Icon(Icons.check, color: Colors.blue)
                  : null,
              onTap: () => Navigator.pop(ctx, FileCategory.all),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined, color: Colors.teal),
              title: const Text('图片'),
              trailing: current == FileCategory.image
                  ? const Icon(Icons.check, color: Colors.blue)
                  : null,
              onTap: () => Navigator.pop(ctx, FileCategory.image),
            ),
            ListTile(
              leading: const Icon(Icons.movie_outlined, color: Colors.purple),
              title: const Text('视频'),
              trailing: current == FileCategory.video
                  ? const Icon(Icons.check, color: Colors.blue)
                  : null,
              onTap: () => Navigator.pop(ctx, FileCategory.video),
            ),
            ListTile(
              leading: const Icon(Icons.music_note_outlined, color: Colors.pink),
              title: const Text('音频'),
              trailing: current == FileCategory.audio
                  ? const Icon(Icons.check, color: Colors.blue)
                  : null,
              onTap: () => Navigator.pop(ctx, FileCategory.audio),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined, color: Colors.blue),
              title: const Text('文档'),
              trailing: current == FileCategory.doc
                  ? const Icon(Icons.check, color: Colors.blue)
                  : null,
              onTap: () => Navigator.pop(ctx, FileCategory.doc),
            ),
            ListTile(
              leading: const Icon(Icons.folder_zip_outlined,
                  color: Color(0xFFB8860B)),
              title: const Text('压缩包'),
              trailing: current == FileCategory.archive
                  ? const Icon(Icons.check, color: Colors.blue)
                  : null,
              onTap: () => Navigator.pop(ctx, FileCategory.archive),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined,
                  color: Colors.grey),
              title: const Text('其他'),
              trailing: current == FileCategory.other
                  ? const Icon(Icons.check, color: Colors.blue)
                  : null,
              onTap: () => Navigator.pop(ctx, FileCategory.other),
            ),
          ],
        ),
      ),
    ).then((c) {
      if (c != null && mounted) {
        _recentKey.currentState?.setFilter(c);
        setState(() => _currentTab = 0); // 筛选后切回最近页展示效果
      }
    });
  }

  Widget _buildRecentTab() {
    // 固定搜索框在 RecentFilesScreen 内部，快捷操作卡已移至「文件」页
    return RecentFilesScreen(
      key: _recentKey,
      translate: t,
      onOpenFile: _openFile,
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
