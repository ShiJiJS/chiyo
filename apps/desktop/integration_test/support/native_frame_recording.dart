import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Captures this test's real native Flutter framebuffer, never the desktop or
/// another application. A real stopwatch preserves timing when sampling stalls.
/// The resulting video is a native-rendering/widget-input recording, not proof
/// of OS input dispatch or a change to the system's DPI settings.
class NativeFrameRecording {
  NativeFrameRecording(
    this.boundaryKey,
    this.output,
    this.python,
    this.encoderScript,
  );
  final GlobalKey boundaryKey;
  final Directory output;
  final String python, encoderScript;
  final _clock = Stopwatch();
  // PNG filtering/encoding on the UI isolate made 150ms effects nearly
  // invisible in recordings. Keep lossless straight RGBA with fast zlib here;
  // color quantization and GIF encoding happen after interaction has stopped.
  final _frames =
      <({int ms, int width, int height, int captureUs, Uint8List data})>[];
  static const _interval = Duration(milliseconds: 33);
  static const _maximumBytes = 128 * 1024 * 1024;
  int _bufferedBytes = 0, _busyTicks = 0, _unpaintedTicks = 0;
  bool _started = false, _stopped = false;
  final events = <Map<String, Object>>[];
  Timer? _timer;
  Future<void>? _pending;
  Object? _error;

  void mark(String event) =>
      events.add({'event': event, 'ms': _clock.elapsedMilliseconds});

  Future<void> start() async {
    if (_started) throw StateError('A recording can only start once');
    _started = true;
    await output.create(recursive: true);
    _clock.start();
    await _capture();
    _timer = Timer.periodic(_interval, (_) {
      if (_pending != null) {
        _busyTicks++;
        return;
      }
      _pending = _capture()
          .catchError((Object error) {
            _error = error;
            _timer?.cancel();
          })
          .whenComplete(() => _pending = null);
    });
  }

  Future<void> _capture() async {
    final boundary = boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || boundary.debugNeedsPaint) {
      _unpaintedTicks++;
      return;
    }
    if (_frames.length >= 900) {
      throw StateError('Native recording frame limit reached');
    }
    final startedUs = _clock.elapsedMicroseconds;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (bytes == null ||
          bytes.lengthInBytes != image.width * image.height * 4) {
        throw StateError(
          'Native framebuffer did not return complete RGBA pixels',
        );
      }
      final compressed = Uint8List.fromList(
        ZLibCodec(level: 1).encode(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        ),
      );
      if (_bufferedBytes + compressed.length > _maximumBytes) {
        throw StateError('Native recording buffer limit reached');
      }
      _bufferedBytes += compressed.length;
      _frames.add((
        ms: startedUs ~/ 1000,
        width: image.width,
        height: image.height,
        captureUs: _clock.elapsedMicroseconds - startedUs,
        data: compressed,
      ));
    } finally {
      image.dispose();
    }
  }

  Future<void> stop(String name) async {
    if (!_started || _stopped) throw StateError('Recording is not active');
    _timer?.cancel();
    await _pending;
    if (_error != null) throw StateError('Native recording failed: $_error');
    await _capture();
    _clock.stop();
    _stopped = true;
    if (_frames.length < 3) {
      throw StateError('Insufficient native recording frames');
    }
    final duration = _clock.elapsedMilliseconds;
    final framesDirectory = Directory('${output.path}/$name-frames');
    await framesDirectory.create(recursive: true);
    final frameFiles = <Map<String, Object>>[];
    for (final (index, frame) in _frames.indexed) {
      final fileName =
          '$name-frames/frame-${index.toString().padLeft(5, '0')}.rgba.zlib';
      await File('${output.path}/$fileName').writeAsBytes(frame.data);
      frameFiles.add({
        'ms': frame.ms,
        'file': fileName,
        'format': 'rgba8888-zlib',
        'width': frame.width,
        'height': frame.height,
        'captureUs': frame.captureUs,
        'compressedBytes': frame.data.length,
      });
    }
    await File('${output.path}/$name.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'kind': 'native-flutter-framebuffer-with-widget-input',
        'wallClockDurationMs': duration,
        'samplingTargetFps': 30,
        'samplingIntervalUs': _interval.inMicroseconds,
        'busyTicksSkipped': _busyTicks,
        'unpaintedTicksSkipped': _unpaintedTicks,
        'bufferedCompressedBytes': _bufferedBytes,
        'bufferLimitBytes': _maximumBytes,
        'pixelRatio': 1,
        'viewportCropped': false,
        'frames': frameFiles,
        'sourceFrames': _frames.map((frame) => frame.ms).toList(),
        'events': events,
        'osDesktopCapture': false,
        'systemDpiChanged': false,
      }),
    );
    // On macOS the sandboxed preview writes its own temporary evidence only.
    // Encoding runs later in the host QA command, not as a sandbox escape.
    if (python.isNotEmpty && encoderScript.isNotEmpty) {
      final encoder = await Process.run(python, [
        encoderScript,
        '--manifest',
        '${output.path}/$name.json',
      ]);
      if (encoder.exitCode != 0) {
        throw StateError('Recording encoding failed: ${encoder.stderr}');
      }
    }
    _frames.clear();
    _bufferedBytes = 0;
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _pending;
    _clock.stop();
    _frames.clear();
    _bufferedBytes = 0;
  }
}
