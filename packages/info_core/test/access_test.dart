import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'public catalog describes fictional fields without disclosing values',
    () {
      final service = InformationService.fictional();
      final catalog = service.agent.catalog();
      expect(catalog.single['id'], 'demo-server');
      expect(catalog.toString(), isNot(contains('demo.example.invalid')));
      expect(catalog.toString(), isNot(contains('demo-user')));
      expect((catalog.single['fields'] as List).length, 2);
    },
  );
}
