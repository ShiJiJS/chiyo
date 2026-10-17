import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';

Future<(InformationService,String,CredentialUseRequest)> fixture()async {
  final service=InformationService(repository:MemoryInformationRepository(),credentialExecutableInspector:(path,receiver)async=>ExecutableIdentity(path,1,1,'sha256:synthetic'));
  final item=await service.owner.createInformation('测试服务器','',[const FieldInput('服务器地址','','test.example.invalid')]);
  var c=await service.owner.createStringCredential(name:'文档站发布 Token',publicPurpose:'发布北辰文档站',secret:'synthetic-token');
  c=await service.owner.updateCredentialMetadata(c.id,c.revision,name:c.name,publicPurpose:c.publicPurpose,privateNote:'',suggestedBinding:'GH_TOKEN',discoverable:true);
  final session=service.agent.openSession('部署北辰文档站');
  final request=await service.agent.requestCredentialUse(session,CredentialUseInput.fromJson({'command':'request-use','purpose':'发布更新后的北辰文档站，需要使用 GitHub Token 完成本次发布。','credentials':[{'alias':'deploy_token','credentialId':c.id,'version':1}],'launch':{'receiver':'gh_token','executable':Platform.resolvedExecutable,'argv':['repo','view','northstar/docs'],'cwd':Directory.current.path,'env':{'GH_TOKEN':{'secret':'deploy_token'}}},'readFields':[{'itemId':item.id,'fieldId':item.fields.single.id}]}));
  return(service,session,request);
}

void main(){
  testWidgets('owner can approve fields independently from credential use through the real inbox', (tester)async {
    tester.view.physicalSize=const Size(1440,900);tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    final (service,session,request)=(await tester.runAsync(fixture))!;
    addTearDown(service.close);
    await tester.pumpWidget(InformationApp(service:service,port:0));
    await tester.pumpAndSettle();
    expect(find.text('允许这次启动'),findsOneWidget);
    expect(find.text('文档站发布 Token'),findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('credential-use-allow')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('credential-use-approve')));
    await tester.pumpAndSettle();
    expect(find.text('批准凭据使用'),findsOneWidget);
    await tester.tap(find.text('确认批准'));
    await tester.runAsync(()=>Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.textContaining('未能保存决定'),findsNothing);
    final status=service.agent.credentialUseStatus(session,request.id);
    expect(status['status'],'partially_approved');
    expect((status['decision'] as Map)['credentialUse'],{'approved':false});
    final grant=service.agent.claim(session,request.id);
    final value=await tester.runAsync(()=>service.agent.read(grant.token,request.fields.single));
    expect(value,'test.example.invalid');
    await tester.pumpWidget(const SizedBox());
  });
}
