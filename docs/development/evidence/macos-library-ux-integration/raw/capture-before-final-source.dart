import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 setUpAll(() async {
  for(final name in ['ProductSans','AppSans']) {
   await (FontLoader(name)..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'))).load();
  }
  for(final face in {'Georgia':'Georgia.ttf','Consolas':'Courier New.ttf'}.entries) {await (FontLoader(face.key)..addFont(Future.value(ByteData.sublistView(await File('/System/Library/Fonts/Supplemental/${face.value}').readAsBytes())))).load();}
  await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
 });
 for(final theme in DesktopColorTheme.values) {
 for(final scale in [1.0,2.0]) {
 testWidgets('capture ${theme.name} $scale', (tester) async {
 tester.view.physicalSize=const Size(800,600);tester.view.devicePixelRatio=1;
 tester.platformDispatcher.textScaleFactorTestValue=scale;
 addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
 addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
 final service=InformationService.fictional();await service.owner.setColorTheme(theme);
 addTearDown(() async { await tester.pumpWidget(const SizedBox());final c=service.close();await tester.pump();await c;});
 for(var i=0;i<30;i++){await service.owner.createDirectory('合成目录 $i');}
 final key=GlobalKey();
 await tester.pumpWidget(RepaintBoundary(key:key,child:InformationApp(service:service,port:0)));
 await tester.pumpAndSettle();await tester.tap(find.byKey(const ValueKey('nav-1')));await tester.pumpAndSettle();
 final error=tester.takeException();
 if(true) { if(error!=null) debugPrint('EXPECTED_true_LAY/Users/jiangxinyi/Documents/Project/agent-info/build/macos-adaptation/issue41-library-ux-integration-20261022/renders: $error'); }
 else {expect(error,isNull);}
 Future<void> shot(String suffix) async {
 final boundary=key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
 await tester.runAsync(() async {final image=await boundary.toImage(); final bytes=await image.toByteData(format:ui.ImageByteFormat.png);await File('/Users/jiangxinyi/Documents/Project/agent-info/build/macos-adaptation/issue41-library-ux-integration-20261022/renders/before-${theme.name}-$scale-$suffix.png').writeAsBytes(bytes!.buffer.asUint8List());image.dispose();});
 }
 await shot('initial');
 if(false) {
  final value=find.text(service.owner.information.first.fields.first.value);
  await tester.ensureVisible(value);await tester.pumpAndSettle();
  expect(value.hitTestable(),findsOneWidget);expect(tester.takeException(),isNull);
  await shot('field');
 }

 });
 }
 }
}
