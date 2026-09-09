import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
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

// 密码长度限制常量
const int kPasswordMinLength = 4;
const int kPasswordMaxLength = 32;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize localization service before running the app
  await LocalizationService.getInstance();

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
  List<HistoryRecord> _recentHistory = [];

  // Helper to get translations
  String t(String key) => widget.localizationService.translate(key);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkInitialFile();
    _loadHistory();
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

  Future<void> _loadHistory() async {
    try {
      final records = await HistoryService.getRecentRecords();
      if (mounted) {
        setState(() {
          _recentHistory = records;
        });
      }
    } catch (e) {
      debugPrint('Failed to load history: $e');
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
      try {
        final file = File(originalPath);
        if (await file.exists()) {
          await file.delete();
          deletedCount++;
        }
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
        await _processEncryptFiles(encryptFiles);
      }
    } catch (e) {
      _showMessage('${t('dropProcessFailed')}$e', isError: true);
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _processEncryptFiles(List<String> filePaths) async {
    final result = await _showEncryptPasswordDialog();
    if (result == null) return;

    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(t('selectOutputDirectory')),
          content: Text(
              '${t('aboutToEncrypt')}${filePaths.length}${t('filesSelectOutputDir')}'),
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

    final outputDirectory = await FileOperationsService.pickOutputDirectory();
    if (outputDirectory == null) return;

    final encryptResults = <Map<String, String>>[];
    final historyRecords = <HistoryRecord>[];
    final now = DateTime.now();

    for (int i = 0; i < filePaths.length; i++) {
      final filePath = filePaths[i];
      final fileName = filePath.split(Platform.pathSeparator).last;

      if (mounted) {
        if (i == 0) {
          ProgressDialog.show(
            context,
            title: t('batchEncrypt'),
            currentProgress: i,
            totalProgress: filePaths.length,
            currentFileName: fileName,
          );
        } else {
          ProgressDialog.update(
            context,
            title: t('batchEncrypt'),
            currentProgress: i,
            totalProgress: filePaths.length,
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
      await _loadHistory();
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

    final outputDirectory = await FileOperationsService.pickOutputDirectory();
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
      await _loadHistory();
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
      final filePaths = await FileOperationsService.pickMultipleFiles();
      if (filePaths.isEmpty) {
        setState(() => _isProcessing = false);
        return;
      }

      await _processEncryptFiles(filePaths);
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

  // ============ 历史 ============

  Future<void> _handleClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('clearHistory')),
        content: Text(t('clearHistoryConfirm')),
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

    if (confirmed == true) {
      await HistoryService.clearAll();
      await _loadHistory();
      if (mounted) {
        _showMessage(t('historyCleared'));
      }
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
        bodyContent = _buildEncryptTab();
        break;
      case 1:
        bodyContent = _buildVaultTab();
        break;
      case 2:
        bodyContent = _buildHistoryTab();
        break;
      default:
        bodyContent = _buildEncryptTab();
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(t('appTitle')),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.language),
            tooltip: t('language'),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (context) => LanguageScreen(
                          onLanguageChanged: widget.onLanguageChanged,
                        )),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: t('about'),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (context) => const AboutScreen()),
              );
            },
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
          if (index == 2) _loadHistory();
        },
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.lock_open),
            label: '加密',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.folder),
            label: '文件',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history),
            label: '历史',
          ),
        ],
      ),
    );
  }

  Widget _buildEncryptTab() {
    final bool isDesktop = !Platform.isAndroid && !Platform.isIOS;

    return Column(
      children: [
        Expanded(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.folder_special,
                  size: 100,
                  color: Colors.blueAccent,
                ),
                const SizedBox(height: 48),
                _buildMenuButton(
                  icon: Icons.folder_open,
                  label: t('openFile'),
                  onPressed: _handleOpenFile,
                ),
                const SizedBox(height: 16),
                _buildMenuButton(
                  icon: Icons.lock,
                  label: t('encryptFile'),
                  onPressed: _handleEncryptFile,
                ),
                const SizedBox(height: 16),
                _buildMenuButton(
                  icon: Icons.lock_open,
                  label: t('decryptFile'),
                  onPressed: _handleDecryptFile,
                ),
                if (isDesktop) ...[
                  const SizedBox(height: 24),
                  Icon(
                    Icons.cloud_upload_outlined,
                    size: 32,
                    color: Colors.grey.shade400,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t('dragDropHint'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade400,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        _buildHistorySection(),
      ],
    );
  }

  Widget _buildVaultTab() {
    return const WeiMiVaultScreen(showSystemDirs: true);
  }

  Widget _buildHistoryTab() {
    if (_recentHistory.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('暂无历史记录', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${t('recentHistory')} (${_recentHistory.length})',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              TextButton.icon(
                onPressed: _handleClearHistory,
                icon: const Icon(Icons.delete_sweep, size: 18),
                label: Text(t('clearAll')),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: _recentHistory.length,
            separatorBuilder: (_, __) =>
                Divider(height: 1, color: Colors.grey.shade200),
            itemBuilder: (context, index) {
              final record = _recentHistory[index];
              return _buildHistoryItem(record);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildHistorySection() {
    if (_recentHistory.isEmpty) return const SizedBox.shrink();

    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  t('recentHistory'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade700,
                  ),
                ),
                TextButton.icon(
                  onPressed: _handleClearHistory,
                  icon: const Icon(Icons.delete_sweep, size: 16),
                  label: Text(
                    t('clearAll'),
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _recentHistory.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, color: Colors.grey.shade200),
              itemBuilder: (context, index) {
                final record = _recentHistory[index];
                return _buildHistoryItem(record);
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onHistoryItemTap(HistoryRecord record) async {
    final targetPath = record.encryptedPath.isNotEmpty
        ? record.encryptedPath
        : record.filePath;
    await _openFile(targetPath);
  }

  Widget _buildHistoryItem(HistoryRecord record) {
    final isEncrypt = record.operation == 'encrypt';
    final icon = isEncrypt ? Icons.lock : Icons.lock_open;
    final iconColor = isEncrypt ? Colors.orange : Colors.green;
    final opLabel = isEncrypt ? t('encryptFile') : t('decryptFile');
    final fileName = record.filePath.split(Platform.pathSeparator).last;

    String timeStr = record.timestamp;
    try {
      final dt = DateTime.parse(record.timestamp);
      timeStr =
          '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {}

    return InkWell(
      onTap: () => _onHistoryItemTap(record),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 16, color: iconColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: isEncrypt
                              ? Colors.orange.shade50
                              : Colors.green.shade50,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          opLabel,
                          style: TextStyle(
                            fontSize: 10,
                            color: isEncrypt
                                ? Colors.orange.shade700
                                : Colors.green.shade700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          fileName,
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (record.hint.isNotEmpty)
                    Text(
                      '${t('hint')}${record.hint}',
                      style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            Text(
              timeStr,
              style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 200,
      height: 50,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          textStyle: const TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}
