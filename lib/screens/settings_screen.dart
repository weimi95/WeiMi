import 'package:flutter/material.dart';

import '../framework/module_registry.dart';
import '../framework/setting_store.dart';

/// 设置中心：单页渲染 + 分类分隔。
///
/// 所有功能模块的设置项纵向排在同一页，模块之间用分隔线 +
/// 分类标题区分（模块来自 framework/module_registry.dart 注册，
/// 设置项由模块通过 SettingDef 贡献，本页只负责渲染与读写，
/// 统一走 SettingStore）。
/// 新增功能的设置 = 模块里加一条 SettingDef，无需改本页。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final mods = ModuleRegistry.modules
        .where((m) => m.settings.any((d) => d.isVisibleNow))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: mods.isEmpty
          ? const Center(child: Text('暂无设置项'))
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: mods.length,
              itemBuilder: (context, i) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _moduleSection(
                  context,
                  mods[i],
                  showDivider: i > 0,
                ),
              ),
            ),
    );
  }

  /// 单个模块的分节：分类标题 + 小节标题 + 设置项列表。
  List<Widget> _moduleSection(
    BuildContext context,
    FeatureModule m, {
    required bool showDivider,
  }) {
    final children = <Widget>[];
    String? lastGroup;
    for (final d in m.settings) {
      if (!d.isVisibleNow) continue;
      if (d.group != lastGroup) {
        if (d.group != null) children.add(_GroupHeader(title: d.group!));
        lastGroup = d.group;
      }
      children.add(_buildTile(context, d));
    }
    return <Widget>[
      if (children.isNotEmpty) ...[
        if (showDivider)
          const Divider(height: 1, indent: 16, endIndent: 16),
        _CategoryHeader(module: m),
        ...children,
      ],
    ];
  }

  Widget _buildTile(BuildContext context, SettingDef def) {
    switch (def.type) {
      case SettingType.boolean:
        return _SwitchTile(def: def);
      case SettingType.integer:
      case SettingType.decimal:
        return _SliderTile(def: def);
      case SettingType.text:
        return _TextTile(def: def);
      case SettingType.choice:
        return _ChoiceTile(def: def);
      case SettingType.custom:
        return def.customTile?.call(context) ?? const SizedBox.shrink();
    }
  }
}

/// 模块内小节标题（如「未信任设备请求」「浮窗行为」）。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: Theme.of(context).hintColor,
        ),
      ),
    );
  }
}

/// 分类标题（模块名 + 图标）。
class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({required this.module});

  final FeatureModule module;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Row(
        children: [
          Icon(module.icon, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Text(
            module.name,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.primary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 开关项：值监听 + 写库 + onChanged 联动。
class _SwitchTile extends StatelessWidget {
  const _SwitchTile({required this.def});

  final SettingDef def;

  @override
  Widget build(BuildContext context) {
    final fallback = def.defaultValue is bool ? def.defaultValue as bool : false;
    return ValueListenableBuilder<dynamic>(
      valueListenable: SettingStore.listen(def.key, fallback),
      builder: (context, v, _) {
        final on = v is bool ? v : fallback;
        return SwitchListTile(
          secondary: Icon(def.icon ?? Icons.tune, size: 20),
          title: Text(def.title, style: const TextStyle(fontSize: 14)),
          subtitle: def.subtitle == null
              ? null
              : Text(def.subtitle!, style: const TextStyle(fontSize: 12)),
          value: on,
          onChanged: (nv) async {
            await SettingStore.set(def.key, nv);
            def.onChanged?.call(context, nv);
          },
        );
      },
    );
  }
}

/// 滑块项（整数/小数）。
class _SliderTile extends StatelessWidget {
  const _SliderTile({required this.def});

  final SettingDef def;

  @override
  Widget build(BuildContext context) {
    final isInt = def.type == SettingType.integer;
    final fallback = (def.defaultValue is num)
        ? (def.defaultValue as num).toDouble()
        : (def.min ?? 0);
    return ValueListenableBuilder<dynamic>(
      valueListenable: SettingStore.listen(def.key, fallback),
      builder: (context, v, _) {
        final dv = (v is num) ? v.toDouble() : fallback;
        return ListTile(
          leading: Icon(def.icon ?? Icons.tune, size: 20),
          title: Text(def.title, style: const TextStyle(fontSize: 14)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (def.subtitle != null)
                Text(def.subtitle!, style: const TextStyle(fontSize: 12)),
              Slider(
                value: dv.clamp(def.min ?? 0, def.max ?? 1).toDouble(),
                min: def.min ?? 0,
                max: def.max ?? 1,
                divisions: def.divisions,
                label: isInt ? dv.round().toString() : dv.toStringAsFixed(2),
                onChanged: (nv) async {
                  await SettingStore.set(
                      def.key, isInt ? nv.round() : double.parse(nv.toStringAsFixed(2)));
                  def.onChanged?.call(context, nv);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 文本项：点击弹对话框编辑。
class _TextTile extends StatelessWidget {
  const _TextTile({required this.def});

  final SettingDef def;

  @override
  Widget build(BuildContext context) {
    final fallback =
        def.defaultValue is String ? def.defaultValue as String : '';
    return ValueListenableBuilder<dynamic>(
      valueListenable: SettingStore.listen(def.key, fallback),
      builder: (context, v, _) {
        final s = v is String ? v : fallback;
        return ListTile(
          leading: Icon(def.icon ?? Icons.tune, size: 20),
          title: Text(def.title, style: const TextStyle(fontSize: 14)),
          subtitle: Text(s.isEmpty ? (def.subtitle ?? '未设置') : s,
              style: const TextStyle(fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.edit_outlined, size: 18),
          onTap: () async {
            final controller = TextEditingController(text: s);
            final r = await showDialog<String>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(def.title),
                content: TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                      hintText: def.subtitle ?? '请输入'),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                      child: const Text('保存')),
                ],
              ),
            );
            if (r != null) {
              await SettingStore.set(def.key, r);
              def.onChanged?.call(context, r);
            }
          },
        );
      },
    );
  }
}

/// 单选项：点击弹底部选择器。
class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({required this.def});

  final SettingDef def;

  @override
  Widget build(BuildContext context) {
    final options = def.options ?? const [];
    final fallback = options.isNotEmpty ? options.first : '';
    return ValueListenableBuilder<dynamic>(
      valueListenable: SettingStore.listen(def.key, fallback),
      builder: (context, v, _) {
        final cur = v is String ? v : fallback;
        return ListTile(
          leading: Icon(def.icon ?? Icons.tune, size: 20),
          title: Text(def.title, style: const TextStyle(fontSize: 14)),
          subtitle: def.subtitle == null
              ? null
              : Text(def.subtitle!, style: const TextStyle(fontSize: 12)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(def.optionLabels?[cur] ?? cur,
                  style: const TextStyle(fontSize: 13)),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
          onTap: () async {
            final picked = await showModalBottomSheet<String>(
              context: context,
              builder: (ctx) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(def.title,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w500)),
                    ),
                    for (final opt in options)
                      RadioListTile<String>(
                        value: opt,
                        groupValue: cur,
                        title: Text(def.optionLabels?[opt] ?? opt,
                            style: const TextStyle(fontSize: 14)),
                        onChanged: (nv) => Navigator.pop(ctx, nv),
                      ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
            if (picked != null && picked != cur) {
              await SettingStore.set(def.key, picked);
              def.onChanged?.call(context, picked);
            }
          },
        );
      },
    );
  }
}
