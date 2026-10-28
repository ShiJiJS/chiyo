import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

typedef _NativePixels = ({
  int width,
  int height,
  int captureUs,
  Uint8List data,
});

Future<_NativePixels> _readPixels(RenderRepaintBoundary boundary) async {
  final clock = Stopwatch()..start();
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    if (image.width > 4096 ||
        image.height > 4096 ||
        image.width * image.height > 8388608) {
      throw StateError('Native framebuffer exceeds the pixel limit');
    }
    final bytes = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (bytes == null ||
        bytes.lengthInBytes != image.width * image.height * 4) {
      throw StateError(
        'Native framebuffer did not return complete RGBA pixels',
      );
    }
    final data = Uint8List.fromList(
      ZLibCodec(level: 1).encode(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      ),
    );
    return (
      width: image.width,
      height: image.height,
      captureUs: clock.elapsedMicroseconds,
      data: data,
    );
  } finally {
    image.dispose();
  }
}

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
  bool _savingStill = false;
  int _stillPixels = 0, _stillBytes = 0;
  final _stills = <Map<String, Object?>>[];
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
      if (_pending != null || _savingStill) {
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

  /// Retain exact pixels now; PNG filtering runs on the host after app exit.
  /// Still capture shares the sampling gate so two framebuffer reads never
  /// overlap. Screenshots before/after the clip use the same bounded format.
  Future<void> saveStill(String name) async {
    if (RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,159}$').stringMatch(name) !=
            name ||
        _stills.any((s) => s['output'] == '$name.png')) {
      throw ArgumentError.value(
        name,
        'name',
        'Unique simple filename required',
      );
    }
    if (_savingStill) throw StateError('A still capture is already active');
    if (_stills.length >= 256) {
      throw StateError('Native still count limit reached');
    }
    _savingStill = true;
    Future<void>? pending;
    try {
      await _pending;
      if (_error != null) throw StateError('Native recording failed: $_error');
      pending = _saveStill(name);
      _pending = pending;
      await pending;
    } finally {
      if (identical(_pending, pending)) _pending = null;
      _savingStill = false;
    }
  }

  Future<void> _saveStill(String name) async {
    final boundary = boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || boundary.debugNeedsPaint) {
      throw StateError('Native still requires a painted framebuffer');
    }
    final duringRecording = _started && !_stopped;
    final ms = duringRecording ? _clock.elapsedMilliseconds : null;
    final frame = await _readPixels(boundary);
    if (_stillPixels + frame.width * frame.height > 512000000 ||
        _stillBytes + frame.data.length > _maximumBytes) {
      throw StateError('Native still resource limit reached');
    }
    final directory = Directory('${output.path}/native-stills');
    await directory.create(recursive: true);
    final file = 'native-stills/$name.rgba.zlib';
    await File('${output.path}/$file').writeAsBytes(frame.data);
    _stillPixels += frame.width * frame.height;
    _stillBytes += frame.data.length;
    _stills.add({
      'file': file,
      'output': '$name.png',
      'format': 'rgba8888-zlib',
      'width': frame.width,
      'height': frame.height,
      'captureUs': frame.captureUs,
      'compressedBytes': frame.data.length,
      'recordingActive': duringRecording,
      'recordingMs': ms,
    });
    await File('${output.path}/native-stills.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'kind': 'native-flutter-stills-raw-rgba',
        'pixelRatio': 1,
        'viewportCropped': false,
        'pngEncodingDeferred': true,
        'stills': _stills,
      }),
    );
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
    final frame = await _readPixels(boundary);
    if (_bufferedBytes + frame.data.length > _maximumBytes) {
      throw StateError('Native recording buffer limit reached');
    }
    _bufferedBytes += frame.data.length;
    _frames.add((
      ms: startedUs ~/ 1000,
      width: frame.width,
      height: frame.height,
      captureUs: frame.captureUs,
      data: frame.data,
    ));
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
