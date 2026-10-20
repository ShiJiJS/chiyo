import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// An isolated loopback consumer, not an upload feature of the product.
/// Only byte equality and public file facts leave this receiver; no payload log.
class NativeResumeUploadReceiver {
  NativeResumeUploadReceiver._(
    this._server,
    this._expected,
    this._expectedName,
  );
  final HttpServer _server;
  final List<int> _expected;
  final String _expectedName;
  final _received = Completer<Map<String, Object>>();
  String get url => 'http://127.0.0.1:${_server.port}';
  Future<Map<String, Object>> get received => _received.future;
  bool get completed => _received.isCompleted;

  static Future<NativeResumeUploadReceiver> start(
    List<int> expected,
    String fileName,
  ) async {
    final receiver = NativeResumeUploadReceiver._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      List.of(expected),
      fileName,
    );
    receiver._server.listen(receiver._handle);
    return receiver;
  }

  Future<void> _handle(HttpRequest request) async {
    request.response.headers.set('Cache-Control', 'no-store');
    if (request.method == 'GET' && request.uri.path == '/') {
      request.response.headers.contentType = ContentType.html;
      request.response.write(_page);
      await request.response.close();
      return;
    }
    if (request.method != 'POST' ||
        request.uri.path != '/upload' ||
        request.headers.value('origin') != url ||
        _received.isCompleted) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    var offset = 0, matches = true;
    await for (final chunk in request) {
      for (final byte in chunk) {
        if (offset >= _expected.length || _expected[offset] != byte) {
          matches = false;
        }
        offset++;
      }
      if (offset > 10 * 1024 * 1024) break;
    }
    matches = matches && offset == _expected.length;
    final facts = <String, Object>{
      'bytesMatched': matches,
      'byteLength': offset,
      'fileNameMatched':
          request.headers.value('x-test-file-name') == _expectedName,
      'sameOrigin': true,
    };
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(facts));
    await request.response.close();
    _received.complete(facts);
  }

  Future<void> close() => _server.close(force: true);
}

const _page = r'''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<title>普通附件 · 本机文件消费验证</title>
<style>body{font:16px/1.7 system-ui;background:#f3f1f4;color:#302a32;margin:48px}
main{max-width:800px;margin:auto;background:white;border:1px solid #ded6df;
padding:36px;border-radius:10px}h1{font-size:25px}label,input,button{display:block;
margin:16px 0}button{background:#805670;color:white;border:0;padding:12px 20px;
border-radius:5px;font:inherit}pre{white-space:pre-wrap;background:#f6f3f6;
padding:20px;border-radius:6px}#result{font-weight:bold}</style>
<main><h1>普通附件 · 本机文件消费验证</h1>
<p>选择由 CLI 领取的虚构简历，读取文字，再发送到同一个本机接收器核对原字节。</p>
<form id="form"><label for="resume">选择已获准的简历文件</label>
<input id="resume" type="file" accept=".txt,text/plain" required>
<p id="file-facts">尚未选择文件</p><pre id="preview">尚未读取文件内容</pre>
<button type="submit">发送到本机接收器并核对</button></form>
<p id="result" role="status">等待选择文件</p></main>
<script>
const input=document.getElementById('resume');
input.addEventListener('change',async()=>{
 const f=input.files[0]; if(!f)return;
 document.getElementById('file-facts').textContent=f.name+' · '+f.size+' bytes';
 document.getElementById('preview').textContent=await f.text();
 document.getElementById('result').textContent='已从所选文件读取文字，等待核对';
});
document.getElementById('form').addEventListener('submit',async e=>{
 e.preventDefault();const f=input.files[0];if(!f)return;
 const response=await fetch('/upload',{method:'POST',
 headers:{'Content-Type':'application/octet-stream','X-Test-File-Name':f.name},body:f});
 const facts=await response.json();
 document.getElementById('result').textContent=facts.bytesMatched&&facts.fileNameMatched
 ?'本机接收器已核对：原字节完全一致':'核对失败';
});
</script></html>''';
