import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'approvals_controller.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

class OperationPagesFooter extends StatelessWidget {
  const OperationPagesFooter({super.key, required this.controller});
  final ApprovalsController controller;
  @override
  Widget build(BuildContext context) {
    final detail = controller.detail;
    if (detail == null) return const SizedBox.shrink();
    final loaded =
        detail.batchOperations.length + detail.programOperations.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (detail.operationsCursor != null)
          DesktopButton(
            key: const ValueKey('load-older-credential-operations'),
            kind: DesktopButtonKind.quiet,
            busy: controller.readingOperationPage,
            onPressed:
                controller.frozen ||
                    controller.readingOperationPage ||
                    controller.loading ||
                    controller.reading ||
                    controller.source is! WorkspaceCredentialOperationPages
                ? null
                : controller.loadMoreOperations,
            child: Text('加载较早记录（已显示$loaded/${detail.operationsTotal}次）'),
          ),
        if (controller.operationPageError case final error?)
          Text(
            error,
            style: libraryText(
              context,
              13,
              color: UiPalette.of(context).warning,
              height: 1.8,
            ),
          ),
      ],
    );
  }
}
