import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'credential_dialogs.dart';
import 'credential_files.dart';
import 'credential_management.dart';
import 'prototype_ui.dart';
import 'ui.dart';
import 'organization.dart' show directoryPath;

class CredentialLibrary extends StatefulWidget {
  const CredentialLibrary({
    super.key,
    required this.owner,
    this.refresh,
    this.onOpenInformation,
    this.onInformationMode,
    this.initialCredentialId,
    this.onOpenUsageHistory,
    this.hasUsageRecords,
    this.files = const NativeCredentialFilePicker(),
  });
  final OwnerAccess owner;
  final Listenable? refresh;
  final ValueChanged<String>? onOpenInformation;
  final VoidCallback? onInformationMode;
  final String? initialCredentialId;
  final ValueChanged<String>? onOpenUsageHistory;
  final bool Function(String credentialId)? hasUsageRecords;
  final CredentialFilePicker files;
  @override
  State<CredentialLibrary> createState() => _CredentialLibraryState();
}

class _CredentialLibraryState extends State<CredentialLibrary> {
  final _search = TextEditingController();
  final _detailScroll = ScrollController();
  final _toolbarScroll = ScrollController();
  String? _selected;
  CredentialForm? _filter;
  int _page = 0;
  UiPalette get p => UiPalette.of(context);
  OwnerAccess get owner => widget.owner;
  @override
  void initState() {
    super.initState();
    _selected = widget.initialCredentialId;
    widget.refresh?.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(CredentialLibrary old) {
    super.didUpdateWidget(old);
    if (old.refresh != widget.refresh) {
      old.refresh?.removeListener(_refresh);
      widget.refresh?.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _detailScroll.dispose();
    _toolbarScroll.dispose();
    widget.refresh?.removeListener(_refresh);
    super.dispose();
  }

  Widget t(
    String text,
    double size, {
    Color? color,
    FontWeight weight = FontWeight.w400,
    double height = 1.5,
    String? family,
    double letterSpacing = 0,
    int? lines,
  }) => Text(
    text,
    maxLines: lines,
    overflow: lines == null ? null : TextOverflow.ellipsis,
    style: prototypeText(
      context,
      size,
      color: color,
      weight: weight,
      height: height,
      family: family,
    ).copyWith(letterSpacing: letterSpacing),
  );
  Widget button(
    String text,
    VoidCallback? action, {
    Key? key,
    bool quiet = false,
    PrototypeIconGlyph? icon,
    double size = 12,
  }) => TextButton(
    key: key,
    onPressed: action,
    style: prototypeButton(
      context,
      size: size,
      foreground: quiet ? p.ink : p.accent,
      padding: quiet
          ? const EdgeInsets.symmetric(horizontal: 13, vertical: 8)
          : EdgeInsets.zero,
      background: quiet ? p.paper : null,
      side: quiet ? BorderSide(color: p.line) : BorderSide.none,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          PrototypeIcon(icon, size: 15),
          const SizedBox(width: 7),
        ],
        Flexible(child: Text(text)),
      ],
    ),
  );
  Future<void> _add() async {
    final result = await showDialog<ManagedCredential>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0x4f241b27),
      builder: (_) => CredentialEditor(owner: owner, files: widget.files),
    );
    if (mounted) {
      setState(() {
        if (result != null) {
          _selected = result.id;
          _search.clear();
          _filter = null;
          _page = 0;
        }
      });
    }
  }

  Future<void> _manage(ManagedCredential c, String action) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0x4f241b27),
      builder: (_) => CredentialManagement(
        owner: owner,
        credential: c,
        action: action,
        files: widget.files,
      ),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    List<ManagedCredential> all;
    try {
      all = owner.credentials;
    } on Object {
      return Center(child: t('凭据暂不可用，请重新打开信息库。', 14));
    }
    final results = all
        .where(
          (c) =>
              (_filter == null || c.form == _filter) &&
              '${c.name} ${c.publicPurpose}'.toLowerCase().contains(
                _search.text.toLowerCase(),
              ),
        )
        .toList();
    if (_page * 50 >= results.length) _page = 0;
    final shown = results.skip(_page * 50).take(50).toList();
    final c =
        shown.where((c) => c.id == _selected).firstOrNull ?? shown.firstOrNull;
    _selected = c?.id;
    Widget columns() => Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 240,
          child: LayoutBuilder(
            builder: (_, bounds) =>
                MediaQuery.textScalerOf(context).scale(1) > 1.5
                ? SingleChildScrollView(
                    primary: false,
                    child: SizedBox(
                      height: bounds.maxHeight + 600,
                      child: _side(all),
                    ),
                  )
                : _side(all),
          ),
        ),
        SizedBox(width: 340, child: _list(shown, results.length, c)),
        Expanded(child: _detail(c)),
      ],
    );
    return Material(
      color: p.canvas,
      child: LayoutBuilder(
        builder: (_, bounds) => bounds.maxWidth < 1120
            ? SingleChildScrollView(
                primary: false,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: 1120,
                  height: bounds.maxHeight,
                  child: columns(),
                ),
              )
            : columns(),
      ),
    );
  }

  Widget _side(List<ManagedCredential> all) => Container(
    padding: const EdgeInsets.fromLTRB(18, 27, 18, 18),
    decoration: BoxDecoration(
      border: Border(right: BorderSide(color: p.line)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              t('信息库', 21, weight: FontWeight.w600),
              Container(
                margin: const EdgeInsets.only(top: 20),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  border: Border.all(color: p.line),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: widget.onInformationMode,
                        style: prototypeButton(
                          context,
                          size: 13,
                          padding: const EdgeInsets.all(7),
                          foreground: p.muted,
                        ),
                        child: const Text('信息'),
                      ),
                    ),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: p.paper,
                          borderRadius: BorderRadius.circular(3),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x11000000),
                              offset: Offset(0, 1),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                        child: Center(child: t('凭据', 13, color: p.strong)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 18, 10, 10),
          child: t('凭据形式', 11, color: p.muted),
        ),
        for (final form in <CredentialForm?>[
          null,
          CredentialForm.string,
          CredentialForm.file,
        ])
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: TextButton(
              onPressed: () => setState(() {
                _filter = form;
                _selected = null;
                _page = 0;
              }),
              style: prototypeButton(
                context,
                size: 13,
                foreground: _filter == form ? p.strong : p.ink,
                background: _filter == form ? p.selected : null,
                radius: 5,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 13,
                ),
              ),
              child: Row(
                children: [
                  PrototypeIcon(
                    form == null
                        ? PrototypeIconGlyph.shield
                        : form == CredentialForm.file
                        ? PrototypeIconGlyph.file
                        : PrototypeIconGlyph.key,
                  ),
                  const SizedBox(width: 11),
                  Text(
                    form == null
                        ? '全部凭据'
                        : form == CredentialForm.file
                        ? '文件'
                        : '字符串',
                  ),
                  const Spacer(),
                  t(
                    '${all.where((c) => form == null || c.form == form).length}',
                    11,
                    color: p.muted,
                  ),
                ],
              ),
            ),
          ),
        const Spacer(),
        if (owner.recycledCredentials.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: button('凭据回收站', () async {
              await showCredentialRecycle(context, owner);
              _refresh();
            }),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(9, 18, 9, 0),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: p.line)),
          ),
          child: t(
            '凭据可以关联多条信息。\n关联只建立引用，使用时仍需审批。',
            13,
            height: 1.9,
            color: p.muted,
          ),
        ),
      ],
    ),
  );
  Widget _list(
    List<ManagedCredential> shown,
    int total,
    ManagedCredential? selected,
  ) => Container(
    decoration: BoxDecoration(
      color: p.rail,
      border: Border(right: BorderSide(color: p.line)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(23, 28, 23, 21),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.line)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    t('凭据', 17, weight: FontWeight.w700),
                    const SizedBox(height: 6),
                    t('$total 项 · 原文默认隐藏', 11, color: p.muted),
                  ],
                ),
              ),
              button(
                '添加',
                _add,
                key: const ValueKey('new-credential'),
                quiet: true,
                icon: PrototypeIconGlyph.plus,
              ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.fromLTRB(20, 17, 20, 5),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            border: Border.all(color: p.line),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              PrototypeIcon(
                PrototypeIconGlyph.search,
                size: 16,
                color: p.muted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 22 * MediaQuery.textScalerOf(context).scale(1),
                  child: TextField(
                    controller: _search,
                    key: const ValueKey('credential-search'),
                    onChanged: (_) => setState(() {
                      _selected = null;
                      _page = 0;
                    }),
                    style: prototypeText(context, 12),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: '搜索名称、用途',
                      hintStyle: prototypeText(context, 12, color: p.muted),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(30),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      t('没有找到凭据', 15, weight: FontWeight.w700),
                      const SizedBox(height: 8),
                      t('试试其他名称或类型。', 13, color: p.muted),
                      const SizedBox(height: 18),
                      button(
                        '清除筛选',
                        () => setState(() {
                          _filter = null;
                          _search.clear();
                        }),
                        quiet: true,
                      ),
                    ],
                  ),
                )
              : ListView(
                  primary: false,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 12,
                  ),
                  children: [
                    for (final c in shown)
                      Container(
                        decoration: BoxDecoration(
                          color: selected?.id == c.id ? p.selected : null,
                          border: selected?.id == c.id
                              ? Border.all(
                                  color: Color.lerp(p.line, p.accent, .25)!,
                                )
                              : Border(
                                  top: const BorderSide(
                                    color: Colors.transparent,
                                  ),
                                  right: const BorderSide(
                                    color: Colors.transparent,
                                  ),
                                  left: const BorderSide(
                                    color: Colors.transparent,
                                  ),
                                  bottom: BorderSide(color: p.line),
                                ),
                          borderRadius: BorderRadius.circular(
                            selected?.id == c.id ? 6 : 0,
                          ),
                        ),
                        child: TextButton(
                          key: ValueKey('credential-row-${c.id}'),
                          onPressed: () => setState(() {
                            _selected = c.id;
                            if (_detailScroll.hasClients) {
                              _detailScroll.jumpTo(0);
                            }
                          }),
                          style: prototypeButton(
                            context,
                            radius: selected?.id == c.id ? 6 : 0,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 13,
                              vertical: 16,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _icon(c, false),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    t(
                                      c.name,
                                      14,
                                      weight: FontWeight.w700,
                                      height: 1.6,
                                      lines: 2,
                                    ),
                                    const SizedBox(height: 5),
                                    t(
                                      c.publicPurpose,
                                      12,
                                      color: p.muted,
                                      lines: 1,
                                    ),
                                    const SizedBox(height: 11),
                                    Wrap(
                                      spacing: 12,
                                      children: [
                                        t(
                                          c.form == CredentialForm.file
                                              ? '文件'
                                              : '字符串',
                                          11,
                                          color: p.muted,
                                        ),
                                        t(
                                          credentialStatus(owner, c),
                                          11,
                                          color: p.muted,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(top: 26),
                                child: PrototypeIcon(
                                  PrototypeIconGlyph.chev,
                                  size: 13,
                                  color: p.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: p.line)),
          ),
          child: Row(
            children: [
              t('独立保管 · 按次授权', 11, color: p.muted),
              const Spacer(),
              if (total > 50) ...[
                button(
                  '‹',
                  _page > 0
                      ? () => setState(() {
                          _page--;
                          _selected = null;
                        })
                      : null,
                ),
                t('${_page + 1} / ${(total / 50).ceil()}', 12),
                button(
                  '›',
                  (_page + 1) * 50 < total
                      ? () => setState(() {
                          _page++;
                          _selected = null;
                        })
                      : null,
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
  Widget _icon(ManagedCredential c, bool large) => Container(
    width: large ? 47 : 33,
    height: large ? 49 : 35,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: large ? p.selected : p.paper,
      border: large ? null : Border.all(color: p.line),
      borderRadius: BorderRadius.circular(large ? 9 : 5),
    ),
    child: PrototypeIcon(
      c.form == CredentialForm.file
          ? PrototypeIconGlyph.file
          : PrototypeIconGlyph.key,
      size: large ? 24 : 18,
      color: p.strong,
    ),
  );
  String expiry(ManagedCredential c) => c.expiresAt == null
      ? '未设置'
      : '${c.expiresAt!.toLocal().year} / ${c.expiresAt!.toLocal().month.toString().padLeft(2, '0')} / ${c.expiresAt!.toLocal().day.toString().padLeft(2, '0')}';
  Widget _detail(ManagedCredential? c) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 21),
    child: Container(
      decoration: BoxDecoration(
        color: p.paper,
        border: Border.all(color: p.line),
        borderRadius: BorderRadius.circular(9),
      ),
      clipBehavior: Clip.antiAlias,
      child: c == null
          ? Center(child: t('选择凭据后查看详情。', 14, color: p.muted))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 55,
                  padding: const EdgeInsets.symmetric(horizontal: 25),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: p.line)),
                  ),
                  child: LayoutBuilder(
                    builder: (_, bounds) => Scrollbar(
                      key: const ValueKey('credential-toolbar-scrollbar'),
                      controller: _toolbarScroll,
                      thumbVisibility:
                          MediaQuery.textScalerOf(context).scale(1) > 1.5,
                      trackVisibility:
                          MediaQuery.textScalerOf(context).scale(1) > 1.5,
                      interactive: true,
                      child: SingleChildScrollView(
                        primary: false,
                        key: const ValueKey('credential-toolbar-scroll'),
                        controller: _toolbarScroll,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: MediaQuery.textScalerOf(context).scale(1) > 1.5
                              ? (bounds.maxWidth > 1100
                                    ? bounds.maxWidth
                                    : 1100)
                              : bounds.maxWidth,
                          child: Row(
                            children: [
                              t('信息库', 12, color: p.muted),
                              const SizedBox(width: 10),
                              const PrototypeIcon(
                                PrototypeIconGlyph.chev,
                                size: 12,
                              ),
                              const SizedBox(width: 10),
                              t('凭据详情', 12, color: p.muted),
                              const Spacer(),
                              Transform.translate(
                                offset: const Offset(0, 4),
                                child: Wrap(
                                  alignment: WrapAlignment.end,
                                  spacing: 15,
                                  children: [
                                    button(
                                      '可见性与有效期',
                                      () => _manage(c, 'metadata'),
                                      key: const ValueKey(
                                        'credential-metadata',
                                      ),
                                      size: 13,
                                    ),
                                    button(
                                      '更换版本',
                                      () => _manage(c, 'rotate'),
                                      size: 13,
                                    ),
                                    button(
                                      c.enabled ? '停用' : '启用',
                                      () => _manage(
                                        c,
                                        c.enabled ? 'disable' : 'enable',
                                      ),
                                      size: 13,
                                    ),
                                    button(
                                      '删除',
                                      () => _manage(c, 'delete'),
                                      size: 13,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    primary: false,
                    key: const ValueKey('credential-detail-scroll'),
                    controller: _detailScroll,
                    padding: const EdgeInsets.fromLTRB(33, 23, 33, 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        t(
                          '凭据 / ${c.form == CredentialForm.file ? '文件' : '字符串'}',
                          12,
                          color: p.muted,
                        ),
                        const SizedBox(height: 22),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _icon(c, true),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  t(
                                    c.name,
                                    25,
                                    weight: FontWeight.w700,
                                    height: 1.4,
                                  ),
                                  const SizedBox(height: 7),
                                  t(
                                    c.privateNote,
                                    13,
                                    height: 1.8,
                                    color: p.muted,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        Container(
                          margin: const EdgeInsets.only(top: 22),
                          padding: const EdgeInsets.symmetric(vertical: 17),
                          decoration: BoxDecoration(
                            border: Border(
                              top: BorderSide(color: p.line),
                              bottom: BorderSide(color: p.line),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final property in [
                                ('用途', c.publicPurpose),
                                ('当前版本', '版本 ${c.version}'),
                                ('到期时间', expiry(c)),
                              ].indexed) ...[
                                if (property.$1 > 0) const SizedBox(width: 20),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      t(property.$2.$1, 11, color: p.muted),
                                      const SizedBox(height: 8),
                                      t(property.$2.$2, 12),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Container(
                          margin: const EdgeInsets.only(top: 25),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 19,
                          ),
                          decoration: BoxDecoration(
                            color: p.rail,
                            border: Border.all(color: p.line),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Row(
                            children: [
                              PrototypeIcon(
                                PrototypeIconGlyph.shield,
                                size: 24,
                                color: p.strong,
                              ),
                              const SizedBox(width: 15),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    t(
                                      c.form == CredentialForm.file
                                          ? c.fileName!
                                          : '•••• •••• •••• ••••',
                                      15,
                                      family: 'Consolas',
                                      letterSpacing: 1,
                                      height: 1.2,
                                    ),
                                    const SizedBox(height: 7),
                                    t(
                                      c.form == CredentialForm.file
                                          ? '${c.byteLength} B · 文件内容不展示'
                                          : '原文不返回到普通信息读取接口',
                                      12,
                                      color: p.muted,
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: p.paper,
                                  border: Border.all(color: p.line),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: t(
                                  c.form == CredentialForm.file
                                      ? '加密文件'
                                      : '加密内容',
                                  11,
                                  color: p.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (owner.credentialAvailability(c) !=
                            CredentialAvailability.available)
                          Container(
                            key: const ValueKey(
                              'credential-unavailable-notice',
                            ),
                            margin: const EdgeInsets.only(top: 22),
                            padding: const EdgeInsets.symmetric(
                              vertical: 16,
                              horizontal: 19,
                            ),
                            decoration: BoxDecoration(
                              color: p.noticeWarningBackground,
                              border: Border.all(color: p.noticeWarningBorder),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: PrototypeIcon(
                                    PrototypeIconGlyph.clock,
                                    size: 18,
                                    color: p.accent,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      t(
                                        '此凭据当前不可使用',
                                        13,
                                        color: p.noticeWarningInk,
                                        height: 1.9,
                                        weight: FontWeight.w700,
                                      ),
                                      const SizedBox(height: 3),
                                      t(
                                        '过期或停用的凭据不能批准新的使用申请。',
                                        13,
                                        color: p.noticeWarningInk,
                                        height: 1.9,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 20),
                        _fact(
                          '可用交付方式',
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              t(
                                c.form == CredentialForm.file
                                    ? '临时路径 → 参数或环境变量'
                                    : '秘密值 → 环境变量',
                                13,
                                weight: FontWeight.w700,
                              ),
                              t(
                                c.form == CredentialForm.file
                                    ? '运行前生成临时文件，进程结束后尝试清理；不会将凭据放入项目目录。'
                                    : '只为本次任务的进程环境提供值，不写入全局环境或命令参数。',
                                13,
                                height: 1.9,
                              ),
                            ],
                          ),
                        ),
                        _fact(
                          c.form == CredentialForm.file ? '文件引用别名' : '建议环境变量名',
                          t(
                            c.suggestedBinding.isEmpty
                                ? '未设置'
                                : c.suggestedBinding,
                            13,
                            family: 'Consolas',
                          ),
                        ),
                        _fact('最近使用', t('尚未使用', 13)),
                        const SizedBox(height: 22),
                        Row(
                          children: [
                            t('关联信息', 16, weight: FontWeight.w700),
                            const Spacer(),
                            t(
                              '${owner.informationForCredential(c.id).length} 条',
                              11,
                              color: p.muted,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        for (final item in owner.informationForCredential(c.id))
                          TextButton(
                            onPressed: widget.onOpenInformation == null
                                ? null
                                : () => widget.onOpenInformation!(item.id),
                            style: prototypeButton(
                              context,
                              padding: const EdgeInsets.symmetric(vertical: 15),
                            ),
                            child: Row(
                              children: [
                                const PrototypeIcon(PrototypeIconGlyph.link),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      t(item.name, 14, weight: FontWeight.w500),
                                      const SizedBox(height: 5),
                                      t(
                                        directoryPath(owner, item.directoryId),
                                        12,
                                        color: p.muted,
                                      ),
                                    ],
                                  ),
                                ),
                                const PrototypeIcon(
                                  PrototypeIconGlyph.chev,
                                  size: 13,
                                ),
                              ],
                            ),
                          ),
                        if (owner.informationForCredential(c.id).isEmpty)
                          credentialHelp(context, '尚未关联信息。可在信息详情中添加关联。'),
                        Padding(
                          padding: const EdgeInsets.only(top: 19),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              PrototypeIcon(
                                PrototypeIconGlyph.shield,
                                size: 16,
                                color: p.muted,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: t(
                                  '运行时注入会让目标程序接触原文。此方式减少对话中的暴露，不提供同用户进程间的强隔离。',
                                  13,
                                  color: p.muted,
                                  height: 1.9,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 27,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: p.rail,
                    border: Border(top: BorderSide(color: p.line)),
                  ),
                  child: Row(
                    children: [
                      PrototypeIcon(
                        PrototypeIconGlyph.shield,
                        size: 15,
                        color: p.muted,
                      ),
                      const SizedBox(width: 8),
                      t('关联不等于授权', 11, color: p.muted),
                      const Spacer(),
                      TextButton(
                        style: prototypeButton(
                          context,
                          size: 13,
                          foreground: p.accent,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                        ),
                        onPressed: () async {
                          await showCredentialVersions(context, owner, c);
                          _refresh();
                        },
                        child: const Text('版本与恢复'),
                      ),
                      if (widget.onOpenUsageHistory != null &&
                          widget.hasUsageRecords?.call(c.id) == true)
                        button(
                          '查看使用记录 →',
                          () => widget.onOpenUsageHistory!(c.id),
                          size: 13,
                        ),
                    ],
                  ),
                ),
              ],
            ),
    ),
  );
  Widget _fact(String name, Widget value) => Container(
    padding: const EdgeInsets.symmetric(vertical: 15),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: p.line)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 122, child: t(name, 13, color: p.muted)),
        const SizedBox(width: 18),
        Expanded(child: value),
      ],
    ),
  );
}
