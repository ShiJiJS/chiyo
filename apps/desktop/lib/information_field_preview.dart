import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'information_file_summary.dart';
import 'prototype_ui.dart';
import 'ui.dart';

/// Private owner views only. Public catalog projections use their own types.
String informationFieldValueLabel(InformationField field) =>
    field.kind == FieldKind.file
    ? '文件 · 版本 ${field.attachment!.attachmentVersion}'
    : field.value;

class InformationFieldContent extends StatelessWidget {
  const InformationFieldContent({
    super.key,
    required this.owner,
    required this.field,
  });
  final OwnerAccess owner;
  final InformationField field;
  @override
  Widget build(BuildContext context) => field.kind == FieldKind.file
      ? InformationFileSummary(owner: owner, reference: field.attachment!)
      : SelectableText(
          field.value,
          style: prototypeText(
            context,
            13,
            family: field.kind == FieldKind.structured ? 'Consolas' : null,
            height: 1.6,
          ),
        );
}

class InformationFieldPreview extends StatelessWidget {
  const InformationFieldPreview({
    super.key,
    required this.owner,
    required this.field,
  });
  final OwnerAccess owner;
  final InformationField field;
  @override
  Widget build(BuildContext context) {
    if (field.kind != FieldKind.file) {
      return InformationValue(
        name: field.name,
        description: field.description,
        value: field.value,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(field.name, style: Theme.of(context).textTheme.titleSmall),
          if (field.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                field.description,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: UiPalette.of(context).rail,
              borderRadius: BorderRadius.circular(6),
            ),
            child: InformationFieldContent(owner: owner, field: field),
          ),
        ],
      ),
    );
  }
}
