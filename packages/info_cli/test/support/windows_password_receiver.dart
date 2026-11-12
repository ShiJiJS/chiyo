import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Pipe adapter for the EXCLUDE_FROM_ALL Win32 synthetic receiver. It never
/// focuses windows or sends input; an operator or platform test owns those
/// actions. Only this disposable receiver reads back its own synthetic fields.
final class WindowsPasswordReceiver {
  WindowsPasswordReceiver._(this._process, this._lines, this._errors);
  final Process _process;
  final StreamIterator<String> _lines;
  final Future<void> _errors;
  Future<void> _queue = Future<void>.value();
  Future<void>? _closing;

  static Future<WindowsPasswordReceiver> start(
    String executable,
    String syntheticSecret,
  ) async {
    if (!Platform.isWindows) throw UnsupportedError('Windows receiver only');
    void scan(String text) {
      if (text.contains(syntheticSecret) ||
          text.contains(
            jsonEncode(
              syntheticSecret,
            ).substring(1, jsonEncode(syntheticSecret).length - 1),
          )) {
        throw StateError('Synthetic value escaped receiver metadata');
      }
    }

    if (syntheticSecret.isEmpty) {
      throw ArgumentError('A synthetic value is required');
    }
    final process = await Process.start(executable, []);
    final lines = StreamIterator(
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .map((line) {
            scan(line);
            return line;
          }),
    );
    final receiver = WindowsPasswordReceiver._(
      process,
      lines,
      process.stderr.transform(utf8.decoder).forEach(scan),
    );
    try {
      if ((await receiver._response())['event'] != 'window_ready') {
        throw StateError('Synthetic receiver did not initialize');
      }
      final result = await receiver._call(1, syntheticSecret);
      if (result['event'] != 'expected_ready') {
        throw StateError(
          'Synthetic receiver did not accept its expected value',
        );
      }
      return receiver;
    } on Object {
      await receiver.close();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _response() async {
    if (!await _lines.moveNext().timeout(const Duration(seconds: 5))) {
      throw StateError('Synthetic receiver ended before its response');
    }
    return jsonDecode(_lines.current) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _call(int code, [String? expected]) {
    if (_closing != null) throw StateError('Synthetic receiver is closing');
    final response = _queue.then((_) async {
      final units = expected?.codeUnits ?? const <int>[];
      final bytes = Uint8List(1 + units.length * 2)..[0] = code;
      final view = ByteData.sublistView(bytes);
      for (var i = 0; i < units.length; i++) {
        view.setUint16(1 + i * 2, units[i], Endian.little);
      }
      final header = ByteData(4)..setUint32(0, bytes.length, Endian.little);
      try {
        _process.stdin.add(header.buffer.asUint8List());
        _process.stdin.add(bytes);
        await _process.stdin.flush();
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
      return _response();
    });
    _queue = response.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return response;
  }

  Future<Map<String, dynamic>> verify() => _call(2);
  Future<void> clear() async => await _call(3);
  Future<void> armFocusChange() async => await _call(4);

  /// EOF asks the receiver to close its own window. No force termination or
  /// control of unrelated applications is used for test teardown.
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    await _queue;
    await _process.stdin.close();
    final code = await _process.exitCode.timeout(const Duration(seconds: 8));
    await _lines.cancel();
    await _errors;
    if (code != 0) throw StateError('Synthetic receiver exited unsuccessfully');
  }
}
