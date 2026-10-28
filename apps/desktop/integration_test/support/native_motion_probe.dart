import 'dart:async';
import 'package:flutter/widgets.dart';

/// Reads this app's rendered properties after actual native frames. It neither
/// captures another app nor synthesizes operating-system input. The recorder
/// requests normal engine frames while observing; it never advances a fake
/// clock. Frame-start wall timestamps exclude variable layout/paint latency.
/// Also retain post-frame read times and delay to diagnose that latency. A
/// post-frame callback is not an observation of pixels presented by the OS.
Future<List<Map<String, Object>>> traceNativeMotion({
  required Map<String, Object>? Function() read,
  required bool Function(Map<String, Object>) complete,
}) async {
  final result = Completer<List<Map<String, Object>>>();
  final samples = <Map<String, Object>>[];
  final binding = WidgetsBinding.instance;
  final clock = Stopwatch()..start();
  Duration? first;
  int? firstWallUs;
  int? firstReadUs;
  var frameStartUs = 0;
  int? pendingFrame;
  var active = true;
  late void Function(Duration) begin;
  void capture(Duration frame) {
    if (!active) return;
    try {
      final value = read();
      final readUs = clock.elapsedMicroseconds;
      if (value != null) {
        if (first == null) {
          first = frame;
          firstWallUs = frameStartUs;
          firstReadUs = readUs;
        }
        samples.add({
          'frameMs': (frame - first!).inMicroseconds / 1000,
          'wallMs': (frameStartUs - firstWallUs!) / 1000,
          'observerDelayMs': (clock.elapsedMicroseconds - frameStartUs) / 1000,
          'readWallMs': (readUs - firstReadUs!) / 1000,
          'frameReadDelayMs': (readUs - frameStartUs) / 1000,
          ...value,
        });
        if (samples.length > 1 && complete(value)) {
          active = false;
          result.complete(samples);
          return;
        }
      }
      pendingFrame = binding.scheduleFrameCallback(begin);
    } catch (error, stack) {
      active = false;
      result.completeError(error, stack);
    }
  }

  begin = (frame) {
    if (!active) return;
    frameStartUs = clock.elapsedMicroseconds;
    binding.addPostFrameCallback(capture);
  };
  pendingFrame = binding.scheduleFrameCallback(begin);
  try {
    return await result.future.timeout(const Duration(seconds: 5));
  } finally {
    active = false;
    if (pendingFrame != null) binding.cancelFrameCallbackWithId(pendingFrame!);
  }
}
