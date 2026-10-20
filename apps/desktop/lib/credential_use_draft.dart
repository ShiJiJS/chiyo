import 'package:info_core/info_core.dart';

/// Workspace-owned draft survives selection changes without becoming authority.
class CredentialUseApprovalDraft {
  CredentialUseApprovalDraft(Iterable<FieldRef> fields)
    : fields = fields.toSet();
  bool allowCredential = true, fieldsExpanded = false, planExpanded = false;
  int minutes = 15;
  int fieldMinutes = 480;
  final Set<FieldRef> fields;
  String? tip;
}
