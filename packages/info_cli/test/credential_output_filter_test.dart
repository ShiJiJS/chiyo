import 'dart:convert';
import 'dart:math';
import 'package:info_cli/credential_output_filter.dart';
import 'package:test/test.dart';

String reference(String source, List<String> secrets) {
  final ranges = <(int, int)>[];
  for (final secret in secrets.where((s) => s.isNotEmpty)) {
    var from = 0;
    while (from < source.length) {
      final found = source.indexOf(secret, from);
      if (found < 0) break;
      ranges.add((found, found + secret.length));
      from = found + 1;
    }
  }
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[];
  for (final range in ranges) {
    if (merged.isNotEmpty && merged.last.$2 >= range.$1) {
      final previous = merged.removeLast();
      merged.add((previous.$1, max(previous.$2, range.$2)));
    } else {
      merged.add(range);
    }
  }
  final result = StringBuffer();
  var cursor = 0;
  for (final range in merged) {
    result.write(source.substring(cursor, range.$1));
    result.write('[REDACTED]');
    cursor = range.$2;
  }
  result.write(source.substring(cursor));
  return result.toString();
}

void main() {
  test(
    'overlapping secrets, shared prefixes and arbitrary chunk boundaries match whole-stream masking',
    () {
      final random = Random(338);
      String word(int n) =>
          List.generate(n, (_) => 'abc'[random.nextInt(3)]).join();
      for (var example = 0; example < 300; example++) {
        final source = word(60),
            patterns = List.generate(4, (_) => word(1 + random.nextInt(8)));
        final expected = reference(source, patterns);
        for (final size in [1, 2, 3, 7, 64]) {
          final filter = CredentialOutputFilter(patterns.map(utf8.encode));
          final bytes = utf8.encode(source), actual = <int>[];
          for (var i = 0; i < bytes.length; i += size) {
            actual.addAll(
              filter.add(bytes.sublist(i, min(i + size, bytes.length))),
            );
          }
          actual.addAll(filter.finish());
          expect(
            utf8.decode(actual),
            expected,
            reason: 'case=$example size=$size',
          );
          expect(filter.finish(), isEmpty);
        }
      }
    },
  );

  test(
    'binary output and incomplete prefixes remain unchanged, large repeated prefixes stay bounded',
    () {
      final pattern = List<int>.filled(10000, 65, growable: true)..add(66);
      final bytes = [0, 255, ...List<int>.filled(200000, 65), 67];
      final filter = CredentialOutputFilter([pattern]);
      final actual = <int>[];
      for (var i = 0; i < bytes.length; i += 1024) {
        actual.addAll(
          filter.add(bytes.sublist(i, min(i + 1024, bytes.length))),
        );
      }
      actual.addAll(filter.finish());
      expect(actual, bytes);
    },
  );

  test(
    'unrelated output is available without waiting for a large key pattern',
    () {
      final filter = CredentialOutputFilter([utf8.encode('private-' * 10000)]);
      expect(filter.add(utf8.encode('ready\n')), utf8.encode('ready\n'));
      expect(filter.finish(), isEmpty);
    },
  );
}
