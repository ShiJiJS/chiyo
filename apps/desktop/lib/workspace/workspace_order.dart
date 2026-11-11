import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'workspace_records.dart';

/// Sort metadata before grouping and paging. IDs break collation/date ties;
/// the platform comparator never sees fields, attachment bytes or secrets.
void sortWorkspaceSummaries(
  List<WorkspaceRecordSummary> items,
  WorkspaceSort sort, {
  List<WorkspaceRecordRef>? manualRecords,
  List<String?>? manualDirectories,
}) {
  int stable(int order, WorkspaceRecordSummary a, WorkspaceRecordSummary b) =>
      order != 0 ? order : a.ref.key.compareTo(b.ref.key);
  if (sort == WorkspaceSort.manual) {
    final records = {
      for (var i = 0; i < (manualRecords?.length ?? 0); i++)
        manualRecords![i]: i,
    };
    final directories = {
      for (var i = 0; i < (manualDirectories?.length ?? 0); i++)
        manualDirectories![i]: i,
    };
    final initial = {for (var i = 0; i < items.length; i++) items[i].ref: i};
    items.sort((a, b) {
      final group = (directories[a.directoryId] ?? directories.length)
          .compareTo(directories[b.directoryId] ?? directories.length);
      return group != 0
          ? group
          : stable(
              (records[a.ref] ?? records.length + initial[a.ref]!).compareTo(
                records[b.ref] ?? records.length + initial[b.ref]!,
              ),
              a,
              b,
            );
    });
    return;
  }
  if (sort == WorkspaceSort.updated) {
    items.sort((a, b) => stable(b.updatedAt.compareTo(a.updatedAt), a, b));
    return;
  }
  if (!Platform.isMacOS && !Platform.isWindows) {
    items.sort((a, b) => stable(a.name.compareTo(b.name), a, b));
    return;
  }
  final _NameOrder order = Platform.isWindows
      ? _WindowsNameOrder()
      : _MacNameOrder();
  try {
    order.initialize();
    items.sort((a, b) => stable(order.compare(a.name, b.name), a, b));
  } finally {
    order.dispose();
  }
}

abstract interface class _NameOrder {
  void initialize();
  int compare(String a, String b);
  void dispose();
}

/// Explicit Chinese collation, independent of the Windows display language.
/// CompareStringEx consumes UTF-16 lengths, including embedded NULs. It returns
/// 1/2/3 for less/equal/greater; zero is an API failure, never a sorting result.
class _WindowsNameOrder implements _NameOrder {
  static final _compare = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Uint32,
          Pointer<Utf16>,
          Int32,
          Pointer<Utf16>,
          Int32,
          Pointer<Void>,
          Pointer<Void>,
          IntPtr,
        ),
        int Function(
          Pointer<Utf16>,
          int,
          Pointer<Utf16>,
          int,
          Pointer<Utf16>,
          int,
          Pointer<Void>,
          Pointer<Void>,
          int,
        )
      >('CompareStringEx');
  final _arena = Arena();
  final _strings = <String, Pointer<Utf16>>{};
  late Pointer<Utf16> _locale;
  Pointer<Utf16> _string(String value) =>
      _strings.putIfAbsent(value, () => value.toNativeUtf16(allocator: _arena));
  @override
  void initialize() => _locale = _string('zh-CN');
  @override
  int compare(String a, String b) {
    final result = _compare(
      _locale,
      0,
      _string(a),
      a.length,
      _string(b),
      b.length,
      nullptr,
      nullptr,
      0,
    );
    if (result == 0) throw StateError('Chinese name comparison failed');
    return result - 2;
  }

  @override
  void dispose() => _arena.releaseAll();
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
class _MacNameOrder implements _NameOrder {
  final _cf = _CoreFoundation.instance;
  final _arena = Arena();
  final _strings = <String, Pointer<Void>>{};
  Pointer<Void> _locale = nullptr;
  late final Pointer<_CFRange> _range = _arena<_CFRange>();

  @override
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

  @override
  int compare(String a, String b) {
    _range.ref
      ..location = 0
      ..length = a.length;
    return _cf.compare(_string(a), _string(b), _range.ref, 0, _locale);
  }

  @override
  void dispose() {
    if (_locale != nullptr) _cf.release(_locale);
    for (final text in _strings.values) {
      _cf.release(text);
    }
    _arena.releaseAll();
  }
}
