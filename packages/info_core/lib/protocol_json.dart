import 'dart:convert';

/// Strict RFC JSON object decoding. Duplicate members are
/// rejected before any caller can treat the last value as authoritative.
Map<String, dynamic> decodeProtocolObject(
  String source, {
  int maxBytes = 262144,
}) {
  // Do not allocate a second full UTF-8 copy of a large backup JSON string.
  // Unpaired UTF-16 surrogates use the encoder's replacement width (3 bytes).
  var bytes = 0;
  for (final rune in source.runes) {
    bytes += rune <= 0x7f
        ? 1
        : rune <= 0x7ff
        ? 2
        : rune <= 0xffff
        ? 3
        : 4;
    if (bytes > maxBytes) throw const FormatException();
  }
  final value = jsonDecode(source);
  if (value is! Map<String, dynamic>) throw const FormatException();
  _Members(source).value(0);
  return value;
}

class _Members {
  _Members(this.source);
  final String source;
  int at = 0;
  void whitespace() {
    while (at < source.length && ' \n\r\t'.contains(source[at])) {
      at++;
    }
  }

  String string({bool decode = true}) {
    final start = at++;
    while (at < source.length) {
      if (source[at] == '\\') {
        at += 2;
        continue;
      }
      if (source[at++] == '"') {
        // jsonDecode already validated/decoded values. This pass only needs
        // decoded member names to detect escaped duplicate keys.
        return decode ? jsonDecode(source.substring(start, at)) as String : '';
      }
    }
    throw const FormatException();
  }

  void value(int depth) {
    if (depth > 64) throw const FormatException();
    whitespace();
    if (source[at] == '"') {
      string(decode: false);
      return;
    }
    if (source[at] == '{') {
      at++;
      whitespace();
      final names = <String>{};
      if (source[at] == '}') {
        at++;
        return;
      }
      while (true) {
        whitespace();
        final name = string();
        if (!names.add(name)) throw const FormatException('duplicate_json_key');
        whitespace();
        at++;
        value(depth + 1);
        whitespace();
        if (source[at++] == '}') return;
      }
    }
    if (source[at] == '[') {
      at++;
      whitespace();
      if (source[at] == ']') {
        at++;
        return;
      }
      while (true) {
        value(depth + 1);
        whitespace();
        if (source[at++] == ']') return;
      }
    }
    final start = at;
    while (at < source.length && !',}] \r\n\t'.contains(source[at])) {
      at++;
    }
    final token = source.substring(start, at);
    if (token != 'true' && token != 'false' && token != 'null') {
      final number = num.parse(token);
      if (!number.isFinite) throw const FormatException();
    }
  }
}
