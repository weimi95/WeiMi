import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class FavoriteDirectoriesService {
  static const String _favoritesKey = 'favorite_directories';
  static SharedPreferences? _prefs;

  static Future<void> _ensureInitialized() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  static Future<List<String>> getDirectories() async {
    await _ensureInitialized();
    final jsonStr = _prefs!.getString(_favoritesKey);
    if (jsonStr == null) return [];
    try {
      final List<dynamic> list = jsonDecode(jsonStr);
      return list.cast<String>();
    } catch (e) {
      return [];
    }
  }

  static Future<void> addDirectory(String path) async {
    await _ensureInitialized();
    final dirs = await getDirectories();
    final normalized = path.replaceAll('\\', '/');
    if (!dirs.contains(normalized)) {
      dirs.add(normalized);
      await _save(dirs);
    }
  }

  static Future<void> removeDirectory(String path) async {
    await _ensureInitialized();
    final dirs = await getDirectories();
    final normalized = path.replaceAll('\\', '/');
    dirs.remove(normalized);
    await _save(dirs);
  }

  static Future<void> reorder(int oldIndex, int newIndex) async {
    await _ensureInitialized();
    final dirs = await getDirectories();
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final item = dirs.removeAt(oldIndex);
    dirs.insert(newIndex, item);
    await _save(dirs);
  }

  static Future<void> _save(List<String> dirs) async {
    await _ensureInitialized();
    await _prefs!.setString(_favoritesKey, jsonEncode(dirs));
  }
}
