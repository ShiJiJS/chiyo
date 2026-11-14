import 'dart:convert';
import 'package:flutter/material.dart';
import 'approval_presentation.dart';
import 'workspace_source.dart';

/// The request and each operation share typed public facts. No summary infers
/// a script's purpose or exposes credential material or managed file paths.
class ProgramPlan extends StatelessWidget {
  const ProgramPlan({super.key, required this.plan, required this.names});
  final WorkspaceCredentialProgramPlan plan;
  final Map<String, String> names;
  @override
  Widget build(BuildContext context) {
    final arguments = plan.arguments(names),
        environment = plan.environment(names),
        input = plan.standardInput(names);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ApprovalDetailRow(
          label: '运行程序',
          value: '${plan.programName}\n${plan.executable}',
        ),
        ApprovalDetailRow(
          label: '在哪里运行',
          value: 'AI 所在的电脑\n工作目录：${plan.workingDirectory}',
        ),
        for (final binding in plan.receivingPositions)
          CredentialBindingCard(
            name: names[binding.credentialId] ?? '凭据',
            version: binding.version,
            destination: binding.destination == '程序启动时的输入（stdin）'
                ? '在程序启动时提供输入（stdin）。'
                : '交给${binding.destination}。',
          ),
        ApprovalExactDetails(
          key: ValueKey('program-exact-${plan.fingerprint}'),
          title: '完整命令与脚本',
          hint: '以下是这次提交的完整程序参数；凭据只显示引用名称与版本。',
          text: [
            '程序：${plan.executable}',
            '工作目录：${plan.workingDirectory}',
            for (final entry in environment.entries)
              '环境变量 ${entry.key} = ${entry.value}',
            if (input != null) '标准输入：$input',
            for (final (i, argument) in arguments.indexed)
              '\n参数 ${i + 1}：\n${argument.contains('\n') ? argument : jsonEncode(argument)}',
          ].join('\n'),
        ),
      ],
    );
  }
}
