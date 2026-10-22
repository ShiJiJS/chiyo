from pathlib import Path
import re
root=Path.cwd()/'apps/desktop/lib'
def wrap(name, labels, skip=0):
 p=root/name;s=p.read_text();starts=[m.start() for m in re.finditer(r'(?<!\w)TextField\(',s)][skip:];assert len(starts)==len(labels),(name,len(starts))
 edits=[]
 for start,label in zip(starts,labels):
  i=s.index('(',start);depth=0;quote=None;escaped=False
  for j in range(i,len(s)):
   c=s[j]
   if quote:
    if escaped:escaped=False
    elif c=='\\':escaped=True
    elif c==quote:quote=None
   elif c in "'\"":quote=c
   elif c=='(':depth+=1
   elif c==')':
    depth-=1
    if depth==0:break
  assert depth==0
  edits.append((start,j+1,'MacTextFieldAccessibility(label: '+label+', child: '+s[start:j+1]+')'))
 for a,b,t in reversed(edits):s=s[:a]+t+s[b:]
 if "import 'mac_text_field_accessibility.dart';" not in s:s="import 'mac_text_field_accessibility.dart';\n"+s
 p.write_text(s)
wrap('organization_management.dart',["'目录名称'","'搜索标签'","'标签名称'"])
wrap('organization_selectors.dart',["'搜索目录'","'搜索标签'"])
wrap('history.dart',["'搜索聊天、Agent、记录编号'"])
wrap('credentials.dart',["'搜索名称、用途'"])
wrap('proposal_queue.dart',["'搜索提案、提交方'"])
wrap('approvals.dart',["'搜索信息'"])
wrap('inbox_queue.dart',["'搜索聊天、信息名称'"])
wrap('library.dart',["'搜索$scope'"])
wrap('credential_dialogs.dart',['label'])
p=root/'credential_dialogs.dart';s=p.read_text().replace('        Text(label, style: prototypeText(context, 13)),','        ExcludeSemantics(child: Text(label, style: prototypeText(context, 13))),');p.write_text(s)
wrap('templates.dart',['label'])
p=root/'templates.dart';s=p.read_text().replace('    Key? key,\n    String? hint,','    required String label,\n    Key? key,\n    String? hint,');s=s.replace('          _name,\n          key:',"          _name,\n          label: '模板名称',\n          key:");s=s.replace('                    _fields[i].name,\n                    key:',"                    _fields[i].name,\n                    label: '字段名称',\n                    key:");s=s.replace('_input(_description, maxLength: 2000)',"_input(_description, label: '模板说明', maxLength: 2000)");s=s.replace('_input(_fields[i].description, maxLength: 2000)',"_input(_fields[i].description, label: '字段 ${i + 1} 说明', maxLength: 2000)");s=s.replace("Text('模板名称', style: prototypeText(context, 13))","ExcludeSemantics(child: Text('模板名称', style: prototypeText(context, 13)))").replace("Text('模板说明', style: prototypeText(context, 13))","ExcludeSemantics(child: Text('模板说明', style: prototypeText(context, 13)))").replace("Text('字段 ${i + 1} 说明', style: prototypeText(context, 13))","ExcludeSemantics(child: Text('字段 ${i + 1} 说明', style: prototypeText(context, 13)))");p.write_text(s)
# _FieldFrame is shared with selectors: only actual ordinary editable children
# supply inputPurpose; native secure buttons retain their existing semantics.
p=root/'desktop_controls.dart';s=p.read_text();s="import 'mac_text_field_accessibility.dart';\n"+s
s=s.replace('    label: decoration.labelText,\n    child: usesNativeSecretEditor',"    label: decoration.labelText,\n    inputPurpose: usesNativeSecretEditor && obscureText ? null : decoration.labelText ?? decoration.hintText,\n    child: usesNativeSecretEditor",1)
s=s.replace('    label: decoration.labelText,\n    child: TextFormField(', '    label: decoration.labelText,\n    inputPurpose: decoration.labelText ?? decoration.hintText,\n    child: TextFormField(',1)
s=s.replace('const _FieldFrame({required this.child, this.label});\n  final String? label;','const _FieldFrame({required this.child, this.label, this.inputPurpose});\n  final String? label, inputPurpose;')
s=s.replace('          Semantics(label: label, child: child),',"          if (inputPurpose?.isNotEmpty == true)\n            MacTextFieldAccessibility(label: inputPurpose!, child: child)\n          else\n            Semantics(label: label, child: child),")
p.write_text(s)
wrap('desktop_controls.dart',["'搜索选项'"],skip=1)
