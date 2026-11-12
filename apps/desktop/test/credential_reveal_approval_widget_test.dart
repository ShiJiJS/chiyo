import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/credential_use_approval.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

void main() {
  testWidgets(
    'reveal approval is explicit and never renders stored plaintext',
    (tester) async {
      await tester.runAsync(() async {
        final service = InformationService(
          repository: MemoryInformationRepository(),
        );
        addTearDown(service.close);
        var credential = await service.owner.createStringCredential(
          name: 'Synthetic login password',
          publicPurpose: '',
          secret: 'SYNTHETIC_PASSWORD_MUST_NOT_APPEAR_IN_APPROVAL',
        );
        credential = await service.owner.updateCredentialMetadata(
          credential.id,
          credential.revision,
          name: credential.name,
          publicPurpose: '',
          privateNote: '',
          suggestedBinding: '',
          discoverable: true,
        );
        final session = service.agent.openSession('Synthetic chat');
        final request = await service.agent.requestCredentialReveal(
          session,
          CredentialRevealInput.fromJson({
            'protocolVersion': 2,
            'command': 'request-reveal',
            'credentialId': credential.id,
            'version': credential.version,
            'purpose': 'Sign in to the synthetic service',
            'fallbackReason': 'Synthetic target cannot be filled',
          }),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: zhiyuTheme(Brightness.light),
            home: Scaffold(
              body: CredentialUseApprovalPanel(
                owner: service.owner,
                request: request,
                draft: CredentialUseApprovalDraft(const []),
                onChanged: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('允许 AI 读取密码原文'), findsOneWidget);
        expect(
          find.textContaining('SYNTHETIC_PASSWORD_MUST_NOT_APPEAR'),
          findsNothing,
        );
        expect(service.owner.credentialGrantState(request), 'not_approved');
        await tester.tap(find.text('允许读取原文'));
        await tester.pumpAndSettle();
        final stored = service.owner.credentialUseRequests.single;
        expect(stored.isReveal, isTrue);
        expect(service.owner.credentialGrantState(stored), 'available');
        expect(stored.revealReads, isEmpty);
        expect(
          find.textContaining('SYNTHETIC_PASSWORD_MUST_NOT_APPEAR'),
          findsNothing,
        );
        await tester.tap(find.text('撤销授权'));
        await tester.pumpAndSettle();
        expect(
          service.owner.credentialGrantState(
            service.owner.credentialUseRequests.single,
          ),
          'revoked',
        );
      });
    },
  );
}
