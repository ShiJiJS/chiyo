import 'dart:convert';
import 'package:flutter/material.dart';
import 'approval_presentation.dart';
import 'workspace_source.dart';
import 'request_presentation.dart';

/// The explanation never substitutes for the actual program or its receivers.
class ProgramPlan extends StatelessWidget {
  const ProgramPlan({
    super.key,
    required this.plan,
    required this.names,
    this.factsOnly = false,
  });
  final WorkspaceCredentialProgramPlan plan;
  final Map<String, String> names;
  final bool factsOnly;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      RequestFacts(
        facts: [
          RequestFact('运行程序', plan.programName, plan.executable),
          RequestFact(
            '使用哪份凭据',
            plan.receivingPositions
                .map(
                  (b) => '${names[b.credentialId] ?? '凭据'} · 第 ${b.version} 版',
                )
                .toSet()
                .join('\n'),
          ),
          RequestFact(
            '交给程序的方式',
            plan.receivingPositions.map((b) => b.destination).join('\n'),
            '仅交给获批程序，不显示凭据原文',
          ),
        ],
      ),
      if (!factsOnly) ...[
        const SizedBox(height: 14),
        ProgramExactPlan(plan: plan, names: names),
      ],
    ],
  );
}

class ProgramExactPlan extends StatelessWidget {
  const ProgramExactPlan({super.key, required this.plan, required this.names});
  final WorkspaceCredentialProgramPlan plan;
  final Map<String, String> names;
  @override
  Widget build(BuildContext context) {
    final arguments = plan.arguments(names),
        environment = plan.environment(names),
        input = plan.standardInput(names);
    return ApprovalExactDetails(
      key: ValueKey('program-exact-${plan.fingerprint}'),
      title: '完整命令与脚本',
      hint: '这是本次提交的完整程序计划；凭据只显示引用名称与版本。',
      text: [
        '程序：${plan.executable}',
        '工作目录：${plan.workingDirectory}',
        for (final e in environment.entries) '环境变量 ${e.key} = ${e.value}',
        if (input != null) '标准输入：$input',
        for (final (i, arg) in arguments.indexed)
          '\n参数 ${i + 1}：\n${arg.contains('\n') ? arg : jsonEncode(arg)}',
      ].join('\n'),
    );
  }
}

String programScopeDescription(
  WorkspaceCredentialProgramPlan plan,
  String id,
  String credential,
  int version,
) {
  if (!plan.matchesScope(id, credential, version)) return '第 $version 版';
  final index = int.parse(id.substring(1)) - 1;
  return '第 $version 版 · ${plan.receivingPositions[index].destination}';
}
