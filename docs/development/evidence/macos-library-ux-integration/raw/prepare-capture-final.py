from pathlib import Path
root=Path.cwd();out=root/'build/macos-adaptation/issue41-library-ux-integration-20261022'
(out/'renders').rename(out/'renders-unregistered-system-fonts');(out/'renders').mkdir()
for label,app in [('before',out/'native-1/source/apps/desktop'),('after',root/'apps/desktop')]:
 p=app/'.dart_tool/mac-compact-capture.dart';s=p.read_text();s=s.replace("await (FontLoader('MaterialIcons')", "for(final face in {'Georgia':'Georgia.ttf','Consolas':'Courier New.ttf'}.entries) {await (FontLoader(face.key)..addFont(Future.value(ByteData.sublistView(await File('/System/Library/Fonts/Supplemental/${face.value}').readAsBytes())))).load();}\n  await (FontLoader('MaterialIcons')")
 pos=s.index(' final boundary=');end=s.index('\n });',pos);shot=s[pos:end];s=s[:pos]+''' Future<void> shot(String suffix) async {
'''+shot.replace("-$scale.png'","-$scale-$suffix.png'")+'''
 }
 await shot('initial');
 if('''+('false' if label=='before' else 'true')+''') {
  final value=find.text(service.owner.information.first.fields.first.value);
  await tester.ensureVisible(value);await tester.pumpAndSettle();
  expect(value.hitTestable(),findsOneWidget);expect(tester.takeException(),isNull);
  await shot('field');
 }
'''+s[end:];p.write_text(s);(out/f'capture-{label}-final-source.dart').write_text(s)
