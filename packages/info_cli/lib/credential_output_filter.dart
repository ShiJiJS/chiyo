import 'dart:convert';
import 'dart:typed_data';

/// Masks exact known material bytes before output is encoded or retained.
/// Each pipe needs its own instance. This cannot recognize transformed secrets.
class CredentialOutputFilter {
  CredentialOutputFilter(Iterable<List<int>> secrets)
    : _patterns = [
        for (final bytes in secrets)
          if (bytes.isNotEmpty) _Pattern(bytes),
      ];
  final List<_Pattern> _patterns;
  final _pending = <int>[], _masks = <_Mask>[];
  int _processed = 0, _base = 0, _lastMaskEnd = -1;
  bool _finished = false;
  static final _replacement = utf8.encode('[REDACTED]');

  List<int> add(List<int> bytes) {
    if (_finished) throw StateError('Output already finished');
    if (_patterns.isEmpty) return List<int>.of(bytes);
    _pending.addAll(bytes);
    for (final byte in bytes) {
      _processed++;
      for (final pattern in _patterns) {
        if (pattern.advance(byte)) {
          var start = _processed - pattern.bytes.length;
          while (_masks.isNotEmpty && _masks.last.end >= start) {
            final previous = _masks.removeLast();
            if (previous.start < start) start = previous.start;
          }
          _masks.add(_Mask(start, _processed));
        }
      }
    }
    // Only an unfinished matching prefix can participate in a future secret.
    // Do not delay ordinary output by the length of a large key file.
    final held = _patterns.fold(0, (int n, p) => p.matched > n ? p.matched : n);
    return _flush(_processed - held);
  }

  List<int> finish() {
    if (_finished) return [];
    _finished = true;
    final result = _flush(_processed);
    _patterns.clear();
    return result;
  }

  List<int> _flush(int safeEnd) {
    if (safeEnd <= _base) return [];
    final result = <int>[];
    var cursor = _base, consumed = 0;
    void raw(int end) {
      if (end <= cursor) return;
      result.addAll(_pending.getRange(cursor - _base, end - _base));
      cursor = end;
      _lastMaskEnd = -1;
    }

    for (final mask in _masks) {
      if (mask.start >= safeEnd) break;
      consumed++;
      if (mask.end <= cursor) continue;
      raw(mask.start.clamp(cursor, safeEnd));
      if (mask.start > _lastMaskEnd) result.addAll(_replacement);
      _lastMaskEnd = mask.end;
      cursor = mask.end;
    }
    raw(safeEnd.clamp(cursor, _processed));
    _pending.removeRange(0, cursor - _base);
    _base = cursor;
    _masks.removeRange(0, consumed);
    return result;
  }
}

class _Mask {
  const _Mask(this.start, this.end);
  final int start, end;
}

/// KMP state keeps matching work linear even for long repeated prefixes.
class _Pattern {
  _Pattern(List<int> source)
    : bytes = Uint8List.fromList(source).asUnmodifiableView(),
      failure = Uint32List(source.length) {
    var prefix = 0;
    for (var i = 1; i < bytes.length; i++) {
      while (prefix > 0 && bytes[prefix] != bytes[i]) {
        prefix = failure[prefix - 1];
      }
      if (bytes[prefix] == bytes[i]) prefix++;
      failure[i] = prefix;
    }
  }
  final List<int> bytes, failure;
  int matched = 0;
  bool advance(int byte) {
    while (matched > 0 && bytes[matched] != byte) {
      matched = failure[matched - 1];
    }
    if (bytes[matched] == byte) matched++;
    if (matched != bytes.length) return false;
    matched = failure[matched - 1];
    return true;
  }
}
