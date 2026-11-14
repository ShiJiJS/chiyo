const DEMO_HTML = `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><style>
*{box-sizing:border-box}body{margin:0;font:14px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;color:#192421;background:white;padding:19px 36px}h2{font-size:18px;font-weight:600;margin:0 0 13px}form{padding:4px;border-radius:5px}label{display:block;margin:0 0 3px}input{width:100%;height:38px;border:1px solid #b3c3ba;border-radius:4px;padding:7px 10px;font:14px SFMono-Regular,monospace;color:#192421;margin-bottom:10px;background:#fff;outline-offset:2px;transition:background .2s,box-shadow .2s}button{display:block;border:0;background:#e8ede8;color:#4b5f52;border-radius:4px;width:100%;font:14px -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;padding:7px;cursor:default}.inspected{outline:2px solid #007764;outline-offset:2px}.found{background:#e1f3ed!important;box-shadow:0 0 0 2px #007764}input:focus-visible{outline:2px solid #007764}.filled{animation:flash .5s ease-out}@keyframes flash{from{background:#a4ddca}to{background:#e1f3ed}}@media(max-width:380px){body{padding:18px 25px}}@media(prefers-reduced-motion:reduce){*{transition:none;animation:none}}
</style><body><h2>登录项目工作台</h2><form id="login"><label for="account">账号</label><input id="account" type="text" autocomplete="off" spellcheck="false"><label for="password">密码</label><input id="password" type="password" autocomplete="off"><button type="button">登录</button></form></body></html>`;

document.addEventListener('alpine:init', () => {
  Alpine.data('tutorial', () => ({
    selected:'password', selector:'#password', queried:false, matches:[], filled:false,
    fillStatus:'会先复核上方选择的目标，再填写教学表单。', os:'mac', nativeFocus:'password',nativeValue:'',focusChanged:false,delivery:'idle',
    init(){
      this.$nextTick(() => {this.$refs.demo.srcdoc=DEMO_HTML;});
      const state=new URLSearchParams(location.search).get('state');
      if(state==='windows')this.os='win';
      if(state==='refused'){this.focusChanged=true;this.delivery='refused';}
    },
    readyDemo(){
      this.inspect('password');
      const state=new URLSearchParams(location.search).get('state');
      if(state==='filled'){this.query();this.fill();}
    },
    get elementNote(){return ({form:'form 把账号、密码和登录动作组织成一组。它本身不是文字输入框。',account:'input 是输入控件；id="account" 是开发者给它的标识，type="text" 表示普通文本。',password:'id="password" 用来标识这个元素；type="password" 决定输入按密码样式显示。',button:'button 是可操作的按钮。点击登录与填写输入框是两次不同操作。'})[this.selected];},
    doc(){return this.$refs.demo.contentDocument;},
    inspect(which){
      this.selected=which;
      const d=this.doc();if(!d)return;
      d.querySelectorAll('.inspected').forEach(e=>e.classList.remove('inspected'));
      const e=d.querySelector(which==='form'?'form':which==='button'?'button':`#${which}`);
      e?.classList.add('inspected');
    },
    chooseSelector(s){
      this.selector=s;this.queried=false;this.matches=[];this.filled=false;
      this.fillStatus='匹配条件已改变，请重新查找。';
      this.doc()?.querySelectorAll('.found,.filled').forEach(e=>e.classList.remove('found','filled'));
    },
    query(){
      const d=this.doc();if(!d)return;
      d.querySelectorAll('.found,.inspected').forEach(e=>e.classList.remove('found','inspected'));
      const els=[...d.querySelectorAll(this.selector)];
      this.matches=els.map(e=>e.id);this.queried=true;
      els.forEach(e=>e.classList.add('found'));
      this.fillStatus=els.length===1?'唯一匹配，可以填写这个密码框。':'匹配了两个输入框，需要缩小条件以确定唯一目标。';
    },
    get queryResult(){return this.queried?`NodeList(${this.matches.length}) [${this.matches.map(id=>'input#'+id).join(', ')}]`:'尚未查询';},
    get canFill(){return this.queried&&this.matches.length===1&&this.matches[0]==='password';},
    demoBrowserFill(){this.query();this.fill();},
    fill(){
      if(!this.canFill)return;
      const field=this.doc().querySelector(this.selector).cloneNode(true);
      field.value='hello';field.dispatchEvent(new Event('input',{bubbles:true}));
      this.filled=true;
      this.fillStatus='本节结果框显示 5 个圆点，演示值为 hello；上面的定位图保持未填写状态。';
    },
    resetWeb(){
      const d=this.doc();if(d)d.querySelectorAll('input').forEach(e=>{e.value='';e.classList.remove('found','filled');});
      this.selector='#password';this.queried=false;this.matches=[];this.filled=false;
      this.fillStatus='会先复核上方选择的目标，再填写教学表单。';this.inspect('password');
    },
    changeFocus(value){this.nativeFocus=value;this.delivery='idle';this.focusChanged=false;},
    setOS(value){this.os=value;this.delivery='idle';},
    resetDelivery(){this.delivery='idle';},
    highlight(code){
      const escaped=code.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
      return escaped.replace(/\b(AXUIElementCopyAttributeValue|AXUIElementCreateApplication|frontmostApplication|GetFocusedElement|get_CurrentIsPassword|GetForegroundWindow|GetGUIThreadInfo|CoCreateInstance|keyboardSetUnicodeString|postToPid|SendInput)\b/g,'<strong class="method-name">$1</strong>');
    },
    checkTarget(){this.delivery=this.nativeFocus!=='password'||this.focusChanged?'refused':'ready';},
    get targetCheckText(){if(this.nativeFocus!=='password')return '选中的是账号框，不符合密码输入条件，不能发送。';return this.delivery==='idle'?'先选择是否改变焦点，再比较。':this.focusChanged?'目标已变化，不能发送。':'目标一致，可以进入发送步骤；比较本身不输入文字。';},
    demoSend(){this.delivery=this.nativeFocus!=='password'||this.focusChanged?'refused':'sent';},
    get deliveryText(){
      if(this.delivery==='refused')return this.nativeFocus!=='password'?'当前是账号框：停止发送，hello 没有送入。':'检查发现控件已变：停止发送。hello 没有送入账号框。';
      if(this.delivery==='sent')return this.os==='mac'?'检查通过：向目标 PID 提交文字事件。应用仍需处理这些事件。':'检查通过：把 10 个事件加入输入流。应用仍需处理这些事件。';
      if(this.delivery==='ready')return '目标检查通过，尚未发送事件。';
      return '尚未发送事件。';
    },
    get queryCode(){return this.os==='mac'?`// Swift：省略错误处理与类型转换
let running = NSWorkspace.shared
    .frontmostApplication!
let app = AXUIElementCreateApplication(
    running.processIdentifier)
AXUIElementCopyAttributeValue(
    app, kAXFocusedUIElementAttribute,
    &field)`:`// C++：省略初始化与错误处理
CoCreateInstance(__uuidof(CUIAutomation8),
    nullptr, CLSCTX_INPROC_SERVER,
    IID_PPV_ARGS(&automation));
automation->GetFocusedElement(&field);`;},
    get propertyCode(){return this.os==='mac'?`// 查询这个控件的子角色
AXUIElementCopyAttributeValue(
    field, kAXSubroleAttribute, &subrole)
// 密码框的典型返回：AXSecureTextField`:`// 查询这个控件是否为密码框
BOOL isPassword = FALSE;
field->get_CurrentIsPassword(&isPassword);
// 密码框的典型返回：TRUE`;},
    get attributes(){return this.os==='mac'?
      [['kAXRoleAttribute','AXTextField'],['kAXSubroleAttribute','AXSecureTextField'],['kAXFocusedAttribute','true'],['kAXEnabledAttribute','true']]:
      [['get_CurrentControlType','UIA_EditControlTypeId'],['get_CurrentIsPassword','TRUE'],['get_CurrentHasKeyboardFocus','TRUE'],['get_CurrentIsEnabled','TRUE']];},
    get sendCode(){return this.os==='mac'?`let units = Array("hello".utf16)
// down / up 是按下和释放两个 CGEvent
// buffer 指向 units 中的文字数据
down.keyboardSetUnicodeString(
    stringLength: units.count,
    unicodeString: buffer)
// up 也调用同一方法装入文字
down.postToPid(targetPID)
up.postToPid(targetPID)`:`const wchar_t* text = L"hello";
INPUT events[10]{};
for (int i = 0; i < 5; ++i) {
  auto& down = events[2 * i];
  down.type = INPUT_KEYBOARD;
  down.ki.wScan = text[i];
  down.ki.dwFlags = KEYEVENTF_UNICODE;
  events[2 * i + 1] = down;
  events[2 * i + 1].ki.dwFlags |= KEYEVENTF_KEYUP;
}
UINT inserted = SendInput(
    10, events, sizeof(INPUT));`;}

  }));
});

// 深层来源链接打开所属折叠区，保留正常链接与键盘导航。
function revealHash(){
  const hash=location.hash.slice(1);if(!hash)return;
  const target=document.getElementById(hash);if(!target)return;
  const parent=target.closest('details');if(parent)parent.open=true;
}
window.addEventListener('hashchange',revealHash);
window.addEventListener('DOMContentLoaded',revealHash);
