import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'browser_fill_types.dart';
import 'browser_form_script.dart';
export 'browser_fill_types.dart';

/// Uses an installed Ego helper, an existing owned TaskSpace and its Page.
/// Does not create/claim spaces, navigate pages or change browser configuration.
/// Helper source (including material) travels exclusively over private stdin.
class EgoBrowserFill {
  EgoBrowserFill(this.executable, {this.timeout = const Duration(seconds: 10)});
  final String executable;
  final Duration timeout;
  static const _maxReply = 1024 * 1024;

  Future<BrowserFormInspection> inspect({
    required int space,
    required String page,
    required String url,
    required String form,
    required String field,
  }) async {
    // Validate without calling Ego or accepting arbitrary code as a locator.
    final selected = BrowserFormTarget.fromJson({
      'provider': 'ego',
      'space': space,
      'pageId': page,
      'url': url,
      'form': form,
      'field': field,
      'instanceId': 'unobserved',
      'structureDigest': '0' * 64,
    });
    final receipt = await _run(selected);
    final structure = receipt['structure'];
    final instance = receipt['instanceId'];
    if (receipt['status'] != 'ready' ||
        structure is! Map<String, dynamic> ||
        instance is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(instance)) {
      throw BrowserFillFailure(browserReceiptCode(receipt));
    }
    return BrowserFormInspection(
      BrowserFormTarget.fromJson({
        ...selected.toJson(),
        'instanceId': instance,
        'structureDigest': sha256
            .convert(utf8.encode(jsonEncode(structure)))
            .toString(),
      }),
      structure,
    );
  }

  Future<Map<String, Object?>> fill(
    BrowserFormTarget approved,
    String password,
  ) async {
    if (approved.provider != 'ego') {
      return const {'status': 'refused', 'code': 'destination_changed'};
    }
    final bytes = utf8.encode(password);
    if (bytes.isEmpty ||
        bytes.length > 65536 ||
        password.contains(RegExp(r'[\r\n\x00]'))) {
      return const {'status': 'refused', 'code': 'unsupported_password_value'};
    }
    try {
      final receipt = await _run(approved, password);
      final status = receipt['status'];
      if (!{'filled', 'refused', 'unknown'}.contains(status)) {
        return const {'status': 'unknown', 'code': 'browser_response_invalid'};
      }
      return {
        'status': status,
        if (receipt['code'] != null) 'code': browserReceiptCode(receipt),
      };
    } on BrowserFillFailure catch (error) {
      // Process.start failure proves nothing was dispatched; all subsequent
      // transport failures conservatively preserve an unknown execution.
      return {
        'status': error.code == 'browser_not_started' ? 'refused' : 'unknown',
        'code': error.code == 'browser_not_started'
            ? 'browser_unavailable'
            : error.code,
      };
    }
  }

  Future<Map<String, dynamic>> _run(
    BrowserFormTarget target, [
    String? password,
  ]) async {
    final nonce = base64Url.encode(
      List.generate(24, (_) => Random.secure().nextInt(256)),
    );
    final prefix = 'chiyo-$nonce:';
    final source = _script(target, password, prefix);
    late Process process;
    try {
      process = await Process.start(executable, ['nodejs']);
    } on Object {
      throw const BrowserFillFailure('browser_not_started');
    }
    final output = <int>[];
    final diagnostics = <int>[];
    var excessive = false;
    var count = 0;
    void consume(List<int> chunk, List<int> buffer) {
      count += chunk.length;
      if (count > _maxReply) {
        excessive = true;
        process.kill();
      } else {
        buffer.addAll(chunk);
      }
    }

    final out = process.stdout.listen((chunk) => consume(chunk, output));
    // Ego currently routes console.log to stderr. Both channels are bounded
    // and filtered; neither raw diagnostic stream is forwarded to the caller.
    final err = process.stderr.listen((chunk) => consume(chunk, diagnostics));
    final drained = Future.wait([out.asFuture<void>(), err.asFuture<void>()]);
    try {
      await (() async {
        process.stdin.add(utf8.encode(source));
        await process.stdin.close();
        final code = await process.exitCode;
        await drained;
        if (excessive || code != 0) {
          throw const BrowserFillFailure('browser_response_invalid');
        }
      })().timeout(timeout);
      final lines = [
        ...const LineSplitter().convert(utf8.decode(output)),
        ...const LineSplitter().convert(utf8.decode(diagnostics)),
      ];
      final receipts = lines.where((line) => line.startsWith(prefix)).toList();
      if (receipts.length != 1) {
        throw const BrowserFillFailure('browser_response_invalid');
      }
      final value = jsonDecode(receipts.single.substring(prefix.length));
      if (value is! Map<String, dynamic>) {
        throw const BrowserFillFailure('browser_response_invalid');
      }
      return value;
    } on BrowserFillFailure {
      rethrow;
    } on TimeoutException {
      throw const BrowserFillFailure('browser_timeout');
    } on Object {
      throw const BrowserFillFailure('browser_unavailable');
    } finally {
      // Terminating the helper does not undo a potentially dispatched write.
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 1));
      } on Object {
        // An unconfirmed helper termination still cannot establish no write.
      }
      await out.cancel();
      await err.cancel();
    }
  }
}

String _script(BrowserFormTarget target, String? password, String prefix) {
  final inspect = browserFormExpression(
    url: target.url,
    form: target.formSelector,
    field: target.fieldSelector,
  );
  final write = browserFormExpression(
    url: target.url,
    form: target.formSelector,
    field: target.fieldSelector,
    password: password,
  );
  return '''
const config = ${jsonEncode({'space': target.space, 'page': target.pageId, 'url': target.url, 'instance': password == null ? null : target.instanceId, 'digest': password == null ? null : target.structureDigest})};
const prefix = ${jsonEncode(prefix)};
let dispatched = false;
let receipt;
try {
  const {createHash, randomUUID} = await import('node:crypto');
  const hash = value => createHash('sha256').update(JSON.stringify(value),'utf8').digest('hex');
  const task = await taskSpace(config.space);
  const page = task.page(config.page);
  await page.cdp('Runtime.enable');
  const frame = (await page.cdp('Page.getFrameTree')).frameTree.frame;
  const instance = hash({space:config.space, frame:frame.id});
  if (frame.url !== config.url || (config.instance !== null && instance !== config.instance)) {
    receipt = {status:'refused',code:'destination_changed'};
  } else {
    // Correlate the isolated world with its system-unique context ID. Numeric
    // context IDs can be reused after navigation; never fall back to them.
    const worldName = 'chiyo-fill-'+randomUUID();
    const world = await page.cdp('Page.createIsolatedWorld',{frameId:frame.id,worldName});
    const contexts = (await page.events()).filter(e => e.method==='Runtime.executionContextCreated')
      .map(e => e.params.context).filter(c => c.id===world.executionContextId && c.name===worldName && c.auxData?.frameId===frame.id);
    if (contexts.length !== 1 || typeof contexts[0].uniqueId !== 'string' || !contexts[0].uniqueId) {
      receipt = {status:'refused',code:'unavailable_target'};
    } else {
      const uniqueContextId = contexts[0].uniqueId;
      const evaluate = async expression => {
        const result = await page.cdp('Runtime.evaluate',{expression,uniqueContextId,returnByValue:true,awaitPromise:false,silent:true});
        if (result.exceptionDetails || result.result?.value?.status === undefined) throw new Error('invalid');
        return result.result.value;
      };
      const checked = await evaluate(${jsonEncode(inspect)});
      if (checked.status !== 'ready') receipt = checked;
      else if (config.digest === null) receipt = {status:'ready',instanceId:instance,structure:checked.structure};
      else if (hash(checked.structure) !== config.digest) receipt = {status:'refused',code:'form_changed'};
      else {
        const write = ${jsonEncode(write)};
        // Supply the structure checked in this invocation, then execute in the
        // very same document context. A navigation invalidates it rather than
        // evaluating in whichever document a mutable Page label now resolves.
        const expression = write.replace(${jsonEncode('"expectedStructure":null')}, '"expectedStructure":'+JSON.stringify(checked.structure));
        dispatched = true;
        receipt = await evaluate(expression);
      }
    }
  }
} catch {
  receipt = {status:dispatched?'unknown':'refused',code:'browser_operation_failed'};
}
console.log(prefix+JSON.stringify(receipt));
''';
}
