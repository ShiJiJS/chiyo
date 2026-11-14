Map<String, dynamic> nativeTargetFixture({
  String controlKind = 'appkit_secure_text',
}) {
  final windows =
      controlKind != 'appkit_secure_text' && controlKind != 'macos_ax_password';
  final executable = windows
      ? r'C:\Synthetic\NativeFixture.exe'
      : '/Applications/Synthetic.app/Contents/MacOS/Synthetic';
  return {
    'targetId': 'N' * 32,
    'helperInstanceId': 'H' * 32,
    'platform': windows ? 'windows' : 'macos',
    'application': {'executable': executable, 'sha256': 'a' * 64},
    'appId': windows ? executable : 'synthetic.native',
    'appName': 'Synthetic Native',
    'windowId': 'W' * 32,
    'windowTitle': 'Synthetic login',
    'fieldLabel': 'Password',
    'controlKind': controlKind,
  };
}
