import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'workspace_records.dart';

/// Sort metadata before grouping and paging. IDs break collation/date ties;
/// the platform comparator never sees fields, attachment bytes or secrets.
void sortWorkspaceSummaries(
  List<WorkspaceRecordSummary> items,
  WorkspaceSort sort,
) {
  int stable(int order, WorkspaceRecordSummary a, WorkspaceRecordSummary b) =>
      order != 0 ? order : a.ref.key.compareTo(b.ref.key);
  if (sort == WorkspaceSort.updated) {
    items.sort((a, b) => stable(b.updatedAt.compareTo(a.updatedAt), a, b));
    return;
  }
  if (!Platform.isMacOS) {
    // Retain the existing non-Mac behavior until that platform's delivery work.
    items.sort((a, b) => stable(a.name.compareTo(b.name), a, b));
    return;
  }
  final order = _MacNameOrder();
  try {
    order.initialize();
    items.sort((a, b) => stable(order.compare(a.name, b.name), a, b));
  } finally {
    order.dispose();
  }
}

final class _CFRange extends Struct {
  @IntPtr()
  external int location;
  @IntPtr()
  external int length;
}

/// Public Core Foundation APIs, available since macOS 10.5. Explicit zh_CN
/// matches the frozen UI's zh-CN name order, independent of machine language.
/// https://developer.apple.com/documentation/corefoundation/cfstringcomparewithoptionsandlocale(_:_:_:_:_:)
class _CoreFoundation {
  _CoreFoundation() : library = DynamicLibrary.open(path);
  static const path =
      '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation';
  static final instance = _CoreFoundation();
  final DynamicLibrary library;
  late final createString = library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint16>, IntPtr),
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint16>, int)
      >('CFStringCreateWithCharacters');
  late final createLocale = library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>)
      >('CFLocaleCreate');
  late final compare = library
      .lookupFunction<
        IntPtr Function(
          Pointer<Void>,
          Pointer<Void>,
          _CFRange,
          UintPtr,
          Pointer<Void>,
        ),
        int Function(Pointer<Void>, Pointer<Void>, _CFRange, int, Pointer<Void>)
      >('CFStringCompareWithOptionsAndLocale');
  late final release = library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CFRelease');
}

/// Owns one sort's locale, string cache and UTF-16 buffers. Release everything
/// even if initialization or comparison fails; no native objects survive a query.
class _MacNameOrder {
  final _cf = _CoreFoundation.instance;
  final _arena = Arena();
  final _strings = <String, Pointer<Void>>{};
  Pointer<Void> _locale = nullptr;
  late final Pointer<_CFRange> _range = _arena<_CFRange>();

  void initialize() {
    _locale = _cf.createLocale(nullptr, _string('zh_CN'));
    if (_locale == nullptr) throw StateError('Chinese name locale unavailable');
  }

  Pointer<Void> _string(String value) => _strings.putIfAbsent(value, () {
    // CFString copies exactly value.length UTF-16 code units, including embedded
    // NULs and both halves of supplementary characters; it is not a C string.
    final text = _cf.createString(
      nullptr,
      value.toNativeUtf16(allocator: _arena).cast<Uint16>(),
      value.length,
    );
    if (text == nullptr) throw StateError('Name string allocation failed');
    return text;
  });

  int compare(String a, String b) {
    _range.ref
      ..location = 0
      ..length = a.length;
    return _cf.compare(_string(a), _string(b), _range.ref, 0, _locale);
  }

  void dispose() {
    if (_locale != nullptr) _cf.release(_locale);
    for (final text in _strings.values) {
      _cf.release(text);
    }
    _arena.releaseAll();
  }
}
