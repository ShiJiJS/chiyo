import 'dart:convert';
import 'dart:io';
import 'package:info_cli/chiyo_intents.dart';

Future<void> main(List<String> args) async {
  try {
    final record = await ChiyoIntentStore(Directory(args[0]), args[1]).remember(
      'access-request',
      {
        'command': 'request',
        'purpose': args[3] == 'same' ? 'Synthetic 私有 意图' : 'Changed intent',
        'fields': [
          {'itemId': 'synthetic-item', 'fieldId': 'host'},
        ],
      },
      operationId: args[2],
    );
    stdout.writeln(
      jsonEncode({
        'status': 'ok',
        'createdAt': record.createdAt.toIso8601String(),
      }),
    );
  } on ChiyoIntentFailure catch (error) {
    stdout.writeln(jsonEncode({'status': 'refused', 'code': error.code}));
    exitCode = 2;
  }
}
