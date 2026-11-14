const DEMO_HTML = `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><style>
*{box-sizing:border-box}body{margin:0;font:14px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;color:#192421;background:white;padding:19px 36px}h2{font-size:18px;font-weight:600;margin:0 0 13px}form{padding:4px;border-radius:5px}label{display:block;margin:0 0 3px}input{width:100%;height:38px;border:1px solid #b3c3ba;border-radius:4px;padding:7px 10px;font:14px SFMono-Regular,monospace;color:#192421;margin-bottom:10px;background:#fff;outline-offset:2px;transition:background .2s,box-shadow .2s}button{display:block;border:0;background:#e8ede8;color:#4b5f52;border-radius:4px;width:100%;font:14px -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;padding:7px;cursor:default}.inspected{outline:2px solid #007764;outline-offset:2px}.found{background:#e1f3ed!important;box-shadow:0 0 0 2px #007764}input:focus-visible{outline:2px solid #007764}.filled{animation:flash .5s ease-out}@keyframes flash{from{background:#a4ddca}to{background:#e1f3ed}}@media(max-width:380px){body{padding:18px 25px}}@media(prefers-reduced-motion:reduce){*{transition:none;animation:none}}
</style><body><h2>登录项目工作台</h2><form id="login"><label for="account">账号</label><input id="account" type="text" autocomplete="off" spellcheck="false"><label for="password">密码</label><input id="password" type="password" autocomplete="off"><button type="button">登录</button></form></body></html>`;

// 同一组教学对象用于目标列表、窗口、控件树与后续目标说明。
const NATIVE_DEMO_TARGETS = [
  {key:'other',file:'OtherArchive.zip',targetId:'tgt_Q2mL7cV9xR4nK8pB6sF3dA',macId:'_NS:281',winId:'121'},
  {key:'task',file:'NativeBackgroundProof.zip',targetId:'tgt_W8Jk2Nx6fR9qP4vL7cY1sA',macId:'_NS:280',winId:'120'}
];
const NATIVE_DEMO_CONTROLS = [
  {key:'file',label:'文件名文字',kind:'text',macRole:'AXStaticText',winRole:'Text'},
  {key:'output',label:'输出目录',kind:'edit',macRole:'AXTextField',winRole:'Edit'},
  {key:'password',label:'密码',kind:'edit',macRole:'AXTextField',winRole:'Edit'},
  {key:'remember',label:'记住本次设置',kind:'check',macRole:'AXCheckBox',winRole:'CheckBox'},
  {key:'cancel',label:'取消',kind:'action',macRole:'AXButton',winRole:'Button'},
  {key:'confirm',label:'确定',kind:'action',macRole:'AXButton',winRole:'Button'}
];

document.addEventListener('alpine:init', () => {
  Alpine.data('tutorial', () => ({
    selected:'password', selector:'#password', queried:false, matches:[], filled:false,
    fillStatus:'会先复核上方选择的目标，再填写教学表单。', os:'mac',delivery:'idle',
    nativeStage:0,nativeWindow:'task',nativeComponent:'file',
    init(){
      this.$nextTick(() => {this.$refs.demo.srcdoc=DEMO_HTML;});
      const state=new URLSearchParams(location.search).get('state');
      if(state==='windows')this.os='win';
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
    setOS(value){this.os=value;this.delivery='idle';this.resetNativeSelection();},
    resetDelivery(){this.delivery='idle';},
    highlight(code){
      const escaped=code.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
      return escaped.replace(/\b(AXUIElementCopyAttributeValue|AXUIElementCreateApplication|AXUIElementIsAttributeSettable|AXUIElementSetAttributeValue|ElementFromHandle|CreatePropertyCondition|FindAll|GetCurrentPatternAs|put_AutoSetFocus|SetValue)\b/g,'<strong class="method-name">$1</strong>');
    },
    demoSend(){this.delivery='sent';},
    get deliveryText(){
      if(this.delivery==='sent')return '演示结果：hello 填入左侧后台密码框，显示为 5 个圆点；右侧邮件正文保持原样，你仍可继续写邮件。';
      return '尚未演示。点击按钮，看左侧密码框变化；右侧邮件正文将保持原样。';
    },
    get nativeAppName(){return this.os==='mac'?'归档实用工具':'7-Zip';},
    get nativeAppId(){return this.os==='mac'?'com.apple.archiveutility':'C:\\Program Files\\7-Zip\\7zFM.exe';},
    get nativeTargets(){return NATIVE_DEMO_TARGETS.map(target=>({...target,
      windowTitle:target.file+' · 输入密码',
      fieldLabel:`密码 [${this.os==='mac'?'AXIdentifier='+target.macId:'AutomationId='+target.winId}]`
    }));},
    get nativeTaskTarget(){return this.nativeTargets[1];},
    get nativeViewedTarget(){return this.nativeTargets.find(target=>target.key===this.nativeWindow);},
    get nativeControls(){return NATIVE_DEMO_CONTROLS;},
    nativeTreeControls(key){return key===this.nativeWindow?this.nativeControls:this.nativeControls.filter(control=>control.key==='password');},
    nativeRole(control){return this.os==='mac'?control.macRole:control.winRole;},
    inspectNative(windowKey,componentKey){this.nativeWindow=windowKey;this.nativeComponent=componentKey;},
    resetNativeSelection(){this.nativeStage=0;this.nativeWindow='task';this.nativeComponent='file';},
    scanNativeTargets(){this.nativeStage=1;},
    selectNativeTask(){if(this.nativeStage<1)return;this.nativeStage=2;this.inspectNative('task','password');},
    nativeControlClass(windowKey,componentKey){return {
      'is-inspected':this.nativeWindow===windowKey&&this.nativeComponent===componentKey,
      'is-candidate':this.nativeStage>=1&&componentKey==='password',
      'is-chosen':this.nativeStage===2&&windowKey==='task'&&componentKey==='password',
      'is-excluded':this.nativeStage>=1&&componentKey!=='password'
    };},
    nativeControlStatus(windowKey,componentKey){
      if(this.nativeStage===0)return '';
      if(componentKey!=='password')return '未进入 targets';
      return this.nativeStage===2&&windowKey==='task'?'Agent 已选中':'候选';
    },
    get nativeInspectedControl(){return this.nativeControls.find(control=>control.key===this.nativeComponent);},
    get nativeInspectedAttributes(){
      const control=this.nativeInspectedControl,target=this.nativeViewedTarget;
      const rows=[[this.os==='mac'?'AXRole':'ControlType',this.nativeRole(control)]];
      if(control.kind==='edit'){
        rows.push(this.os==='mac'?['AXSubrole',control.key==='password'?'AXSecureTextField':'未提供（无安全子角色）']:['IsPassword',control.key==='password'?'true':'false']);
      }
      if(control.key==='password')rows.push([this.os==='mac'?'AXIdentifier':'AutomationId',this.os==='mac'?target.macId:target.winId]);
      return rows;
    },
    get nativeInspectionNote(){
      if(this.nativeComponent==='password')return this.nativeStage>=1?'本例假设此密码框已通过身份、可用性、直接设值能力与兼容检查，成为可填写候选；这还不是批准。':'密码语义只是一项筛选条件，还要检查身份、可用性、直接设值能力与兼容支持。';
      return ({file:'这是静态文字，只描述文件；不接收密码。',output:'这是普通文本框。可编辑不等于密码控件，不进入本次 targets。',remember:'这是勾选控件，不是密码输入目标。',cancel:'这是按钮。执行取消与设置密码框的值是不同操作。',confirm:'这是按钮。点击确定与填写密码是不同操作。'})[this.nativeComponent];
    },
    get nativeSelectionStatus(){
      if(this.nativeStage===0)return '结构初态：点击窗口里的组件或树节点，查看两侧的对应关系。查看组件不会选择填写目标。';
      if(this.nativeStage===1)return 'helper 已筛出 2 个候选密码框；普通组件仍留在树中，但未进入 targets。Agent 还没有按任务选择。';
      return 'Agent 对照任务文件名与密码字段，选中第二项。OtherArchive.zip 仍是候选，但属于另一文件。';
    },
    get nativeDiscoverCommand(){return this.os==='mac'?`chiyo fill targets --via native \\\n  --app com.apple.archiveutility --json`:`chiyo fill targets --via native --app "C:\\Program Files\\7-Zip\\7zFM.exe" --json`;},
    get queryCode(){return this.os==='mac'?`// Swift：pid 来自指定应用的运行进程
let app = AXUIElementCreateApplication(pid)
AXUIElementCopyAttributeValue(
    app, kAXWindowsAttribute, &windows)
// 对窗口逐层读取 AXChildren；省略遍历细节
AXUIElementCopyAttributeValue(
    window, kAXChildrenAttribute, &children)
// 逐项筛选支持的安全文本框
// 保留候选原对象，并返回说明与 targetId
// Agent 再按任务从返回项选择 targetId`:`// C++：automation 为已创建的 UIA 对象
// hwnd 来自指定应用的窗口
 automation->put_AutoSetFocus(FALSE);
 automation->ElementFromHandle(hwnd, &root);
 VARIANT passwordFlag{};
 passwordFlag.vt = VT_BOOL;
 passwordFlag.boolVal = VARIANT_TRUE;
 automation->CreatePropertyCondition(
     UIA_IsPasswordPropertyId, passwordFlag,
     &passwordCondition);
 root->FindAll(TreeScope_Descendants,
     passwordCondition.Get(), &fields);
// 逐项检查 fields，保留支持的候选原对象
// 返回每项的说明与 targetId
// Agent 再按任务从返回项选择 targetId`;},
    get propertyCode(){return this.os==='mac'?`AXUIElementCopyAttributeValue(
    field, kAXSubroleAttribute, &subrole)
// 本例：AXSecureTextField
AXUIElementIsAttributeSettable(
    field, kAXValueAttribute, &writable)
// 另核对已验证的应用版本、结构和上下文`:`field->get_CurrentIsPassword(&isPassword);
field->GetCurrentPatternAs(UIA_ValuePatternId,
    IID_PPV_ARGS(&valuePattern));
valuePattern->get_CurrentIsReadOnly(&readOnly);
// 另核对进程、窗口和原生控件支持状态`;},
    get attributes(){return this.os==='mac'?
      [['AXEnabled','true'],['AXValue 可写','true']]:
      [['IsEnabled','TRUE'],['ValuePattern','支持'],['IsReadOnly','FALSE']];},
    get sendCode(){return this.os==='mac'?`// field 是发现阶段保存并重新核验的原对象
let result = AXUIElementSetAttributeValue(
    field, kAXValueAttribute,
    "hello" as CFString)
// result == .success：设值调用已被接受`:`// field 是保存并重新核验的原对象
// 关闭 UIA 操作前自动设置焦点的行为
 automation->put_AutoSetFocus(FALSE);
 field->GetCurrentPatternAs(UIA_ValuePatternId,
     IID_PPV_ARGS(&valuePattern));
 HRESULT result = valuePattern->SetValue(L"hello");
// result == S_OK：设值调用已被接受`;}


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
