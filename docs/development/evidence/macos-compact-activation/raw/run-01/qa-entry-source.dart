// Isolated synthetic UI diagnosis. Ordinary binding and production UI; all
// pointer/key actions come from CUA. The owned control file can move only the
// document scroll position as an explicit automated-test fallback. It cannot
// approve, select fields, inject text or change production application state.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/information_file_summary.dart';
import 'package:info_desktop/main.dart';
import '../test/support/information_attachment_fixture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final f = await AttachmentUiFixture.create();
  final session = f.service.agent.openSession('Mac 小窗口审批可达性独立复现 20261023');
  final request = f.service.agent.request(session, '仅合成资料的窄窗口诊断', [
    FieldRef(f.item.id, f.item.fields.first.id),
    FieldRef(f.item.id, f.item.fields.last.id),
  ]);
  var errors = 0;
  FlutterError.onError = (details) {
    errors++;
    FlutterError.presentError(details);
  };
  void report(String kind, Object? facts) => stdout.writeln(
    'COMPACT_QA=${jsonEncode({'kind': kind, 'facts': facts})}',
  );
  Timer? timer;
  final bootstrap = DesktopBootstrap(
    port: 0,
    platform: NativeDesktopPlatform(),
    openLibrary: () async => DesktopLibrary(
      service: f.service,
      close: () async {
        timer?.cancel();
        report('closed', {'flutterErrors': errors});
        await f.close();
      },
    ),
  );
  await bootstrap.start();
  if (bootstrap.state != DesktopStartupState.ready) {
    throw StateError('Synthetic bootstrap failed');
  }
  const native = MethodChannel('agent_info_manage/desktop');
  await native.invokeMethod<void>('qaSetCompactWindow');
  var pointerSignals = 0, pointerDowns = 0, keys = 0;
  bool observeKey(KeyEvent event) {
    keys++;
    report('key', {
      'type': event.runtimeType.toString(),
      'logical': event.logicalKey.debugName,
    });
    return false;
  }

  HardwareKeyboard.instance.addHandler(observeKey);
  runApp(
    Listener(
      onPointerSignal: (event) {
        pointerSignals++;
        report('pointerSignal', {
          'x': event.position.dx,
          'y': event.position.dy,
          if (event is PointerScrollEvent) 'dy': event.scrollDelta.dy,
        });
      },
      onPointerDown: (event) {
        pointerDowns++;
        report('pointerDown', {'x': event.position.dx, 'y': event.position.dy});
      },
      child: DesktopLauncher(bootstrap: bootstrap),
    ),
  );
  var last = '';
  final control = File('${f.root.path}/compact-control.json');
  timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
    final scrolls = <Map<String, Object?>>[];
    final approvals = <bool>[];
    var summaries = 0;
    ScrollPosition? documentPosition;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is InformationFileSummary) summaries++;
      if (widget.key == const ValueKey('approve-selection')) {
        approvals.add(widget is FilledButton && widget.onPressed != null);
      }
      if (element is StatefulElement && element.state is ScrollableState) {
        var document = false;
        element.visitAncestorElements((ancestor) {
          if (ancestor.widget.key == PageStorageKey('detail-${request.id}')) {
            document = true;
          }
          return !document;
        });
        if (document) {
          final p = (element.state as ScrollableState).position;
          documentPosition = p;
          final box = element.findRenderObject();
          scrolls.add({
            'pixels': p.pixels,
            'max': p.maxScrollExtent,
            'viewport': p.viewportDimension,
            if (box is RenderBox) ...{
              'left': box.localToGlobal(Offset.zero).dx,
              'top': box.localToGlobal(Offset.zero).dy,
              'width': box.size.width,
              'height': box.size.height,
            },
          });
        }
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    if (control.existsSync()) {
      final input = jsonDecode(control.readAsStringSync());
      control.deleteSync();
      if (input is! Map ||
          input.length != 1 ||
          input['scrollDocumentTo'] is! num ||
          !(input['scrollDocumentTo'] as num).isFinite ||
          documentPosition == null) {
        throw StateError('Invalid owned scroll-only test command');
      }
      final p = documentPosition!;
      final offset = (input['scrollDocumentTo'] as num).toDouble();
      if (offset < 0 || offset > p.maxScrollExtent) {
        throw StateError('Test scroll is outside document bounds');
      }
      report('automatedScroll', {'from': p.pixels, 'to': offset});
      p.jumpTo(offset);
    }
    final state = {
      'pointerSignals': pointerSignals,
      'pointerDowns': pointerDowns,
      'keys': keys,
      'documentScrolls': scrolls,
      'fileSummariesBuilt': summaries,
      'approveEnabled': approvals,
      'flutterErrors': errors,
      'semanticsEnabled': SemanticsBinding.instance.semanticsEnabled,
      'requestStatus': f.service.agent.status(session, request.id)['status'],
    };
    final encoded = jsonEncode(state);
    if (encoded != last) {
      last = encoded;
      report('state', state);
    }
  });
  report('ready', {
    'port': bootstrap.boundPort,
    'fixtureRoot': f.root.path,
    'systemKeychainUsed': false,
  });
}
