import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
import 'services/file_operations_service.dart';
import 'services/encryption_service.dart';
import 'services/file_viewer_service.dart';
import 'services/file_association_service.dart';
import 'services/localization_service.dart';
import 'services/history_service.dart';
import 'services/favorite_directories_service.dart';
import 'widgets/progress_dialog.dart';
import 'screens/about_screen.dart';
import 'screens/language_screen.dart';

const int kPasswordMinLength = 4;
const int kPasswordMaxLength = 32;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
            title: '微密',
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

// ============================================================
// File icon helper
// ============================================================
class FileIconHelper {
  static IconData getIcon(String extension) {
    switch (extension.toLowerCase()) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'bmp':
      case 'webp':
      case 'svg':
        return Icons.image;
      case 'mp4':
      case 'avi':
      case 'mkv':
      case 'mov':
      case 'wmv':
      case 'flv':
        return Icons.videocam;
      case 'mp3':
      case 'wav':
      case 'flac':
      case 'aac':
      case 'm4a':
      case 'ogg':
        return Icons.audiotrack;
      case 'py':
      case 'dart':
      case 'js':
      case 'ts':
      case 'java':
      case 'c':
      case 'cpp':
      case 'h':
      case 'cs':
      case 'rs':
      case 'go':
      case 'rb':
      case 'swift':
      case 'kt':
      case 'sh':
      case 'ps1':
      case 'bat':
        return Icons.code;
      case 'doc':
      case 'docx':
      case 'ppt':
      case 'pptx':
      case 'xls':
      case 'xlsx':
      case 'csv':
      case 'txt':
      case 'md':
        return Icons.description;
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
      case 'bz2':
        return Icons.folder_zip;
      default:
        return Icons.insert_drive_file;
    }
  }

  static Color getColor(String extension) {
    switch (extension.toLowerCase()) {
      case 'pdf':
        return Colors.red;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'bmp':
      case 'webp':
      case 'svg':
        return Colors.blue;
      case 'mp4':
      case 'avi':
      case 'mkv':
      case 'mov':
      case 'wmv':
      case 'flv':
        return Colors.purple;
      case 'mp3':
      case 'wav':
      case 'flac':
      case 'aac':
      case 'm4a':
      case 'ogg':
        return Colors.green;
      case 'py':
      case 'dart':
      case 'js':
      case 'ts':
      case 'java':
      case 'c':
      case 'cpp':
      case 'h':
      case 'cs':
      case 'rs':
      case 'go':
      case 'rb':
      case 'swift':
      case 'kt':
      case 'sh':
      case 'ps1':
      case 'bat':
        return Colors.grey;
      case 'doc':
      case 'docx':
      case 'ppt':
      case 'pptx':
      case 'xls':
      case 'xlsx':
      case 'csv':
      case 'txt':
      case 'md':
        return Colors.orange;
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
      case 'bz2':
        return Colors.brown;
      default:
        return Colors.blueGrey;
    }
  }
}

// ============================================================
// HomePage
// ============================================================
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
  // --- state ---
  bool _isProcessing = false;
  bool _isDragging = false;
  List<HistoryRecord> _recentHistory = [];

  // sidebar
  List<String> _favoriteDirs = [];
  String? _selectedDir;

  // file list
  List<_FileItem> _fileItems = [];
  bool _isLoadingFiles = false;
  final Set<int> _selectedIndices = {};
  int? _lastTappedIndex;
  bool _isGridView = true;

  // history
  bool _historyExpanded = false;

  // sidebar collapse
  bool _sidebarCollapsed = false;

  String t(String key) => widget.localizationService.translate(key);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkInitialFile();
    _loadHistory();
    _loadFavorites();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isAndroid) {
      _cleanupFilePickerCache();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // No-op: required by WidgetsBindingObserver
  }

  Future<void> _cleanupFilePickerCache() async {
    try {
      await FilePicker.platform.clearTemporaryFiles();
    } catch (e) {
      debugPrint('Failed to clear file_picker cache: $e');
    }
  }

  // ============ data loading ============

  Future<void> _loadHistory() async {
    try {
      final records = await HistoryService.getRecentRecords();
      if (mounted) {
        setState(() => _recentHistory = records);
      }
    } catch (e) {
      debugPrint('Failed to load history: $e');
    }
  }

  Future<void> _loadFavorites() async {
    final dirs = await FavoriteDirectoriesService.getDirectories();
    if (mounted) {
      setState(() => _favoriteDirs = dirs);
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

  Future<void> _loadFiles(String dirPath) async {
    setState(() {
      _isLoadingFiles = true;
      _selectedDir = dirPath;
      _fileItems = [];
      _selectedIndices.clear();
      _lastTappedIndex = null;
    });

    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        if (mounted) {
          setState(() {
            _isLoadingFiles = false;
            _fileItems = [];
          });
        }
        return;
      }

      // Async listing to avoid blocking UI
      final entities = await dir.list().toList();
      final fileItems = <_FileItem>[];

      for (final entity in entities) {
        if (entity is File) {
          try {
            final stat = await entity.stat();
            final ext = entity.path.split('.').last;
            final isEncrypted =
                await EncryptionService.isEncryptedFile(entity.path);
            fileItems.add(_FileItem(
              path: entity.path,
              name: entity.path.split(Platform.pathSeparator).last,
              extension: ext,
              size: stat.size,
              modified: stat.modified,
              isEncrypted: isEncrypted,
            ));
          } catch (_) {
            // skip files that can't be read
          }
        }
      }

      // sort by name
      fileItems.sort((a, b) => a.name.compareTo(b.name));

      if (mounted) {
        setState(() {
          _fileItems = fileItems;
          _isLoadingFiles = false;
        });
      }
    } catch (e) {
      debugPrint('Failed to load directory $dirPath: $e');
      if (mounted) {
        setState(() => _isLoadingFiles = false);
        _showMessage('${t('openFileFailed')}$e', isError: true);
      }
    }
  }

  // ============ favorite dirs ============

  Future<void> _addFavoriteDir() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: t('addDirectory'),
    );
    if (result != null) {
      await FavoriteDirectoriesService.addDirectory(result);
      await _loadFavorites();
      // auto-select and load
      _loadFiles(result);
    }
  }

  Future<void> _removeFavoriteDir(int index) async {
    final dir = _favoriteDirs[index];
    await FavoriteDirectoriesService.removeDirectory(dir);
    await _loadFavorites();
    if (_selectedDir == dir) {
      setState(() {
        _selectedDir = null;
        _fileItems = [];
        _selectedIndices.clear();
      });
    }
  }

  // ============ file operations ============

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

  List<String> get _selectedPaths {
    return _selectedIndices.map((i) => _fileItems[i].path).toList();
  }

  bool get _hasSelection => _selectedIndices.isNotEmpty;

  Future<void> _encryptSelected() async {
    if (!_hasSelection) {
      _showMessage(t('selectFilesFirst'), isError: true);
      return;
    }
    final paths = _selectedPaths.toList();
    await _processEncryptFiles(paths);
    if (_selectedDir != null) {
      _loadFiles(_selectedDir!);
    }
  }

  Future<void> _decryptSelected() async {
    if (!_hasSelection) {
      _showMessage(t('selectFilesFirst'), isError: true);
      return;
    }
    final paths =
        _selectedPaths.where((p) => p.toLowerCase().endsWith('.wemi')).toList();
    if (paths.isEmpty) {
      _showMessage(t('notEncryptedFile'), isError: true);
      return;
    }
    await _processDecryptFiles(paths);
    if (_selectedDir != null) {
      _loadFiles(_selectedDir!);
    }
  }

  // ============ dialogs ============

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
                      Icon(Icons.lightbulb_outline,
                          color: Colors.blue.shade700, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${t('hint')}$hint',
                          style: TextStyle(
                              color: Colors.blue.shade700, fontSize: 14),
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
                    style:
                        const TextStyle(fontSize: 12, color: Colors.grey),
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
                  child: Text(t('permanentDelete'),
                      style: const TextStyle(color: Colors.red)),
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

  // ============ drag-drop ============

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
      if (_selectedDir != null) {
        _loadFiles(_selectedDir!);
      }
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

  // ============ selection logic ============

  void _onFileTap(int index, {bool ctrl = false, bool shift = false}) {
    setState(() {
      if (shift && _lastTappedIndex != null) {
        // range select
        final start = _lastTappedIndex! < index ? _lastTappedIndex! : index;
        final end = _lastTappedIndex! < index ? index : _lastTappedIndex!;
        for (int i = start; i <= end; i++) {
          _selectedIndices.add(i);
        }
      } else if (ctrl) {
        // toggle
        if (_selectedIndices.contains(index)) {
          _selectedIndices.remove(index);
        } else {
          _selectedIndices.add(index);
        }
        _lastTappedIndex = index;
      } else {
        // single select
        _selectedIndices.clear();
        _selectedIndices.add(index);
        _lastTappedIndex = index;
      }
    });
  }

  void _onFileDoubleTap(int index) {
    _openFile(_fileItems[index].path);
  }

  void _showContextMenu(Offset position, int index) {
    final item = _fileItems[index];
    final isEncrypted = item.isEncrypted || item.name.endsWith('.wemi');

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx + 1, position.dy + 1),
      items: [
        PopupMenuItem(
          value: 'open',
          child: ListTile(
            leading: const Icon(Icons.open_in_new),
            title: Text(t('open')),
            dense: true,
          ),
        ),
        if (!isEncrypted)
          PopupMenuItem(
            value: 'encrypt',
            child: ListTile(
              leading: const Icon(Icons.lock),
              title: Text(t('encryptFile')),
              dense: true,
            ),
          ),
        if (isEncrypted)
          PopupMenuItem(
            value: 'decrypt',
            child: ListTile(
              leading: const Icon(Icons.lock_open),
              title: Text(t('decryptFile')),
              dense: true,
            ),
          ),
        PopupMenuItem(
          value: 'copyPath',
          child: ListTile(
            leading: const Icon(Icons.copy),
            title: Text(t('copyPath')),
            dense: true,
          ),
        ),
      ],
    ).then((value) {
      if (value == 'open') {
        _openFile(item.path);
      } else if (value == 'encrypt') {
        _processEncryptFiles([item.path]).then((_) {
          if (_selectedDir != null) _loadFiles(_selectedDir!);
        });
      } else if (value == 'decrypt') {
        _processDecryptFiles([item.path]).then((_) {
          if (_selectedDir != null) _loadFiles(_selectedDir!);
        });
      } else if (value == 'copyPath') {
        Clipboard.setData(ClipboardData(text: item.path));
        _showMessage('${t('copyPath')}: ${item.path}');
      }
    });
  }

  // ============ build ============

  @override
  Widget build(BuildContext context) {
    final bool supportDragDrop = !Platform.isAndroid && !Platform.isIOS;

    Widget bodyContent = Row(
      children: [
        // --- Left sidebar ---
        _buildSidebar(),
        // --- Right main area ---
        Expanded(
          child: Column(
            children: [
              // Toolbar
              _buildToolbar(),
              // File list
              Expanded(child: _buildFileListArea()),
              // Collapsible history
              _buildHistorySection(),
            ],
          ),
        ),
      ],
    );

    if (supportDragDrop) {
      bodyContent = DropTarget(
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
            color: _isDragging ? Colors.blueAccent.withAlpha(20) : null,
          ),
          child: bodyContent,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(t('appTitle')),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      drawer: _buildDrawer(),
      body: _isProcessing
          ? const Center(child: CircularProgressIndicator())
          : bodyContent,
    );
  }

  // ----- sidebar -----

  Widget _buildSidebar() {
    if (_sidebarCollapsed) {
      // Collapsed: thin strip with expand button
      return Container(
        width: 36,
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          border: Border(
            right: BorderSide(color: Colors.grey.shade300),
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 8),
            InkWell(
              onTap: () => setState(() => _sidebarCollapsed = false),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: Colors.grey.shade600,
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: RotatedBox(
                  quarterTurns: 1,
                  child: Text(
                    t('favoriteDirectories'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade500,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        border: Border(
          right: BorderSide(color: Colors.grey.shade300),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.only(left: 16, right: 4, top: 10, bottom: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Colors.grey.shade300),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    t('favoriteDirectories'),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => setState(() => _sidebarCollapsed = true),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.chevron_left,
                      size: 20,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Directory list
          Expanded(
            child: _favoriteDirs.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        t('addDirectoryHint'),
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 13,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : Scrollbar(
                    child: ReorderableListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _favoriteDirs.length,
                      onReorder: (oldIndex, newIndex) async {
                        await FavoriteDirectoriesService.reorder(
                            oldIndex, newIndex);
                        if (mounted) _loadFavorites();
                      },
                      proxyDecorator: (child, index, animation) {
                        return Material(
                          elevation: 4,
                          color: Colors.transparent,
                          child: child,
                        );
                      },
                      itemBuilder: (context, index) {
                        final dir = _favoriteDirs[index];
                        final name = dir.split(Platform.pathSeparator).last;
                        final isSelected = dir == _selectedDir;

                        return Material(
                          key: ValueKey(dir),
                          color: isSelected
                              ? Colors.blue.shade50
                              : Colors.transparent,
                          child: InkWell(
                            onTap: () => _loadFiles(dir),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.folder,
                                    size: 18,
                                    color: isSelected
                                        ? Colors.blue
                                        : Colors.amber.shade700,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          name,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: isSelected
                                                ? FontWeight.w600
                                                : FontWeight.normal,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          dir,
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey.shade500,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  InkWell(
                                    onTap: () => _removeFavoriteDir(index),
                                    child: Icon(
                                      Icons.close,
                                      size: 16,
                                      color: Colors.grey.shade400,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          // Add button
          Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: Colors.grey.shade300),
              ),
            ),
            child: InkWell(
              onTap: _addFavoriteDir,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add, size: 18, color: Colors.blue.shade600),
                    const SizedBox(width: 4),
                    Text(
                      t('addDirectory'),
                      style: TextStyle(
                        color: Colors.blue.shade600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ----- toolbar -----

  Widget _buildToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade300),
        ),
      ),
      child: Row(
        children: [
          // Encrypt button
          _ToolbarButton(
            icon: Icons.lock,
            label: t('encryptFile'),
            enabled: _hasSelection,
            onPressed: _encryptSelected,
          ),
          const SizedBox(width: 8),
          // Decrypt button
          _ToolbarButton(
            icon: Icons.lock_open,
            label: t('decryptFile'),
            enabled: _hasSelection,
            onPressed: _decryptSelected,
          ),
          const SizedBox(width: 16),
          const VerticalDivider(width: 1),
          const SizedBox(width: 12),
          // Breadcrumb
          Expanded(
            child: _selectedDir == null
                ? Text(
                    t('breadcrumbHome'),
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade600,
                    ),
                  )
                : GestureDetector(
                    onTap: () {
                      // open in explorer
                      Process.run('explorer', [_selectedDir!]);
                    },
                    child: Text(
                      _selectedDir!,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.blue.shade700,
                        decoration: TextDecoration.underline,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
          ),
          // View toggle
          IconButton(
            icon: Icon(_isGridView ? Icons.list : Icons.grid_view),
            tooltip: _isGridView ? t('listView') : t('gridView'),
            onPressed: () {
              setState(() => _isGridView = !_isGridView);
            },
            iconSize: 20,
          ),
        ],
      ),
    );
  }

  // ----- file list area -----

  Widget _buildFileListArea() {
    if (_selectedDir == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_open, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              t('dragDropHint'),
              style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
            ),
          ],
        ),
      );
    }

    if (_isLoadingFiles) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(t('loadingDirectory'),
                style: TextStyle(color: Colors.grey.shade600)),
          ],
        ),
      );
    }

    if (_fileItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_off, size: 48, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text(t('noFilesInDirectory'),
                style: TextStyle(color: Colors.grey.shade500)),
          ],
        ),
      );
    }

    final fileCount = _fileItems.length;

    return Column(
      children: [
        // Status bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          color: Colors.grey.shade50,
          child: Row(
            children: [
              Text(
                '$fileCount ${fileCount == 1 ? 'file' : 'files'}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              if (_hasSelection) ...[
                const SizedBox(width: 16),
                Text(
                  '${_selectedIndices.length} selected',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.blue.shade600,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ],
          ),
        ),
        // File grid/list
        Expanded(
          child: _isGridView ? _buildFileGrid() : _buildFileList(),
        ),
      ],
    );
  }

  Widget _buildFileGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = (constraints.maxWidth / 140).floor().clamp(2, 8);
        return Scrollbar(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              childAspectRatio: 0.85,
            ),
            itemCount: _fileItems.length,
            itemBuilder: (context, index) =>
                _buildFileGridItem(context, index),
          ),
        );
      },
    );
  }

  Widget _buildFileGridItem(BuildContext context, int index) {
    final item = _fileItems[index];
    final isSelected = _selectedIndices.contains(index);
    final ext = item.extension.toLowerCase();
    final icon = FileIconHelper.getIcon(ext);
    final color = FileIconHelper.getColor(ext);

    return GestureDetector(
      onTap: () {
        final mods = HardwareKeyboard.instance.logicalKeysPressed;
        final ctrl = mods.contains(LogicalKeyboardKey.controlLeft) ||
            mods.contains(LogicalKeyboardKey.controlRight);
        final shift = mods.contains(LogicalKeyboardKey.shiftLeft) ||
            mods.contains(LogicalKeyboardKey.shiftRight);
        _onFileTap(index, ctrl: ctrl, shift: shift);
      },
      onDoubleTap: () => _onFileDoubleTap(index),
      onSecondaryTapDown: (details) {
        _showContextMenu(details.globalPosition, index);
      },
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue.shade50 : Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? Colors.blue : Colors.grey.shade200,
            width: isSelected ? 2 : 1,
          ),
        ),
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon, size: 36, color: color),
                if (item.isEncrypted)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Icon(Icons.lock, size: 14, color: Colors.orange),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              item.name,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              textAlign: TextAlign.center,
            ),
            Text(
              _formatSize(item.size),
              style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileList() {
    return Scrollbar(
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _fileItems.length,
        itemBuilder: (context, index) => _buildFileListItem(index),
      ),
    );
  }

  Widget _buildFileListItem(int index) {
    final item = _fileItems[index];
    final isSelected = _selectedIndices.contains(index);
    final ext = item.extension.toLowerCase();
    final icon = FileIconHelper.getIcon(ext);
    final color = FileIconHelper.getColor(ext);

    return GestureDetector(
      onTap: () {
        final mods = HardwareKeyboard.instance.logicalKeysPressed;
        final ctrl = mods.contains(LogicalKeyboardKey.controlLeft) ||
            mods.contains(LogicalKeyboardKey.controlRight);
        final shift = mods.contains(LogicalKeyboardKey.shiftLeft) ||
            mods.contains(LogicalKeyboardKey.shiftRight);
        _onFileTap(index, ctrl: ctrl, shift: shift);
      },
      onDoubleTap: () => _onFileDoubleTap(index),
      onSecondaryTapDown: (details) {
        _showContextMenu(details.globalPosition, index);
      },
      child: Container(
        color: isSelected ? Colors.blue.shade50 : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Stack(
              children: [
                Icon(icon, size: 22, color: color),
                if (item.isEncrypted)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child:
                        Icon(Icons.lock, size: 10, color: Colors.orange.shade700),
                  ),
              ],
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                item.name,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _formatSize(item.size),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  // ----- history section -----

  Widget _buildHistorySection() {
    if (_recentHistory.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Toggle header
          InkWell(
            onTap: () {
              setState(() => _historyExpanded = !_historyExpanded);
            },
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    _historyExpanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 18,
                    color: Colors.grey.shade600,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    t('recentHistory'),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  const Spacer(),
                  if (_historyExpanded)
                    TextButton.icon(
                      onPressed: _handleClearHistory,
                      icon:
                          const Icon(Icons.delete_sweep, size: 14),
                      label: Text(
                        t('clearAll'),
                        style: const TextStyle(fontSize: 11),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Expanded list
          if (_historyExpanded)
            Container(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _recentHistory.length,
                separatorBuilder: (_, __) =>
                    Divider(height: 1, color: Colors.grey.shade200),
                itemBuilder: (context, index) {
                  return _buildHistoryItem(_recentHistory[index]);
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
            Icon(icon, size: 14, color: iconColor),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 3, vertical: 1),
                        decoration: BoxDecoration(
                          color: isEncrypt
                              ? Colors.orange.shade50
                              : Colors.green.shade50,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Text(
                          opLabel,
                          style: TextStyle(
                            fontSize: 9,
                            color: isEncrypt
                                ? Colors.orange.shade700
                                : Colors.green.shade700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          fileName,
                          style: const TextStyle(fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (record.hint.isNotEmpty)
                    Text(
                      '${t('hint')}${record.hint}',
                      style: TextStyle(
                          fontSize: 9, color: Colors.grey.shade500),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            Text(
              timeStr,
              style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }

  // ----- drawer -----

  Widget _buildDrawer() {
    return Drawer(
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
                const Icon(Icons.folder_special,
                    size: 60, color: Colors.blueAccent),
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
                          onLanguageChanged: widget.onLanguageChanged,
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
    );
  }

  // ----- helpers -----

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
  }
}

// ============================================================
// Data class and small widget
// ============================================================
class _FileItem {
  final String path;
  final String name;
  final String extension;
  final int size;
  final DateTime modified;
  final bool isEncrypted;

  _FileItem({
    required this.path,
    required this.name,
    required this.extension,
    required this.size,
    required this.modified,
    required this.isEncrypted,
  });
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: OutlinedButton.icon(
        onPressed: enabled ? onPressed : null,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
      ),
    );
  }
}
