Map<String, Object?> syntheticTemplatePackage(
  String version, {
  bool extra = false,
}) => {
  'id': 'local.synthetic',
  'name': 'Synthetic notes',
  'version': version,
  'hostApi': 1,
  'author': 'Automated test',
  'description': 'Declarative test definitions, no user values.',
  'templates': [
    {
      'id': 'note',
      'name': 'Synthetic note',
      'icon': 'book',
      'instructions':
          'Use plain or markdown for the format. Put configuration steps in body; relate a deployment rather than duplicate it.',
      'fields': [
        {'key': 'format', 'label': 'Format', 'type': 'text', 'required': true},
        {'key': 'body', 'label': 'Body', 'type': 'multiline', 'required': true},
        if (extra)
          {
            'key': 'maintainer',
            'label': 'Maintainer',
            'type': 'text',
            'required': false,
          },
      ],
      'sections': [
        {
          'kind': 'text',
          'title': 'Configuration',
          'key': 'body',
          'formatKey': 'format',
        },
        if (extra)
          {
            'kind': 'fields',
            'title': 'Contacts',
            'keys': ['maintainer'],
          },
      ],
      'relations': [],
      'example': {
        'name': 'Synthetic device configuration',
        'summary': 'Device configuration example.',
        'values': {
          'format': 'markdown',
          'body': '## Configuration\n\n- Use the deployment endpoint.',
        },
      },
    },
  ],
};
