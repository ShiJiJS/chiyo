import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../prototype_icons.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'library_document.dart';
import 'library_file.dart';
import 'library_credential.dart';
import 'workspace_source.dart';
import 'host_settings.dart';
import 'template_record_content.dart';

/// Reads a template snapshot for display; it does not own persistence or infer
/// authorization from a link. Related identities resolve as metadata only.
class LibraryDetail extends StatefulWidget {
  const LibraryDetail({
    super.key,
    required this.detail,
    required this.source,
    required this.metrics,
    required this.revision,
    required this.onOpen,
    required this.onEdit,
    this.onHistory,
    this.onRecycle,
    this.onAdopt,
    this.onApproval,
    this.filePicker,
    this.credentialPicker,
    this.onModalChanged,
    required this.onSettings,
    required this.onTag,
    required this.onExpand,
  });
  final WorkspaceDetail detail;
  final WorkspaceSource source;
  final LibraryMetrics metrics;
  final int revision;
  final ValueChanged<WorkspaceRecordRef> onOpen;
  final VoidCallback? onEdit, onHistory, onRecycle;
  final VoidCallback? onAdopt;
  final ValueChanged<String>? onApproval;
  final VoidCallback onSettings, onExpand;
  final ValueChanged<String> onTag;
  final WorkspaceFilePicker? filePicker;
  final WorkspaceCredentialPicker? credentialPicker;
  final ValueChanged<bool>? onModalChanged;
  @override
  State<LibraryDetail> createState() => _LibraryDetailState();
}

class _LibraryDetailState extends State<LibraryDetail> {
  bool _relations = false;
  final _documentReading = DocumentReadingController();
  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(covariant LibraryDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.detail.record.ref != widget.detail.record.ref ||
        oldWidget.detail.values['body'] != widget.detail.values['body'] ||
        oldWidget.detail.values['bodyFormat'] !=
            widget.detail.values['bodyFormat']) {
      _documentReading.value = false;
    }
  }

  @override
  void dispose() {
    _documentReading.dispose();
    super.dispose();
  }

  Widget _tab(
    BuildContext context,
    String label,
    bool selected,
    VoidCallback onPressed,
  ) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(
          color: selected ? UiPalette.of(context).accent : Colors.transparent,
          width: 2,
        ),
      ),
    ),
    child: DesktopButton(
      kind: DesktopButtonKind.quiet,
      onPressed: onPressed,
      padding: const EdgeInsets.symmetric(vertical: 10),
      minimumSize: const Size(0, 44.4),
      child: Text(
        label,
        style: libraryText(
          context,
          14,
          weight: FontWeight.w500,
          color: selected
              ? UiPalette.of(context).accent
              : UiPalette.of(context).muted,
        ),
      ),
    ),
  );

  Widget _description(BuildContext context, String value) {
    final style = libraryText(
      context,
      14,
      color: UiPalette.of(context).muted,
      height: 1.8,
    );
    // The frozen paragraph has max-width:65ch. Use the same installed font
    // and scaler for the zero glyph instead of a platform-specific pixel cap.
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox(
        width: libraryChWidth(context, style, 65),
        child: Text(
          value,
          key: const ValueKey('library-detail-description'),
          style: style,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail,
        record = detail.record,
        c = UiPalette.of(context);
    final documentSection =
        record.type.id == 'document' &&
            detail.templateState == WorkspaceTemplateState.available
        ? (detail.definition['sections'] as List? ?? [])
              .whereType<Map>()
              .where(
                (s) =>
                    s['kind'] == 'text' &&
                    s['key'] == 'body' &&
                    s['formatKey'] == 'bodyFormat',
              )
              .firstOrNull
        : null;
    final declaredFields = (detail.definition['fields'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final declaredSections = (detail.definition['sections'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final primaryFile =
        detail.templateState == WorkspaceTemplateState.available &&
        workspaceFileTypeIds.contains(record.type.id) &&
        detail.definition['id'] == record.type.id &&
        declaredFields.length == 1 &&
        declaredFields.single['key'] == 'file' &&
        declaredFields.single['type'] == 'file' &&
        declaredSections.any((s) => s['kind'] == 'fields') &&
        declaredSections.every(
          (s) =>
              s['kind'] == 'relations' ||
              (s['kind'] == 'fields' &&
                  (s['keys'] as List?)?.length == 1 &&
                  (s['keys'] as List).single == 'file'),
        );
    final primaryCredential =
        record.ref.kind == WorkspaceRecordKind.credential &&
        detail.templateState == WorkspaceTemplateState.available &&
        declaredFields.isEmpty &&
        declaredSections.isEmpty;
    final standalone =
        documentSection != null || primaryFile || primaryCredential;
    final tabs = <Widget>[
      _tab(
        context,
        '概览',
        !_relations,
        () => setState(() => _relations = false),
      ),
      const SizedBox(width: 24),
      _tab(
        context,
        '关联资料',
        _relations,
        () => setState(() => _relations = true),
      ),
    ];
    final editButton = DesktopButton(
      kind: DesktopButtonKind.quiet,
      onPressed: widget.onEdit,
      fontSize: 13,
      padding: EdgeInsets.symmetric(vertical: standalone ? 8 : 10),
      child: const Text('编辑信息'),
    );
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RecordIcon(record.type, size: widget.metrics.iconSize),
              SizedBox(width: widget.metrics.headerGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      record.name,
                      key: const ValueKey('library-detail-title'),
                      style:
                          libraryText(
                            context,
                            widget.metrics.titleSize,
                            height: 1.45,
                            weight: FontWeight.w600,
                          ).copyWith(
                            letterSpacing: -.4,
                            fontVariations: [
                              const FontVariation('wght', 650),
                              // Match CSS automatic optical sizing for the same
                              // installed variable face and actual logical size.
                              FontVariation.opticalSize(
                                MediaQuery.textScalerOf(
                                  context,
                                ).scale(widget.metrics.titleSize),
                              ),
                            ],
                          ),
                    ),
                    const SizedBox(height: 6),
                    _description(context, record.description),
                    const SizedBox(height: 11),
                    Wrap(
                      key: const ValueKey('library-detail-meta'),
                      spacing: 7,
                      runSpacing: 7,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          key: const ValueKey('library-detail-type'),
                          height: libraryMetaHeight(context),
                          padding: const EdgeInsets.symmetric(horizontal: 9),
                          decoration: BoxDecoration(
                            color: c.nav,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Center(
                            widthFactor: 1,
                            child: Text(
                              record.type.name,
                              style: libraryText(context, 13, color: c.muted),
                            ),
                          ),
                        ),
                        for (final tag in record.tags)
                          LibraryTag.detail(
                            tag.name,
                            key: ValueKey('library-detail-tag-${tag.id}'),
                            onPressed: () => widget.onTag(tag.id),
                          ),
                        DesktopButton(
                          key: const ValueKey('library-detail-edit-tags'),
                          kind: DesktopButtonKind.quiet,
                          onPressed: widget.onEdit,
                          leading: const PrototypeIcon(
                            PrototypeIconGlyph.plus,
                            size: 19,
                          ),
                          fontSize: 13,
                          minimumSize: Size(0, libraryMetaHeight(context)),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 13,
                            vertical: 8,
                          ),
                          child: const Text('标签'),
                        ),
                        if (documentSection != null) ...[
                          LibraryDocumentTools(
                            controller: _documentReading,
                            format: detail.values['bodyFormat'] is String
                                ? detail.values['bodyFormat'] as String
                                : 'unknown',
                            canToggle: !libraryDocumentIsLarge(
                              detail.values['body']?.toString() ?? '',
                            ),
                          ),
                        ],
                        if (standalone) editButton,
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(width: widget.metrics.headerGap),
              DesktopButton(
                key: const ValueKey('library-detail-expand'),
                onPressed: widget.onExpand,
                tooltip: '展开阅读',
                kind: DesktopButtonKind.quiet,
                minimumSize: const Size(36, 36),
                padding: const EdgeInsets.all(8),
                child: const PrototypeIcon(PrototypeIconGlyph.expand, size: 19),
              ),
              const SizedBox(width: 2),
              SizedBox(
                width: 36,
                child: DesktopSelect<String>(
                  compact: true,
                  quiet: true,
                  minimumTriggerSize: const Size(36, 36),
                  triggerPadding: const EdgeInsets.all(8),
                  tooltip: '资料操作',
                  triggerLabel: const PrototypeIcon(
                    PrototypeIconGlyph.more,
                    size: 19,
                  ),
                  key: const ValueKey('library-record-actions'),
                  items: [
                    const DropdownMenuItem(value: 'edit', child: Text('编辑信息')),
                    if (widget.onAdopt != null)
                      const DropdownMenuItem(
                        value: 'adopt',
                        child: Text('采用资料模板'),
                      ),
                    if (widget.onHistory != null)
                      DropdownMenuItem(
                        value: 'history',
                        child: Text(
                          record.ref.kind == WorkspaceRecordKind.credential
                              ? '材料版本'
                              : '内容版本',
                        ),
                      ),
                    if (widget.onRecycle != null)
                      const DropdownMenuItem(
                        value: 'recycle',
                        child: Text('移到回收站'),
                      ),
                  ],
                  onChanged: widget.onEdit == null
                      ? null
                      : (action) {
                          switch (action) {
                            case 'adopt':
                              widget.onAdopt?.call();
                            case 'history':
                              widget.onHistory?.call();
                            case 'recycle':
                              widget.onRecycle?.call();
                            default:
                              widget.onEdit?.call();
                          }
                        },
                ),
              ),
            ],
          ),
          if (!standalone) ...[
            const SizedBox(height: 18),
            Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.line)),
              ),
              child: Row(children: [...tabs, const Spacer(), editButton]),
            ),
          ],
          if (detail.templateState != WorkspaceTemplateState.available)
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Text(
                detail.templateState == WorkspaceTemplateState.disabled
                    ? '模板插件已停用，按保留的字段显示。已有内容可继续编辑。'
                    : detail.templateState ==
                          WorkspaceTemplateState.removedDefinition
                    ? '当前插件不再提供此模板，按保留的字段显示。已有内容可继续编辑。'
                    : '模板插件未安装，按保留的字段显示。已有内容可继续编辑。',
                key: const ValueKey('library-template-unavailable'),
                style: libraryText(context, 13, color: c.muted),
              ),
            ),
          if (detail.definition['legacyTemplateVersion'] case final int version)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Text(
                '沿用旧版模板第$version版的录入结构；字段内容由这份资料独立保存。',
                style: libraryText(context, 13, color: c.muted),
              ),
            ),
          TemplateRecordContent(
            detail: detail,
            relations: widget.source,
            onOpen: widget.onOpen,
            documentController: _documentReading,
            relationsOnly: _relations && !standalone,
            fileBuilder: (fieldKey) => LibraryFile(
              key: ValueKey('library-file-${record.ref.key}-$fieldKey'),
              detail: detail,
              fieldKey: fieldKey,
              source: widget.source,
              picker: widget.filePicker,
              onModalChanged: widget.onModalChanged,
            ),
            credentialBuilder: (_) => LibraryCredential(
              key: ValueKey(record.ref),
              ref: record.ref,
              source: widget.source,
              revision: widget.revision,
              onOpen: widget.onOpen,
              onModalChanged: widget.onModalChanged,
              picker: widget.credentialPicker,
              onApproval: widget.onApproval,
            ),
            hostIdentity: HostIdentityButton(
              source: widget.source,
              record: record.ref,
              onPressed: widget.onSettings,
            ),
          ),
        ],
      ),
    );
  }
}
