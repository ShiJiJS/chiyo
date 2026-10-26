import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:info_desktop/preview_main.dart' as preview;
import 'package:info_desktop/workspace/mac_preview_desktop.dart';

/// QA entry point only. Runs the actual preview composition, then asks Cocoa
/// to use the same quit/close path as its own menu/window. No global key events,
/// clipboard, other apps or operating-system permission settings are touched.
Future<void> main() async {
  await preview.main();
  final binding = WidgetsBinding.instance;
  for (var frame = 0; frame < 120; frame++) {
    await binding.endOfFrame;
    await Future<void>.delayed(Duration.zero);
    if (!binding.hasScheduledFrame) break;
  }
  final state = await MacPreviewDesktop.channel
      .invokeMapMethod<String, Object?>('initialize');
  final action = Platform.environment['ZHIYU_PREVIEW_SMOKE_ACTION'];
  if (!const ['quit', 'close'].contains(action)) {
    throw StateError('Explicit preview lifecycle action required');
  }
  // ignore: avoid_print
  print(
    'ZHIYU_LIFECYCLE=${jsonEncode({'action': action, 'native': state, 'renderedFramesSettled': !binding.hasScheduledFrame})}',
  );
  await MacPreviewDesktop.channel.invokeMethod<void>(action!);
}
