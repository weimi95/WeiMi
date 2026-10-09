import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
import 'services/lan_transfer_service.dart';
import 'services/view_prefs_service.dart';
import 'widgets/file_thumbnail.dart';
import 'package:path_provider/path_provider.dart';

// 密码长度限制常量
const int kPasswordMinLength = 4;
const int kPasswordMaxLength = 32;

// 上次加密/解密输出目录的 SharedPreferences key
const String kLastOutputDirKey = 'last_output_dir';

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

  if (Platform.isWindows) {
    await FileAssociationService.registerFileAssociation();
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

  // Helper to get translations
  String t(String key) => widget.localizationService.translate(key);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkInitialFile();
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

    return Scaffold(
      appBar: AppBar(
        title: Text(t('appTitle')),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // 搜索（最近页文件名过滤）
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '搜索',
            onPressed: _recentKey.currentState?.toggleSearch,
          ),
          // 类型筛选
          IconButton(
            icon: const Icon(Icons.filter_list),
            tooltip: '筛选',
            onPressed: _showFilterSheet,
          ),
          // 视图切换（列表 → 宫格 → 瀑布流）
          AnimatedBuilder(
            animation: ViewPrefsService.instance,
            builder: (context, _) {
              final m = ViewPrefsService.instance.mode;
              final (icon, tip) = switch (m) {
                ViewMode.list => (Icons.grid_view, '宫格视图'),
                ViewMode.grid => (Icons.dashboard_outlined, '瀑布流视图'),
                ViewMode.waterfall => (Icons.view_list, '列表视图'),
              };
              return IconButton(
                icon: Icon(icon),
                tooltip: tip,
                onPressed: () => ViewPrefsService.instance.cycle(),
              );
            },
          ),
          // 竖三点：语言 / 关于
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: '更多',
            onSelected: (value) {
              if (value == 'language') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => LanguageScreen(
                            onLanguageChanged: widget.onLanguageChanged,
                          )),
                );
              } else if (value == 'about') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => const AboutScreen()),
                );
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'language',
                child: Row(
                  children: [
                    const Icon(Icons.language, size: 20),
                    const SizedBox(width: 10),
                    Text(t('language')),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'about',
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 20),
                    const SizedBox(width: 10),
                    Text(t('about')),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      drawer: isDesktop
          ? Drawer(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  DrawerHeader(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.inversePrimary,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.folder_special,
                          size: 60,
                          color: Colors.blueAccent,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          t('appTitle'),
                          style: const TextStyle(
                              fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.language),
                    title: Text(t('language')),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (context) => LanguageScreen(
                                  onLanguageChanged:
                                      widget.onLanguageChanged,
                                )),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(t('about')),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (context) => const AboutScreen()),
                      );
                    },
                  ),
                ],
              ),
            )
          : null,
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
    return Column(
      children: [
        // 快速操作区（紧凑一行）
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: _buildActionCard(
                  icon: Icons.lock,
                  label: t('encryptFile'),
                  color: Colors.orange,
                  onTap: _handleEncryptFile,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildActionCard(
                  icon: Icons.lock_open,
                  label: t('decryptFile'),
                  color: Colors.green,
                  onTap: _handleDecryptFile,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildActionCard(
                  icon: Icons.folder_open,
                  label: t('openFile'),
                  color: Colors.blue,
                  onTap: _handleOpenFile,
                ),
              ),
            ],
          ),
        ),
        // 全部文件列表（最近修改在前）
        Expanded(
          child: RecentFilesScreen(
            key: _recentKey,
            translate: t,
            onOpenFile: _openFile,
          ),
        ),
      ],
    );
  }

  Widget _buildActionCard({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withAlpha(15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(50)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: color),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilesTab() {
    return const WeiMiVaultScreen(showSystemDirs: true);
  }
}
