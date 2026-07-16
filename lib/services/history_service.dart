import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 单条操作历史记录
class HistoryRecord {
  final int id;
  final String filePath;        // 原文件路径
  final String operation;       // 'encrypt' 或 'decrypt'
  final String timestamp;       // ISO 8601 格式时间戳
  final String hint;            // 密码提示词（可为空）
  final String encryptedPath;   // 加密后的 .wemi 文件路径（解密时为原加密文件路径）
  final String status;          // 'success'

  HistoryRecord({
    required this.id,
    required this.filePath,
    required this.operation,
    required this.timestamp,
    required this.hint,
    required this.encryptedPath,
    required this.status,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'filePath': filePath,
        'operation': operation,
        'timestamp': timestamp,
        'hint': hint,
        'encryptedPath': encryptedPath,
        'status': status,
      };

  factory HistoryRecord.fromJson(Map<String, dynamic> json) => HistoryRecord(
        id: json['id'] as int,
        filePath: json['filePath'] as String,
        operation: json['operation'] as String,
        timestamp: json['timestamp'] as String,
        hint: json['hint'] as String? ?? '',
        encryptedPath: json['encryptedPath'] as String,
        status: json['status'] as String,
      );
}

/// 操作历史服务：基于 shared_preferences 存储操作历史记录
class HistoryService {
  static const String _historyKey = 'operation_history';
  static const int _maxRecords = 200;
  static SharedPreferences? _prefs;

  static Future<void> _ensureInitialized() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// 添加一条历史记录
  static Future<void> addRecord({
    required String filePath,
    required String operation,
    required String timestamp,
    String hint = '',
    required String encryptedPath,
    String status = 'success',
  }) async {
    await _ensureInitialized();
    final records = await getRecordsRaw();

    final newRecord = HistoryRecord(
      id: DateTime.now().millisecondsSinceEpoch,
      filePath: filePath,
      operation: operation,
      timestamp: timestamp,
      hint: hint,
      encryptedPath: encryptedPath,
      status: status,
    );

    records.insert(0, newRecord.toJson());

    // 超出上限则裁剪最早记录
    while (records.length > _maxRecords) {
      records.removeLast();
    }

    await _prefs!.setString(_historyKey, jsonEncode(records));
  }

  /// 批量添加历史记录（用于批量加密/解密）
  static Future<void> addRecords(List<HistoryRecord> newRecords) async {
    await _ensureInitialized();
    final records = await getRecordsRaw();

    for (final record in newRecords) {
      records.insert(0, record.toJson());
    }

    while (records.length > _maxRecords) {
      records.removeLast();
    }

    await _prefs!.setString(_historyKey, jsonEncode(records));
  }

  /// 获取原始 JSON 列表
  static Future<List<dynamic>> getRecordsRaw() async {
    await _ensureInitialized();
    final jsonStr = _prefs!.getString(_historyKey);
    if (jsonStr == null) return [];
    try {
      return jsonDecode(jsonStr) as List<dynamic>;
    } catch (e) {
      return [];
    }
  }

  /// 获取最近 N 条记录（最多 10 条）
  static Future<List<HistoryRecord>> getRecentRecords({int count = 10}) async {
    final raw = await getRecordsRaw();
    final records = raw
        .map((e) => HistoryRecord.fromJson(e as Map<String, dynamic>))
        .toList();
    return records.take(count).toList();
  }

  /// 获取所有记录
  static Future<List<HistoryRecord>> getAllRecords() async {
    final raw = await getRecordsRaw();
    return raw
        .map((e) => HistoryRecord.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 根据加密文件路径查找历史记录（用于解密时关联）
  static Future<HistoryRecord?> findByEncryptedPath(String encryptedPath) async {
    final all = await getAllRecords();
    for (final record in all) {
      if (record.encryptedPath == encryptedPath) {
        return record;
      }
    }
    return null;
  }

  /// 清空所有历史记录
  static Future<void> clearAll() async {
    await _ensureInitialized();
    await _prefs!.remove(_historyKey);
  }
}

/// 删除策略枚举
enum DeleteAction { recycleBin, permanent, keep }

/// 删除偏好管理：记录用户对"加密后是否删除原文件"的选择
class DeletePreferenceService {
  static const String _deletePrefKey = 'delete_preference';
  static const String _rememberKey = 'remember_delete_choice';

  static SharedPreferences? _prefs;

  static Future<void> _ensureInitialized() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// 获取已记住的删除偏好（null 表示未设置或选择了"保留"）
  static Future<DeleteAction?> getSavedPreference() async {
    await _ensureInitialized();
    final remember = _prefs!.getBool(_rememberKey) ?? false;
    if (!remember) return null;

    final action = _prefs!.getString(_deletePrefKey);
    if (action == 'recycleBin') return DeleteAction.recycleBin;
    if (action == 'permanent') return DeleteAction.permanent;
    return null; // 'keep' 不记住
  }

  /// 保存删除偏好
  static Future<void> savePreference(bool remember, DeleteAction? action) async {
    await _ensureInitialized();
    await _prefs!.setBool(_rememberKey, remember);
    if (remember && action != null && action != DeleteAction.keep) {
      await _prefs!.setString(
          _deletePrefKey,
          action == DeleteAction.recycleBin ? 'recycleBin' : 'permanent');
    } else {
      await _prefs!.remove(_deletePrefKey);
    }
  }
}
