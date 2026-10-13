import 'package:flutter/material.dart';

import '../framework/module_registry.dart';
import '../framework/setting_store.dart';
import '../services/localization_service.dart';
import '../screens/language_screen.dart';

/// 语言模块：设置中心里的语言入口（跳语言选择页）。
class LanguageModule extends FeatureModule {
  LanguageModule();

  /// 由 main.dart 挂接 MyApp 的刷新回调（语言切换后整机 UI 立即生效）。
  VoidCallback? onLanguageChanged;

  @override
  String get id => 'language';

  @override
  String get name => '语言';

  @override
  IconData get icon => Icons.translate;

  @override
  int get order => 5;

  @override
  List<SettingDef> get settings => [
        SettingDef(
          key: 'language',
          title: '界面语言',
          icon: Icons.translate,
          subtitle: '切换应用界面显示语言',
          type: SettingType.custom,
          customTile: (ctx) => _LanguageTile(
            onLanguageChanged: () => onLanguageChanged?.call(),
          ),
        ),
      ];

  @override
  List<FileActionDef> get fileActions => const [];
}

class _LanguageTile extends StatefulWidget {
  const _LanguageTile({required this.onLanguageChanged});

  final VoidCallback onLanguageChanged;

  @override
  State<_LanguageTile> createState() => _LanguageTileState();
}

class _LanguageTileState extends State<_LanguageTile> {
  String _current = '…';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final svc = await LocalizationService.getInstance();
    if (!mounted) return;
    setState(() => _current = svc.currentLanguage.displayName);
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.translate),
      title: const Text('界面语言', style: TextStyle(fontSize: 14)),
      subtitle: Text(_current, style: const TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => LanguageScreen(
              onLanguageChanged: () {
                widget.onLanguageChanged();
                _load();
              },
            ),
          ),
        );
        _load();
      },
    );
  }
}
