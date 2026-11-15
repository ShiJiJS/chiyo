import 'dart:io';

/// Public business input only: no session/owner identities or credential bytes.
Map<String, Object?> chiyoRequestTemplate(String kind, String via) {
  final windows = Platform.isWindows;
  final credential = {'credentialId': 'CREDENTIAL_ID', 'version': 1};
  final presentation = {'title': '简短的任务标题', 'summary': '说明为什么需要使用这份凭据。'};
  return switch (kind) {
    'exec' => {
      ...presentation,
      'launch': {
        'executable': windows
            ? r'C:\Program Files\Example\tool.exe'
            : '/absolute/path/to/tool',
        'cwd': windows ? r'C:\work\project' : '/absolute/path/to/project',
        'argv': <Object?>[
          if (via == 'file') {'file': credential},
        ],
        'env': <String, Object?>{if (via == 'env') 'SERVICE_TOKEN': credential},
        if (via == 'stdin') 'stdin': credential,
      },
    },
    'ssh' => {
      ...presentation,
      ...credential,
      'target': {
        'host': 'server.example.test',
        'port': 22,
        'user': 'deploy',
        'authentication': 'password',
        'credentialUse': 'login',
        'validity': 'session',
      },
    },
    'fill' => {
      ...presentation,
      'items': [
        {
          ...credential,
          'destination': {
            'via': via,
            if (via == 'native') 'targetId': 'TARGET_ID_FROM_FILL_TARGETS',
            if (via != 'native') ...{
              'url': 'https://service.example.test/login',
              'form': '#login',
              'selector': '#password',
              if (via == 'ego') ...{
                'space': 7,
                'page': 'p1',
              } else ...{
                'browser': 'http://127.0.0.1:9222',
                'tab': 'TAB_ID_FROM_BROWSER',
              },
            },
          },
        },
      ],
    },
    _ => throw ArgumentError.value(kind, 'kind'),
  };
}
