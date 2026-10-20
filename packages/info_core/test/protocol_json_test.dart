import 'dart:convert';
import 'package:info_core/protocol_json.dart';
import 'package:test/test.dart';

void main() {
  test(
    'byte limits match UTF8 for all widths, surrogate edges and mixed JSON',
    () {
      final values = [
        'ASCII',
        String.fromCharCode(0x7ff),
        String.fromCharCode(0x800),
        String.fromCharCode(0xd7ff),
        String.fromCharCode(0xd800),
        String.fromCharCode(0xdc00),
        String.fromCharCode(0xffff),
        String.fromCharCode(0x10000),
        String.fromCharCode(0x10ffff),
        'a中文😀e\u0301',
      ];
      for (final value in values) {
        for (final input in [
          jsonEncode({'v': value}),
          ' {"v":"$value"} ',
        ]) {
          final expected = jsonDecode(input);
          final size = utf8.encode(input).length;
          expect(decodeProtocolObject(input, maxBytes: size), expected);
          expect(
            () => decodeProtocolObject(input, maxBytes: size - 1),
            throwsFormatException,
          );
        }
      }
    },
  );
  test(
    'escaped quotes, nested-looking value strings and values with duplicate text remain values',
    () {
      final input = jsonEncode({
        'literal': '{"a":1,"a":2}',
        'quotes': '\\" }[]:{',
        'unicode': '😀',
      });
      expect(decodeProtocolObject(input), jsonDecode(input));
    },
  );
  test(
    'escaped and unicode duplicate member names still reject at any nesting',
    () {
      for (final input in [
        r'{"a":1,"\u0061":2}',
        r'{"x":[{"y":1,"y":2}]}',
        '{"😀":1,"\\ud83d\\ude00":2}',
      ]) {
        expect(() => decodeProtocolObject(input), throwsFormatException);
      }
      expect(decodeProtocolObject('{"é":1,"e\\u0301":2}'), {
        'é': 1,
        'e\u0301': 2,
      });
    },
  );
  test(
    'large value strings decode once while obeying the exact source byte limit',
    () {
      final value = 'x' * 1024 * 1024;
      final input = jsonEncode({'text': value});
      expect(
        decodeProtocolObject(input, maxBytes: input.length)['text'],
        value,
      );
      expect(
        () => decodeProtocolObject(input, maxBytes: input.length - 1),
        throwsFormatException,
      );
    },
  );
  test('depth boundary remains enforced after the native JSON parser', () {
    Object nested = 0;
    for (var i = 0; i < 63; i++) {
      nested = [nested];
    }
    expect(
      decodeProtocolObject(jsonEncode({'x': nested})),
      isA<Map<String, dynamic>>(),
    );
    expect(
      () => decodeProtocolObject(
        jsonEncode({
          'x': [nested],
        }),
      ),
      throwsFormatException,
    );
  });
  test('invalid syntax and nonfinite numbers are still rejected', () {
    for (final input in [
      '{"x":}',
      '{"x":1e999}',
      '[]',
      '{"x":"unterminated}',
      '',
    ]) {
      expect(() => decodeProtocolObject(input), throwsFormatException);
    }
  });
}
