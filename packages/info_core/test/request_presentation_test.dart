import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'separate display fields adapt to legacy purpose without touching execution',
    () {
      final value = RequestPresentation.fromJson({
        'title': '检查部署',
        'summary': '查看容器状态。',
      });
      expect(value.toProtocolJson(), {'title': '检查部署', 'purpose': '查看容器状态。'});
      expect(value.toJson(), {'title': '检查部署', 'summary': '查看容器状态。'});
      final old = RequestPresentation.fromJson({
        'purpose': 'A long legacy explanation\n${'x' * 1000}',
      });
      expect(RequestPresentation.fromJson({'purpose': ' '}).summary, ' ');
      expect(old.title, isEmpty);
      expect(old.toProtocolJson(), {'purpose': old.summary});
    },
  );
  test(
    'ambiguous, missing, oversized or multiline display fields are rejected',
    () {
      for (final input in <Map<String, dynamic>>[
        {'title': '检查', 'summary': '说明', 'purpose': '另一份说明'},
        {'summary': '没有标题'},
        {'title': '只有标题'},
        {'title': 'x' * 81, 'summary': '说明'},
        {'title': '检查\n部署', 'summary': '说明'},
        {'title': true, 'purpose': '说明'},
        {'title': '检查', 'summary': 'x' * 601},
        {'title': '检查', 'summary': '\u0000'},
      ]) {
        expect(
          () => RequestPresentation.fromJson(input),
          throwsFormatException,
        );
      }
    },
  );
}
