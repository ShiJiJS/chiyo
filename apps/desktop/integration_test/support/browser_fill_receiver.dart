// Local synthetic receiver only. Password bytes stay in this process, the
// browser input and loopback POST bodies. Public records contain booleans only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

class BrowserFillReceiver {
  BrowserFillReceiver._(this.server, this._secret);
  final HttpServer server;
  final String _secret;
  int _generation = 0, _seenGeneration = -1, _sequence = -1;
  bool _arm = false, _matches = false, _empty = true, _changed = false;
  int _pastes = 0;
  String get url => 'http://127.0.0.1:${server.port}/target.html';

  static Future<BrowserFillReceiver> start(String secret) async {
    final result = BrowserFillReceiver._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      secret,
    );
    result.server.listen(result._handle);
    return result;
  }

  Future<void> _handle(HttpRequest request) async {
    request.response.headers.set('Cache-Control', 'no-store');
    try {
      if (request.method == 'GET' && request.uri.path == '/target.html') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(_page);
      } else if (request.method == 'GET' && request.uri.path == '/command') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'generation': _generation, 'arm': _arm}),
        );
      } else if (request.method == 'POST' && request.uri.path == '/input') {
        final bytes = <int>[];
        await for (final chunk in request) {
          bytes.addAll(chunk);
          if (bytes.length > 8192) {
            throw StateError('Oversized synthetic input');
          }
        }
        final value = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final sequence = value['sequence'] as int;
        if (sequence > _sequence) {
          _sequence = sequence;
          _seenGeneration = value['generation'] as int;
          _matches = value['password'] == _secret && value['other'] == '';
          _empty = value['password'] == '' && value['other'] == '';
          _changed = value['changed'] == true;
          _pastes = value['pastes'] as int;
        }
        bytes.fillRange(0, bytes.length, 0);
        request.response.write('ok');
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
    } on Object {
      request.response.statusCode = HttpStatus.badRequest;
    } finally {
      await request.response.close();
    }
  }

  Future<Map<String, Object?>> command(int code) async {
    if (code == 3 || code == 4) {
      _arm = code == 4;
      _generation++;
      final until = DateTime.now().add(const Duration(seconds: 3));
      while (_seenGeneration != _generation && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      if (_seenGeneration != _generation) {
        throw StateError('Synthetic browser did not acknowledge control');
      }
      return {'event': code == 3 ? 'cleared' : 'focus_change_armed'};
    }
    if (code == 2) {
      // Allow the final trusted input event's local verification POST to drain.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return {
        'event': 'verified',
        'matches': _matches,
        'empty': _empty,
        'noPaste': _pastes == 0,
        'focusChanged': _changed,
      };
    }
    return {'event': 'configured'};
  }

  Future<void> close() async => await server.close(force: true);

  static const _page = r'''<!doctype html><html lang="zh-CN">
<meta charset="utf-8"><title>本机填充合成测试</title>
<style>body{font:18px/1.7 system-ui;background:#f3f2f5;color:#28232d;padding:48px}main{max-width:640px;margin:auto;padding:32px;background:white;border:1px solid #dcd6df;border-radius:10px}input{display:block;width:100%;font:inherit;box-sizing:border-box;padding:10px;margin:8px 0 24px}button{font:inherit;padding:8px 16px}p{color:#605866}</style>
<main><h1>本机填充合成测试</h1><p>仅使用随机假密码；校验只发送到本机测试进程，不连接账号或外网。</p>
<label>密码框<input id="password" type="password" autocomplete="new-password"></label>
<label>焦点切换目标<input id="other" type="text" autocomplete="off"></label>
<button id="visibility" type="button">显示明文</button><p id="result">等待测试输入</p></main>
<script>
const password=document.querySelector('#password'),other=document.querySelector('#other');
let generation=-1,arm=false,changed=false,pastes=0,sequence=0;
const report=()=>fetch('/input',{method:'POST',body:JSON.stringify({sequence:sequence++,generation,password:password.value,other:other.value,changed,pastes})});
password.addEventListener('input',()=>{if(arm){arm=false;changed=true;other.focus()}report();document.querySelector('#result').textContent='已接收合成测试输入'});
other.addEventListener('input',report);
for(const field of [password,other])field.addEventListener('paste',()=>{pastes++;report()});
document.querySelector('#visibility').onclick=()=>{password.type=password.type==='password'?'text':'password';document.querySelector('#visibility').textContent=password.type==='password'?'显示明文':'恢复遮挡'};
let polling=false;
setInterval(async()=>{if(polling)return;polling=true;try{const control=await(await fetch('/command')).json();if(control.generation!==generation){generation=control.generation;arm=control.arm;if(!arm){password.value='';other.value='';changed=false}await report()}}finally{polling=false}},80);
</script></html>''';
}
