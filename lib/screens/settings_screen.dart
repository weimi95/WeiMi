import 'package:flutter/material.dart';

import '../framework/module_registry.dart';
import '../framework/setting_store.dart';

/// 设置中心：分类导航 + 注册表渲染。
///
/// 左侧（宽屏）或顶部（窄屏）的分类来自各功能模块的注册
/// （见 framework/module_registry.dart），设置项由模块通过
/// SettingDef 贡献，本页只负责渲染与读写（统一走 SettingStore）。
/// 新增功能的设置 = 模块里加一条 SettingDef，无需改本页。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    final mods = ModuleRegistry.modules;
    if (mods.isNotEmpty) _selectedId = mods.first.id;
  }

  FeatureModule? get _current {
    final id = _selectedId;
    if (id == null) return null;
    return ModuleRegistry.module(id);
  }

  @override
  Widget build(BuildContext context) {
    final mods = ModuleRegistry.modules;
    final wide = MediaQuery.of(context).size.width >= 860;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: mods.isEmpty
          ? const Center(child: Text('暂无设置项'))
          : wide
              ? Row(
                  children: [
                    SizedBox(
                      width: 220,
                      child: _CategoryNav(
                        modules: mods,
                        selectedId: _selectedId,
                        onSelect: (id) => setState(() => _selectedId = id),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _SettingsPanel(module: _current)),
                  ],
                )
              : Column(
                  children: [
                    _CategoryTabs(
                      modules: mods,
                      selectedId: _selectedId,
                      onSelect: (id) => setState(() => _selectedId = id),
                    ),
                    const Divider(height: 1),
                    Expanded(child: _SettingsPanel(module: _current)),
                  ],
                ),
    );
  }
}

/// 宽屏左侧分类导航。
class _CategoryNav extends StatelessWidget {
  const _CategoryNav({
    required this.modules,
    required this.selectedId,
    required this.onSelect,
  });

  final List<FeatureModule> modules;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      children: [
        for (final m in modules)
          Container(
            margin: const EdgeInsets.only(bottom: 2),
            decoration: BoxDecoration(
              color: m.id == selectedId
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: ListTile(
              dense: true,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              leading: Icon(m.icon, size: 20),
              title: Text(m.name,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500)),
              selected: m.id == selectedId,
              onTap: () => onSelect(m.id),
            ),
          ),
      ],
    );
  }
}

/// 窄屏顶部分类横滑标签。
class _CategoryTabs extends StatelessWidget {
  const _CategoryTabs({
    required this.modules,
    required this.selectedId,
    required this.onSelect,
  });

  final List<FeatureModule> modules;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        children: [
          for (final m in modules)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                avatar: Icon(m.icon, size: 16),
                label: Text(m.name),
                selected: m.id == selectedId,
                onSelected: (_) => onSelect(m.id),
              ),
            ),
        ],
      ),
    );
  }
}

/// 右侧/下方设置面板：渲染选中模块的全部设置项。
class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({required this.module});

  final FeatureModule? module;

  @override
  Widget build(BuildContext context) {
    if (module == null) {
      return const SizedBox.shrink();
    }
    final defs = module!.settings.where((d) => d.isVisibleNow).toList();
    if (defs.isEmpty) {
      return Center(
        child: Text('「${module!.name}」暂无设置项',
            style: TextStyle(color: Theme.of(context).hintColor)),
      );
    }

    // 按 group 分小节（group 为空的归入无标题首节）
    final groups = <String?, List<SettingDef>>{};
    for (final d in defs) {
      groups.putIfAbsent(d.group, () => []).add(d);
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (final entry in groups.entries) ...[
          if (entry.key != null)
            _groupHeader(context, entry.key!)
          else
            const SizedBox(height: 8),
          for (final d in entry.value) _buildTile(context, d),
        ],
      ],
    );
  }

  Widget _groupHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
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
                value: dv.clamp(def.min ?? 0, def.max ?? 1),
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
