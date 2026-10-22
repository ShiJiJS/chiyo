// Ordinary Flutter/production UI, driven only through CUA. Observations are
// passive; no tester binding, text injection, focus requests or UI callbacks.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/information_editor.dart';
import 'package:info_desktop/main.dart';

// Only the optional diagnosis wraps the messenger. The original handler,
// payload, reply and ordering are preserved; no platform input is injected.
class _KeyDiagnosticBinding extends WidgetsFlutterBinding {
  @override
  BinaryMessenger createBinaryMessenger() =>
      _KeyDiagnosticMessenger(super.createBinaryMessenger());
}

class _KeyDiagnosticMessenger extends BinaryMessenger {
  const _KeyDiagnosticMessenger(this.delegate);
  final BinaryMessenger delegate;

  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    ui.PlatformMessageResponseCallback? callback,
  ) async {
    ui.channelBuffers.push(channel, data, (reply) => callback?.call(reply));
  }

  @override
  Future<ByteData?>? send(String channel, ByteData? message) =>
      delegate.send(channel, message);

  @override
  void setMessageHandler(String channel, MessageHandler? handler) {
    if (channel != 'flutter/textinput' || handler == null) {
      delegate.setMessageHandler(channel, handler);
      return;
    }
    delegate.setMessageHandler(channel, (message) {
      if (message != null) {
        try {
          final call = const JSONMethodCodec().decodeMethodCall(message);
          final record = <String, Object?>{'method': call.method};
          // Do not log text values, client IDs or other channel arguments.
          if (call.method == 'TextInputClient.performSelectors') {
            record['selectors'] = (call.arguments as List)[1];
          }
          stdout.writeln('EDITOR_FOCUS_TEXT_INPUT=${jsonEncode(record)}');
        } catch (_) {
          stdout.writeln('EDITOR_FOCUS_TEXT_INPUT_DECODE_FAILED');
        }
      }
      return handler(message);
    });
  }
}

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.filled(32, 158);
  @override
  Future<void> create(List<int> key) async => throw StateError('QA key exists');
}

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final env = Platform.environment, mode = env['MAC_FOCUS_MODE']!;
  final diagnoseKeys = env['MAC_FOCUS_DIAGNOSE_KEYS'] == '1';
  if (diagnoseKeys) {
    _KeyDiagnosticBinding();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }
  final owner = env['MAC_FOCUS_OWNER']!;
  check({'edit', 'reopen'}.contains(mode), 'QA mode');
  check(RegExp(r'^[a-f0-9]{32}$').hasMatch(owner), 'QA owner');
  final root = env['MAC_FOCUS_ROOT'] == null
      ? await Directory.systemTemp.createTemp('aim-editor-focus-')
      : Directory(env['MAC_FOCUS_ROOT']!);
  final canonical = await root.resolveSymbolicLinks();
  check(
    canonical.startsWith(
      '${await Directory.systemTemp.resolveSymbolicLinks()}/aim-editor-focus-',
    ),
    'Owned root',
  );
  final marker = File('$canonical/.qa-owner');
  if (mode == 'edit') await marker.writeAsString(owner);
  check(await marker.readAsString() == owner, 'Foreign root');
  stdout.writeln('EDITOR_FOCUS_ROOT=$canonical');
  final report = File('$canonical/$mode.json');
  final facts = <String, Object?>{
    'mode': mode,
    'complete': false,
    'systemKeychainUsed': false,
  };
  final observations = <Map<String, Object?>>[];
  Timer? timer;
  var closes = 0, flutterErrors = 0;
  void write() {
    facts.addAll({'libraryCloses': closes, 'flutterErrors': flutterErrors});
    final temp = File('${report.path}.writing');
    temp.writeAsStringSync(jsonEncode(facts), flush: true);
    temp.renameSync(report.path);
  }

  final hardwareKeys = <Map<String, Object?>>[];
  bool observeHardwareKey(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    hardwareKeys.add({
      'event': event.runtimeType.toString(),
      'physical': event.physicalKey.usbHidUsage,
      'logical': event.logicalKey.keyId,
      'logicalName': event.logicalKey.debugName,
      'synthesized': event.synthesized,
      'shift': keyboard.isShiftPressed,
      'control': keyboard.isControlPressed,
      'alt': keyboard.isAltPressed,
      'meta': keyboard.isMetaPressed,
    });
    facts['hardwareKeys'] = hardwareKeys;
    write();
    return false;
  }

  if (diagnoseKeys) {
    HardwareKeyboard.instance.addHandler(observeHardwareKey);
  }

  FlutterError.onError = (details) {
    flutterErrors++;
    FlutterError.presentError(details);
  };
  late EncryptedInformationRepository repository;
  final bootstrap = DesktopBootstrap(
    port: 0,
    platform: NativeDesktopPlatform(),
    openLibrary: () async {
      repository = await EncryptedInformationRepository.open(
        '$canonical/library',
        _Keys(),
      );
      final service = InformationService(repository: repository);
      if (mode == 'edit') {
        final source = File('$canonical/合成附件.txt');
        await source.writeAsBytes([0, 255, 1, 2, 10, 42, 7]);
        final draft = await service.owner.beginInformationFileDraft();
        final stage = await service.owner.stageInformationFile(
          draft,
          source.path,
        );
        await service.owner.commitInformationDraft(
          draft,
          'seed-only',
          InformationDraftInput(
            name: 'Mac 焦点合成资料',
            description: 'BaselineDescription',
            fields: [
              const InformationDraftField.text('合成字段', '', 'BaselineValue'),
              InformationDraftField.stagedFile('合成附件', '', stage.id),
            ],
          ),
        );
        await service.owner.releaseInformationFileDraft(draft);
      }
      return DesktopLibrary(
        service: service,
        backups: repository.backups,
        close: () async {
          timer?.cancel();
          if (diagnoseKeys) {
            HardwareKeyboard.instance.removeHandler(observeHardwareKey);
          }
          await repository.close();
          closes++;
          write();
        },
      );
    },
  );
  try {
    await bootstrap.start();
    check(bootstrap.state == DesktopStartupState.ready, 'Bootstrap failed');
    final service = bootstrap.library!.service;
    facts['port'] = bootstrap.boundPort;
    const channel = MethodChannel('agent_info_manage/desktop');
    facts['inputSourceAtStart'] = await channel.invokeMethod<String>(
      'qaReadInputSource',
    );
    runApp(DesktopLauncher(bootstrap: bootstrap));
    var last = '';
    void observe() {
      InformationEditor? editor;
      final controls = <String, bool>{};
      var confirmation = false;
      void visit(Element element) {
        final widget = element.widget;
        if (widget is InformationEditor) editor = widget;
        if (widget is Text && widget.data == '放弃未保存的更改？') confirmation = true;
        final key = widget.key;
        if (key is ValueKey<String>) {
          if (widget is TextFormField) {
            controls[key.value] = widget.enabled;
          }
          if (widget is TextButton) {
            controls[key.value] = widget.onPressed != null;
          }
        }
        element.visitChildren(visit);
      }

      WidgetsBinding.instance.rootElement?.visitChildren(visit);
      final focus = FocusManager.instance.primaryFocus;
      final focusKeys = <String>[];
      focus?.context?.visitAncestorElements((element) {
        final key = element.widget.key;
        if (key is ValueKey<String>) focusKeys.add(key.value);
        return true;
      });
      final editable = focus?.context
          ?.findAncestorStateOfType<EditableTextState>();
      final value = editable?.widget.controller.value;
      final draft = editor?.draft;
      final snapshot = <String, Object?>{
        'focusIdentity': focus == null ? null : identityHashCode(focus),
        'focusKeys': focusKeys,
        if (value != null)
          'editingValue': {
            'text': value.text,
            'selection': [value.selection.start, value.selection.end],
            'composing': [value.composing.start, value.composing.end],
          },
        'confirmation': confirmation,
        'controlsEnabled': controls,
        'editor': draft == null
            ? null
            : {
                'description': draft.description,
                'name': draft.name,
                'fileStages': draft.fields.where((f) => f.stage != null).length,
              },
        'persistedDescription': service.owner.information.single.description,
      };
      final encoded = jsonEncode(snapshot);
      if (encoded != last) {
        last = encoded;
        snapshot['sequence'] = observations.length;
        observations.add(snapshot);
        facts['observations'] = observations;
        facts['latest'] = snapshot;
        write();
      }
    }

    if (mode == 'edit') {
      timer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => observe(),
      );
      final deadline = DateTime.now().add(const Duration(minutes: 40));
      stdout.writeln(
        'EDITOR_FOCUS_PHASE=actual-ui-edit-cancel-keyboard-and-save',
      );
      while (service.owner.information.single.description != 'MacFocusSaved') {
        check(DateTime.now().isBefore(deadline), 'Actual UI deadline');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      // The saved model is the actual UI result, not a tester/controller write.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      observe();
      timer.cancel();
      facts['actualUiSaved'] = true;
    } else {
      check(
        service.owner.information.single.description == 'MacFocusSaved',
        'Saved description did not persist',
      );
      facts['savedDescriptionPreserved'] = true;
    }
    final item = service.owner.information.single;
    check(
      item.name == 'Mac 焦点合成资料' &&
          item.fields.length == 2 &&
          item.fields.first.value == 'BaselineValue',
      'Other fields changed',
    );
    final bytes = await repository.readInformationAttachmentChunk(
      item.fields.last.attachment!,
      0,
      7,
    );
    check(
      listEquals(bytes, [0, 255, 1, 2, 10, 42, 7]),
      'Original attachment changed',
    );
    facts['otherFieldsAndAttachmentPreserved'] = true;
    facts['inputSourceAtEnd'] = await channel.invokeMethod<String>(
      'qaReadInputSource',
    );
    facts['complete'] = true;
    write();
    stdout.writeln('EDITOR_FOCUS_COMPLETE=$mode');
  } catch (error) {
    timer?.cancel();
    facts.addAll({'failed': true, 'error': error.toString()});
    write();
    stderr.writeln('EDITOR_FOCUS_FAILED=$error');
    await bootstrap.runtime?.stop();
    exit(1);
  }
}
