// Standalone private-transport check. Only owned fixtures and synthetic values.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';

import 'package:info_desktop/windows_native_background_fill.dart';

var _checks = 0, _failures = 0;
void check(String family, String name, bool pass, [String? code]) {
  _checks++;
  if (!pass) _failures++;
  stdout.writeln(
    jsonEncode({
      'framework': family,
      'case': name,
      'pass': pass,
      'errorCode': ?code,
    }),
  );
}

class Fixture {
  Fixture._(this.process, this.lines, this.errors);
  final Process process;
  final StreamIterator<String> lines;
  final StreamSubscription<List<int>> errors;

  static Future<Fixture> start(String executable, List<String> args) async {
    final process = await Process.start(executable, args);
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final errors = process.stderr.listen((_) {});
    final fixture = Fixture._(process, lines, errors);
    if (!await lines.moveNext().timeout(const Duration(seconds: 8)) ||
        !lines.current.startsWith('ready ')) {
      await fixture.stop();
      throw const CredentialUseFailure('service_unavailable');
    }
    return fixture;
  }

  Future<String> command(String command) async {
    process.stdin.writeln(command);
    await process.stdin.flush();
    if (!await lines.moveNext().timeout(const Duration(seconds: 8))) {
      throw const CredentialUseFailure('service_unavailable');
    }
    return lines.current;
  }

  Future<void> expect(Uint8List bytes) async {
    final units = utf8.decode(bytes).codeUnits;
    await command(
      'expect ${units.map((u) => u.toRadixString(16).padLeft(4, '0')).join()}',
    );
  }

  Future<bool> setterEntered() async =>
      await lines.moveNext().timeout(const Duration(seconds: 8)) &&
      lines.current == 'setter_entered';

  Future<void> stop() async {
    try {
      process.stdin.writeln('close');
      await process.stdin.close();
      await process.exitCode.timeout(const Duration(seconds: 4));
    } on Object {
      process.kill();
    }
    await lines.cancel();
    await errors.cancel();
  }
}

Uint8List secret() {
  final random = Random.secure();
  final randomPart = List.generate(
    24,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  return Uint8List.fromList(utf8.encode(' $randomPart中🙂e\u0301%"\\ '));
}

Future<FocusedFillApplication> identity(String path) async {
  final file = File(await File(path).resolveSymbolicLinks());
  return FocusedFillApplication.fromJson({
    'executable': file.path,
    'sha256': (await sha256.bind(file.openRead()).first).toString(),
  });
}

Future<String?> refusal(Future<Object?> Function() action) async {
  try {
    await action();
    return null;
  } on CredentialUseFailure catch (failure) {
    return failure.code;
  } on Object {
    return 'sanitized_test_failure';
  }
}

NativeFillTarget firstField(List<NativeFillTarget> targets) =>
    targets.singleWhere((target) => target.fieldLabel.startsWith('[101]'));

Future<void> suite(
  String family,
  FocusedFillApplication helper,
  String executable,
  List<String> args,
) async {
  final scope = 'a'.padRight(64, 'a'), otherScope = 'b'.padRight(64, 'b');
  final driver = WindowsNativeFillDriver(helper: helper);
  final fixture = await Fixture.start(executable, args);
  final bytes = secret();
  var stage = 'discover';
  try {
    var found = await driver.discover(scope: scope, appId: executable);
    check(family, 'discover_native_fields', found.length == 2);
    var target = firstField(found);
    check(
      family,
      'field_metadata_distinguishes_controls',
      found.map((t) => t.fieldLabel).toSet().length == found.length,
    );
    final again = await driver.discover(scope: scope, appId: executable);
    check(
      family,
      'rediscovery_keeps_live_reference_ids',
      found
              .map((t) => t.targetId)
              .toSet()
              .containsAll(again.map((t) => t.targetId)) &&
          found.length == again.length,
    );
    final foreign = await refusal(
      () => driver.prepare(scope: otherScope, targetId: target.targetId),
    );
    check(
      family,
      'cross_scope_reference_refused',
      foreign == 'scope_not_approved',
      foreign,
    );
    final initial = await driver.prepare(
      scope: scope,
      targetId: target.targetId,
    );
    final busy = await refusal(
      () => driver.prepare(scope: scope, targetId: target.targetId),
    );
    check(family, 'same_control_busy', busy == 'busy', busy);
    stage = 'initial_close';
    await initial.close();
    await initial.close();
    stage = 'fixture_expected';
    await fixture.expect(bytes);
    stage = 'fixture_seed';
    await fixture.command('seed');
    stage = 'prepare_expected';
    var prepared = await driver.prepare(
      scope: scope,
      targetId: target.targetId,
      expected: target,
    );
    var callbacks = 0;
    stage = 'value_submit';
    final sent = await prepared.setValue(
      bytes,
      beforeDispatch: () async {
        callbacks++;
      },
    );
    var oracle = await fixture.command('verify');
    check(
      family,
      'adapter_unicode_whole_value',
      sent.state == NativeFillState.sent &&
          oracle.contains('match=1') &&
          oracle.contains('others=1') &&
          callbacks == 1,
      sent.errorCode,
    );
    final duplicate = await prepared.setValue(
      bytes,
      beforeDispatch: () async {
        callbacks++;
      },
    );
    check(
      family,
      'adapter_ticket_not_replayed',
      duplicate.state == sent.state &&
          callbacks == 1 &&
          await fixture.command('verify') == oracle,
    );
    await prepared.close();
    await prepared.close();
    await fixture.command('reset');
    await fixture.expect(bytes);
    prepared = await driver.prepare(
      scope: scope,
      targetId: target.targetId,
      expected: target,
    );
    final focused = await prepared.setValue(
      bytes,
      beforeDispatch: () async {
        await fixture.command('focusB');
      },
    );
    oracle = await fixture.command('verify');
    check(
      family,
      'adapter_callback_focus_B_still_writes_A',
      focused.state == NativeFillState.sent &&
          oracle.contains('match=1') &&
          oracle.contains('others=1'),
      focused.errorCode,
    );
    await fixture.command('reset');
    prepared = await driver.prepare(
      scope: scope,
      targetId: target.targetId,
      expected: target,
    );
    final canceled = await prepared.setValue(
      bytes,
      beforeDispatch: () async {
        throw const CredentialUseFailure('grant_revoked');
      },
    );
    check(
      family,
      'callback_refusal_sends_no_value',
      canceled.state == NativeFillState.refused &&
          canceled.errorCode == 'grant_revoked' &&
          (await fixture.command('verify')).contains('empty=1'),
    );
    prepared = await driver.prepare(
      scope: scope,
      targetId: target.targetId,
      expected: target,
    );
    final disabled = await prepared.setValue(
      bytes,
      beforeDispatch: () async {
        await fixture.command('disable');
      },
    );
    check(
      family,
      'native_rechecks_after_grant_callback',
      disabled.state == NativeFillState.refused &&
          (await fixture.command('verify')).contains('empty=1'),
      disabled.errorCode,
    );
    await fixture.command('enable');
    final retired = await refusal(
      () => driver.prepare(
        scope: scope,
        targetId: target.targetId,
        expected: target,
      ),
    );
    check(
      family,
      'invalidated_old_target_not_restored',
      retired != null,
      retired,
    );
    found = await driver.discover(scope: scope, appId: executable);
    target = firstField(found);
    await fixture.command('reset');
    await fixture.expect(bytes);
    prepared = await driver.prepare(
      scope: scope,
      targetId: target.targetId,
      expected: target,
    );
    final rebuilt = await prepared.setValue(
      bytes,
      beforeDispatch: () async {
        await fixture.command('recreate');
      },
    );
    check(
      family,
      'recreated_object_refused_after_callback',
      rebuilt.state == NativeFillState.refused &&
          (await fixture.command('verify')).contains('empty=1'),
      rebuilt.errorCode,
    );
    found = await driver.discover(scope: scope, appId: executable);
    target = firstField(found);
    await fixture.command('reset');
    await fixture.expect(bytes);
    prepared = await driver.prepare(
      scope: scope,
      targetId: target.targetId,
      expected: target,
    );
    final unknown = await prepared.setValue(
      bytes,
      beforeDispatch: () async {
        await fixture.command('disable-after-set');
      },
    );
    oracle = await fixture.command('verify');
    check(
      family,
      'setter_started_then_changed_is_unknown',
      unknown.state == NativeFillState.unknown &&
          unknown.errorCode == 'fill_unknown' &&
          oracle.contains('match=1'),
    );
    final sameUnknown = await prepared.setValue(
      bytes,
      beforeDispatch: () async {
        callbacks++;
      },
    );
    check(
      family,
      'unknown_ticket_not_replayed',
      sameUnknown.state == NativeFillState.unknown &&
          await fixture.command('verify') == oracle,
    );
    await fixture.command('reset');
    found = await driver.discover(scope: scope, appId: executable);
    target = firstField(found);
    final others = await driver.discover(scope: otherScope, appId: executable);
    final other = firstField(others);
    final held = await driver.prepare(
      scope: scope,
      targetId: target.targetId,
      expected: target,
    );
    final physicalBusy = await refusal(
      () => driver.prepare(
        scope: otherScope,
        targetId: other.targetId,
        expected: other,
      ),
    );
    check(
      family,
      'concrete_control_busy_across_scopes',
      physicalBusy == 'busy',
      physicalBusy,
    );
    await held.close();
    final otherPrepared = await driver.prepare(
      scope: otherScope,
      targetId: other.targetId,
      expected: other,
    );
    await driver.release(scope: scope, targetId: target.targetId);
    await driver.release(scope: scope, targetId: target.targetId);
    await fixture.expect(bytes);
    final otherSent = await otherPrepared.setValue(
      bytes,
      beforeDispatch: () async {},
    );
    check(
      family,
      'release_one_scope_preserves_other_scope',
      otherSent.state == NativeFillState.sent &&
          (await fixture.command('verify')).contains('match=1'),
      otherSent.errorCode,
    );
    final released = await refusal(
      () => driver.prepare(
        scope: scope,
        targetId: target.targetId,
        expected: target,
      ),
    );
    check(
      family,
      'released_reference_cannot_prepare',
      released == 'target_unavailable',
      released,
    );
    final decoy = await Fixture.start(executable, args);
    try {
      final ambiguous = await refusal(
        () => driver.discover(scope: scope, appId: executable),
      );
      check(
        family,
        'indistinguishable_same_title_windows_refused',
        ambiguous == 'unsupported_target',
        ambiguous,
      );
      if (family == 'Win32') {
        final prefix = List.filled(256, 'x').join();
        await fixture.command('title ${prefix}A');
        await decoy.command('title ${prefix}B');
        final truncated = await refusal(
          () => driver.discover(scope: scope, appId: executable),
        );
        check(
          family,
          'truncated_public_titles_stay_ambiguous',
          truncated == 'unsupported_target',
          truncated,
        );
        await fixture.command('title Synthetic\twindow');
        await decoy.command('title Synthetic window');
        final normalized = await refusal(
          () => driver.discover(scope: scope, appId: executable),
        );
        check(
          family,
          'normalized_public_titles_stay_ambiguous',
          normalized == 'unsupported_target',
          normalized,
        );
      }
    } finally {
      await decoy.stop();
    }
    await fixture.command('reset');
    found = await driver.discover(scope: scope, appId: executable);
    target = firstField(found);
    await fixture.command('retitle');
    final staleWindow = await refusal(
      () => driver.discover(
        scope: scope,
        appId: executable,
        windowId: target.windowId,
      ),
    );
    check(
      family,
      'invalidated_window_reference_cannot_rediscover',
      staleWindow == 'target_unavailable',
      staleWindow,
    );
    found = await driver.discover(scope: scope, appId: executable);
    target = firstField(found);
    prepared = await driver.prepare(
      scope: scope,
      targetId: target.targetId,
      expected: target,
    );
    final invalid = await prepared.setValue(
      [0xff],
      beforeDispatch: () async {
        callbacks++;
      },
    );
    check(
      family,
      'malformed_utf8_is_refused',
      invalid.state == NativeFillState.refused &&
          invalid.errorCode == 'unsupported_secret' &&
          (await fixture.command('verify')).contains('empty=1'),
    );
    await prepared.close();
    if (family == 'Win32') {
      prepared = await driver.prepare(
        scope: scope,
        targetId: target.targetId,
        expected: target,
      );
      await fixture.expect(bytes);
      final armed = Completer<void>();
      final pending = prepared.setValue(
        bytes,
        beforeDispatch: () async {
          await fixture.command('delay-next-set');
          armed.complete();
        },
      );
      await armed.future.timeout(const Duration(seconds: 8));
      final entered = await fixture.setterEntered();
      final elapsed = Stopwatch()..start();
      await driver.dispose();
      final interrupted = await pending.timeout(const Duration(seconds: 3));
      check(
        family,
        'dispose_does_not_wait_for_setter_reply',
        entered && elapsed.elapsed < const Duration(seconds: 3),
      );
      check(
        family,
        'lost_setter_reply_is_unknown',
        interrupted.state == NativeFillState.unknown &&
            interrupted.errorCode == 'fill_unknown',
      );
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      final observed = await fixture.command('verify');
      final again = await prepared.setValue(
        bytes,
        beforeDispatch: () async {
          callbacks++;
        },
      );
      check(
        family,
        'lost_reply_not_replayed',
        again.state == NativeFillState.unknown &&
            await fixture.command('verify') == observed,
      );
    }
    final oldInstance = target.helperInstanceId;
    await driver.dispose();
    await driver.dispose();
    final fresh = WindowsNativeFillDriver(helper: helper);
    try {
      final newFound = await fresh.discover(scope: scope, appId: executable);
      check(
        family,
        'helper_restart_changes_incarnation',
        newFound.isNotEmpty &&
            newFound.every((t) => t.helperInstanceId != oldInstance),
      );
      final old = await refusal(
        () => fresh.prepare(
          scope: scope,
          targetId: target.targetId,
          expected: target,
        ),
      );
      check(
        family,
        'old_snapshot_not_recreated_after_restart',
        old == 'target_unavailable',
        old,
      );
    } finally {
      await fresh.dispose();
    }
  } on CredentialUseFailure catch (failure) {
    check(family, 'suite_exception', false, failure.code);
  } on Object catch (error, trace) {
    check(family, 'suite_exception', false, 'sanitized_${error.runtimeType}');
    stdout.writeln(
      jsonEncode({
        'case': 'safe_test_location',
        'stage': stage,
        'frames': trace.toString().split('\n').take(4).toList(),
      }),
    );
  } finally {
    bytes.fillRange(0, bytes.length, 0);
    await driver.dispose();
    await fixture.stop();
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 3 && args.length != 4) {
    exitCode = 64;
    return;
  }
  final helper = await identity(args[0]);
  final native = File(args[1]).absolute.path;
  final managed = File(args[2]).absolute.path;
  if (args.length == 3 || args[3] == 'Win32') {
    await suite('Win32', helper, native, const []);
  }
  if (args.length == 3 || args[3] == 'WinForms') {
    await suite('WinForms', helper, managed, const ['forms']);
  }
  if (args.length == 3 || args[3] == 'WPF') {
    await suite('WPF', helper, managed, const ['wpf']);
  }
  stdout.writeln(
    jsonEncode({'case': 'summary', 'checks': _checks, 'failures': _failures}),
  );
  exitCode = _failures == 0 ? 0 : 1;
}
