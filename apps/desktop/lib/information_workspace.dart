import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'library.dart';
import 'credentials.dart';
import 'credential_files.dart';

/// Information and credentials share a navigation destination, never a value store.
class InformationWorkspace extends StatefulWidget {
  const InformationWorkspace({
    super.key,
    required this.owner,
    this.refresh,
    this.focusItemId,
    this.initialCredentialId,
    this.focusRevision = 0,
    this.onOpenInformation,
    this.files = const NativeCredentialFilePicker(),
  });
  final OwnerAccess owner;
  final Listenable? refresh;
  final String? focusItemId;
  final String? initialCredentialId;
  final int focusRevision;
  final ValueChanged<String>? onOpenInformation;
  final CredentialFilePicker files;
  @override
  State<InformationWorkspace> createState() => _InformationWorkspaceState();
}

class _InformationWorkspaceState extends State<InformationWorkspace> {
  bool _credentials = false;
  String? _itemId, _credentialId;
  int _itemNavigation = 0, _credentialNavigation = 0;
  @override
  void initState() {
    super.initState();
    _itemId = widget.focusItemId;
    _credentialId = widget.initialCredentialId;
    _credentials = _credentialId != null && _itemId == null;
  }

  @override
  void didUpdateWidget(InformationWorkspace old) {
    super.didUpdateWidget(old);
    if (old.focusRevision != widget.focusRevision &&
        widget.focusItemId != null) {
      _itemId = widget.focusItemId;
      _itemNavigation++;
      _credentials = false;
    }
  }

  void _openInformation(String id) {
    if (widget.onOpenInformation != null) {
      widget.onOpenInformation!(id);
      return;
    }
    setState(() {
      _itemId = id;
      _itemNavigation++;
      _credentials = false;
    });
  }

  @override
  Widget build(BuildContext context) => IndexedStack(
    index: _credentials ? 1 : 0,
    children: [
      InformationLibrary(
        key: ValueKey('information-$_itemNavigation'),
        owner: widget.owner,
        refresh: widget.refresh,
        initialItemId: _itemId,
        onOpenCredentials: () => setState(() => _credentials = true),
        onOpenCredential: (id) => setState(() {
          _credentialId = id;
          _credentialNavigation++;
          _credentials = true;
        }),
      ),
      CredentialLibrary(
        key: ValueKey('credentials-$_credentialNavigation'),
        owner: widget.owner,
        refresh: widget.refresh,
        initialCredentialId: _credentialId,
        files: widget.files,
        onInformationMode: () => setState(() => _credentials = false),
        onOpenInformation: _openInformation,
      ),
    ],
  );
}
