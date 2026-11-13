import 'package:flutter/material.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

/// The request and each actual operation render the same typed public plan.
/// References are labels, never passwords or material paths.
class ProgramPlan extends StatelessWidget {
  const ProgramPlan({super.key, required this.plan, required this.names});
  final WorkspaceCredentialProgramPlan plan;
  final Map<String, String> names;
  @override
  Widget build(BuildContext context) {
    final environment = plan.environment(names),
        arguments = plan.arguments(names);
    final input = plan.standardInput(names);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _row(context, '程序', plan.executable),
        _row(context, '工作目录', plan.workingDirectory),
        if (arguments.isNotEmpty)
          _row(
            context,
            '参数',
            [
              for (var i = 0; i < arguments.length; i++)
                '${i + 1}. ${arguments[i]}',
            ].join('\n'),
          ),
        if (environment.isNotEmpty)
          _row(
            context,
            '环境变量',
            [
              for (final entry in environment.entries)
                '${entry.key} = ${entry.value}',
            ].join('\n'),
          ),
        if (input != null) _row(context, '标准输入', input),
      ],
    );
  }

  Widget _row(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: libraryText(context, 12, color: UiPalette.of(context).muted),
        ),
        const SizedBox(height: 3),
        SelectableText(value, style: libraryText(context, 14, height: 1.7)),
      ],
    ),
  );
}
