import 'package:flutter/widgets.dart';

/// Host-owned protected inputs. The workspace sees readiness and widgets only,
/// never the text or a reusable handle to credential material.
abstract class ProposalPasswords extends ChangeNotifier {
  bool ready(String proposalId, int version, String itemId);
  Widget input(
    String proposalId,
    int version,
    String itemId, {
    required bool enabled,
  });

  /// Store this proposal's edited inputs in one encrypted proposal revision.
  /// Returns the filled item identities, without values. No record is admitted.
  Future<Set<String>> store(String proposalId, int version);
  void clear(String proposalId);
}
