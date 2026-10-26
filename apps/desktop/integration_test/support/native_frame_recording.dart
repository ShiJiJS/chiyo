import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
  final _frames = <({int ms, List<int> png})>[];
  final events = <Map<String, Object>>[];
  Timer? _timer;
  Future<void>? _pending;
  Object? _error;

  void mark(String event) =>
      events.add({'event': event, 'ms': _clock.elapsedMilliseconds});

  Future<void> start() async {
    await output.create(recursive: true);
    _clock.start();
    await _capture();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_pending != null || _frames.length >= 900) return;
      _pending = _capture()
          .catchError((Object error) {
            _error = error;
          })
          .whenComplete(() => _pending = null);
    });
  }

  Future<void> _capture() async {
    final boundary = boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || boundary.debugNeedsPaint) return;
    final time = _clock.elapsedMilliseconds;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes != null) {
        _frames.add((ms: time, png: bytes.buffer.asUint8List()));
      }
    } finally {
      image.dispose();
    }
  }

  Future<void> stop(String name) async {
    _timer?.cancel();
    await _pending;
    await _capture();
    _clock.stop();
    if (_error != null) throw StateError('Native recording failed: $_error');
    if (_frames.length < 3) {
      throw StateError('Insufficient native recording frames');
    }
    final duration = _clock.elapsedMilliseconds;
    final framesDirectory = Directory('${output.path}/$name-frames');
    await framesDirectory.create(recursive: true);
    final frameFiles = <Map<String, Object>>[];
    for (final (index, frame) in _frames.indexed) {
      final fileName =
          '$name-frames/frame-${index.toString().padLeft(5, '0')}.png';
      await File('${output.path}/$fileName').writeAsBytes(frame.png);
      frameFiles.add({'ms': frame.ms, 'file': fileName});
    }
    await File('${output.path}/$name.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'kind': 'native-flutter-framebuffer-with-widget-input',
        'wallClockDurationMs': duration,
        'samplingTargetFps': 20,
        'frames': frameFiles,
        'sourceFrames': _frames.map((frame) => frame.ms).toList(),
        'events': events,
        'osDesktopCapture': false,
        'systemDpiChanged': false,
      }),
    );
    final encoder = await Process.run(python, [
      encoderScript,
      '--manifest',
      '${output.path}/$name.json',
    ]);
    if (encoder.exitCode != 0) {
      throw StateError('Recording encoding failed: ${encoder.stderr}');
    }
    for (final entry in {
      'start': _frames.first,
      'middle': _frames[_frames.length ~/ 2],
      'end': _frames.last,
    }.entries) {
      await File(
        '${output.path}/$name-${entry.key}.png',
      ).writeAsBytes(entry.value.png);
    }
    _frames.clear();
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _pending;
    _clock.stop();
  }
}
