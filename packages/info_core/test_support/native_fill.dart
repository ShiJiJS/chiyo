Map<String, dynamic> nativeTargetFixture() => {
  'targetId': 'N' * 32,
  'helperInstanceId': 'H' * 32,
  'platform': 'macos',
  'application': {
    'executable': '/Applications/Synthetic.app/Contents/MacOS/Synthetic',
    'sha256': 'a' * 64,
  },
  'appId': 'synthetic.native',
  'appName': 'Synthetic Native',
  'windowId': 'W' * 32,
  'windowTitle': 'Synthetic login',
  'fieldLabel': 'Password',
  'controlKind': 'appkit_secure_text',
};
