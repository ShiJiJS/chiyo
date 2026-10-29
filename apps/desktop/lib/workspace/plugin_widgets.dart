import 'package:flutter/material.dart';
import '../ui_palette.dart';
import '../prototype_icons.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

const pluginFieldLabels = {
  'text': '文字',
  'url': '链接',
  'number': '数字',
  'date': '日期',
  'multiline': '长文本',
  'entries': '多段经历',
};

class PluginTemplatePreview extends StatelessWidget {
  const PluginTemplatePreview({
    super.key,
    required this.template,
    this.structure = false,
    this.embedded = false,
  });
  final WorkspacePluginTemplate template;
  final bool structure;
  final bool embedded;
  @override
  Widget build(BuildContext context) {
    final definition = template.definition, c = UiPalette.of(context);
    final fields = List<Map>.from(definition['fields'] as List? ?? []);
    final example = definition['example'] as Map?;
    final values = example?['values'] as Map? ?? {};
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (structure) ...[
          Text(
            '信息字段',
            style: libraryText(context, 17, weight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          for (final f in fields)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.line)),
              ),
              child: Wrap(
                spacing: 18,
                runSpacing: 6,
                children: [
                  Text(
                    f['label'] as String,
                    style: libraryText(context, 14, weight: FontWeight.w600),
                  ),
                  Text(
                    pluginFieldLabels[f['type']] ?? f['type'].toString(),
                    style: libraryText(context, 13, color: c.muted),
                  ),
                  Text(
                    f['required'] == true ? '必填' : '选填',
                    style: libraryText(context, 13, color: c.muted),
                  ),
                  SelectableText(
                    f['key'] as String,
                    style: libraryText(context, 12, color: c.muted),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 24),
          Text(
            '可选关联',
            style: libraryText(context, 17, weight: FontWeight.w600),
          ),
          for (final r in definition['relations'] as List? ?? [])
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '${r['label']} · ${(r['targetTemplates'] as List).isEmpty ? '已有资料' : (r['targetTemplates'] as List).join(' / ')}',
                style: libraryText(context, 13, color: c.muted),
              ),
            ),
        ] else ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: c.selected,
              border: Border(bottom: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                PrototypeIcon(
                  RecordIcon.glyphFor(template.type.icon),
                  size: 18,
                  color: c.accent,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    template.type.name,
                    style: libraryText(
                      context,
                      15,
                      weight: FontWeight.w700,
                      color: c.accent,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final (index, section)
              in (definition['sections'] as List? ?? []).indexed)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
              decoration: BoxDecoration(
                border: index == 0
                    ? null
                    : Border(top: BorderSide(color: c.line)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    section['title'] as String,
                    style: libraryText(context, 14, weight: FontWeight.w700),
                  ),
                  const SizedBox(height: 13),
                  if (section['kind'] == 'fields')
                    LayoutBuilder(
                      builder: (context, bounds) {
                        final two =
                            bounds.maxWidth >= 400 &&
                            MediaQuery.textScalerOf(context).scale(1) < 1.5;
                        return Wrap(
                          spacing: 15,
                          runSpacing: 15,
                          children: [
                            for (final key in section['keys'] as List)
                              for (final f in fields.where(
                                (f) => f['key'] == key,
                              ))
                                SizedBox(
                                  width: two
                                      ? (bounds.maxWidth - 15) / 2
                                      : bounds.maxWidth,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        f['label'] as String,
                                        style: libraryText(
                                          context,
                                          12,
                                          color: c.muted,
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      SelectableText(
                                        values[key] is String
                                            ? values[key] as String
                                            : '填写${f['label']}',
                                        style: libraryText(context, 13),
                                      ),
                                    ],
                                  ),
                                ),
                          ],
                        );
                      },
                    )
                  else if (section['kind'] == 'relations')
                    Text(
                      '可关联已有资料，也可以暂不填写。',
                      style: libraryText(context, 13, color: c.muted),
                    )
                  else
                    SelectableText(
                      values[section['key']] is String
                          ? values[section['key']] as String
                          : section['kind'] == 'timeline'
                          ? '可添加多段记录'
                          : '填写此项内容',
                      style: libraryText(context, 14, height: 1.8),
                    ),
                ],
              ),
            ),
        ],
      ],
    );
    return structure
        ? content
        : Container(
            padding: embedded
                ? const EdgeInsets.symmetric(vertical: 20)
                : EdgeInsets.zero,
            clipBehavior: embedded ? Clip.none : Clip.antiAlias,
            decoration: BoxDecoration(
              color: c.paper,
              border: embedded
                  ? Border(top: BorderSide(color: c.line))
                  : Border.all(color: c.line),
              borderRadius: embedded ? null : BorderRadius.circular(9),
            ),
            child: content,
          );
  }
}

class PluginFailureView extends StatelessWidget {
  const PluginFailureView(this.failure, {super.key});
  final WorkspaceFailure failure;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          failure.message,
          style: TextStyle(color: UiPalette.of(context).danger),
        ),
        for (final e in failure.fieldErrors.entries)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(
              '${e.key}：${e.value}',
              style: libraryText(
                context,
                13,
                color: UiPalette.of(context).danger,
              ),
            ),
          ),
      ],
    ),
  );
}
