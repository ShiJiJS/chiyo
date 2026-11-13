import 'package:args/args.dart';

class ChiyoUsageFailure implements Exception {
  const ChiyoUsageFailure(this.message);
  final String message;
}

class ChiyoInvocation {
  const ChiyoInvocation(
    this.path,
    this.options,
    this.root,
    this.json,
    this.help,
  );
  final String path;
  final ArgResults options, root;
  final bool json;
  final String? help;
}

/// One grammar owns parsing and discoverable help. Parsing performs no file,
/// network, browser, session or permission operations.
class ChiyoCommandLine {
  ChiyoCommandLine() {
    _root.addOption('context', help: '本聊天的私有配置文件；也可由 CHIYO_CONTEXT 提供。');
    _root.addFlag(
      'context-stdin',
      negatable: false,
      help: '从独立 stdin 读取宿主提供的私有上下文引用。',
    );
    _command('connection', '查看当前聊天绑定的资料库。');
    _command('connection show', '显示资料库、审批位置和执行设备，不输出私密凭证。');
    _command('chat', '建立、查看或结束独立聊天；不按公开聊天 ID 恢复许可。');
    final start = _command(
      'chat start',
      '建立初始未授权的聊天，并写入专用私有文件。',
      example:
          'chiyo chat start --agent "Example Agent" --id chat-1 --label "整理资料" --context-out /private/chat/context.json',
    );
    for (final name in ['agent', 'id', 'label', 'context-out', 'connection']) {
      start.addOption(
        name,
        help: switch (name) {
          'connection' => '独立 Agent 设备配置；省略则使用 App 当前配置。',
          'context-out' => '新私有文件的绝对路径；不能覆盖已有聊天。',
          'id' => '当前聊天的真实标识；有 CHIYO_CHAT_ID 或 CODEX_THREAD_ID 时须一致。',
          _ => '本次聊天的 $name。',
        },
      );
    }
    _command('chat show', '查看并核对本聊天状态。');
    _command('chat end', '结束本聊天，停止后续使用；不终止已经启动的外部业务。');
    _command('catalog', '查询公开资料名称、字段说明和归属，不读取正文。');
    final catalog = _command('catalog list', '按关键词、目录、模板和标签查询资料。');
    catalog.addOption('query', help: '名称或说明关键词。');
    catalog.addOption('directory', help: '目录 ID。');
    catalog.addOption('template', help: '模板 ID。');
    catalog.addOption('tag', help: '标签 ID。');
    _page(catalog);
    _command('directories', '查看现有目录，提案前复用已有归属。');
    _command('directories list', '返回完整目录层级，包括空目录。');
    _command('credentials', '查询托管凭据；使用申请与原文读取分别批准。');
    final credentials = _command('credentials list', '查询默认可见的凭据名称、用途、ID 和版本。');
    credentials.addOption('query', help: '名称或用途关键词。');
    credentials.addOption('directory', help: '目录 ID。');
    credentials.addOption('cursor', help: '上一页返回的游标。');
    credentials.addOption('limit', defaultsTo: '20', help: '每页 1–100 条。');
    _command('credentials reveal', '直接使用无法完成时，另行申请读取密码原文。');
    final reveal = _command(
      'credentials reveal request',
      '说明无法直接使用的原因；批准后原文会进入聊天。',
    );
    _credential(reveal);
    _operation(reveal);
    reveal.addOption('reason', help: '无法通过直接填写或程序接收完成的原因。');
    final read = _command('credentials reveal read', '领取单独获批的原文，保留独立操作记录。');
    _request(read);
    _operation(read);
    _command('templates', '动态查询当前库的插件模板、填写说明和示例。');
    final templates = _command('templates list', '列出当前已安装插件提供的模板。');
    templates.addOption('plugin', help: '插件包 ID。');
    _page(templates);
    _command('templates show', '查看模板格式和字段说明。', argument: 'ID');
    _command('templates examples', '查看模板提供的完整填写示例。', argument: 'ID');
    _command('access', '申请读取资料或领取普通附件；不直接批准。');
    final access = _command(
      'access request',
      '提交字段清单，返回申请 ID；不代表已获准。',
      example:
          'chiyo access request --item ITEM_ID --field FIELD_ID --purpose "核对服务地址" --json',
    );
    _input(access);
    access.addOption('item', help: '单项资料 ID；多字段使用 --input。');
    access.addOption(
      'field',
      help:
          '单个字段 ID；--input 文件格式为 {"fields":[{"itemId":"...","fieldId":"..."}]}。',
    );
    _purpose(access);
    _operation(access);
    final accessRead = _command('access read', '读取已获准的普通字段。');
    _request(accessRead);
    accessRead.addOption('item', help: '资料 ID。');
    accessRead.addOption('field', help: '字段 ID。');
    _command('requests', '查询本聊天的访问、凭据、提案及整理申请。');
    final requests = _command('requests list', '找回本聊天的申请，不按公开聊天 ID 查询其他聊天。');
    requests.addOption(
      'kind',
      allowed: [
        'access',
        'credential-use',
        'credential-reveal',
        'import',
        'update',
        'delete',
        'organization',
      ],
    );
    requests.addOption('status', help: '状态，例如 pending、approved、denied。');
    _page(requests);
    _command('requests show', '查看申请、批准范围和后续操作信息。', argument: 'ID');
    final wait = _command(
      'requests wait',
      '等待审批变化；等待超时不取消申请或缩短批准期限。',
      argument: 'ID',
    );
    wait.addOption('timeout', defaultsTo: '60', help: '本次最多等待的秒数，0–300。');
    _command('requests cancel', '取消仍待审的普通资料访问申请。', argument: 'ID');
    _command('proposals', '检查并提交新增、修改或删除提案；用户整体保存后才入库。');
    for (final verb in ['check', 'submit']) {
      final proposal = _command(
        'proposals $verb',
        verb == 'check'
            ? '按实际模板检查内容并冻结模板版本；不提交或写入信息库。'
            : '提交已检查的内容；模板变化时须重新检查。',
        example: verb == 'check'
            ? 'chiyo proposals check --input proposal.json --json'
            : 'chiyo proposals submit --check CHECK_ID --input proposal.json --json',
      );
      _input(proposal);
      proposal.addOption(
        'kind',
        allowed: ['import', 'update', 'delete'],
        defaultsTo: 'import',
      );
      if (verb == 'submit') {
        proposal.addOption('check', help: 'check 命令返回的检查编号，固定内容、文件和模板。');
        _operation(proposal);
      }
    }
    _command('proposals show', '查看本聊天提案的状态和入库结果。', argument: 'ID');
    final proposals = _command('proposals list', '列出本聊天的录入、修改和删除提案。');
    proposals.addOption('kind', allowed: ['import', 'update', 'delete']);
    proposals.addOption('status', help: '提案状态。');
    _page(proposals);
    _command('browsers', '查询明确指定的浏览器控制入口，不扫描端口或用户资料。');
    final browsers = _command('browsers list', '列出指定 Chrome 实例的标签页。');
    browsers.addOption('via', allowed: ['chrome'], defaultsTo: 'chrome');
    browsers.addOption(
      'browser',
      help: '本机 Chrome 控制地址，例如 http://127.0.0.1:9222。',
    );
    _command('fill', '申请并执行指定网页表单或本机密码框填写。');
    final fill = _command(
      'fill request',
      '检查目标并提交申请；保存计划，批准不自动填写。',
      example:
          "chiyo fill request --credential CREDENTIAL_ID --via ego --space 7 --page p1 --url https://example.test/login --form '#login' --selector '#password' --purpose '登录服务'",
    );
    _credential(fill);
    _input(fill);
    _operation(fill);
    fill.addOption(
      'via',
      allowed: ['ego', 'chrome', 'focus'],
      help: '选择实际填写途径，不选择内部脚本。',
    );
    for (final key in [
      'space',
      'page',
      'browser',
      'tab',
      'url',
      'form',
      'selector',
    ]) {
      fill.addOption(
        key,
        help: switch (key) {
          'browser' => 'Chrome 控制地址，不是网页网址。',
          'form' => '唯一匹配登录区域的 CSS 选择器。',
          'selector' => '在该区域内唯一匹配密码框的 CSS 选择器。',
          _ => '网页目标的 $key。',
        },
      );
    }
    final run = _command('fill run', '按获批计划发起一次新填写；先登记操作，再检查和发送。');
    _request(run);
    _operation(run);
    run.addMultiOption(
      'item',
      splitCommas: false,
      help: '仅执行申请中指定的条目 ID，可重复提供；省略则需要整份计划的所有条目均获准。ID 由软件返回，不手工起别名。',
    );
    _command('exec', '让业务程序通过标准输入、环境变量或受管文件使用凭据。');
    final exec = _command('exec request', '提交真实业务程序和凭据接收位置；不暴露内部填写程序。');
    _input(exec);
    _credential(exec);
    exec.addOption(
      'via',
      allowed: ['stdin', 'env', 'file'],
      help: '这份凭据交给程序的实际位置；多份凭据使用 --input。',
    );
    exec.addOption('executable', help: '业务程序的绝对路径，不是知予内部脚本。');
    exec.addOption('cwd', help: '业务程序的工作目录绝对路径。');
    exec.addMultiOption(
      'arg',
      splitCommas: false,
      help: '一个普通参数，可重复；以 - 开头时使用 --arg=VALUE。',
    );
    exec.addOption('variable', help: 'env 的环境变量名；file 时表示通过此变量交付受管文件路径。');
    exec.addOption(
      'file-argument',
      help: 'file 方式中插入受管文件路径的参数位置，从 0 开始；与 --variable 二选一。',
    );
    _operation(exec);
    final execRun = _command('exec run', '执行获批业务程序；所需凭据全部有效后才启动。');
    _request(execRun);
    _input(execRun);
    _operation(execRun);
    final execOutput = _command('exec output', '读取本次程序的有限输出；不会重新启动程序。');
    execOutput.addOption('operation', help: '必填，原程序执行的操作编号；不会生成新编号或重新执行。');
    execOutput.addOption('cursor', defaultsTo: '0', help: '上次结果中的输出位置。');
    execOutput.addOption('limit', defaultsTo: '16', help: '本次读取 1–16 段。');
    _command('operations', '找回原操作；结果未知时查询，不重放输入。');
    final operations = _command('operations list', '列出本聊天的提交和执行操作。');
    operations.addOption('request', help: '只看某份申请的操作。');
    _page(operations);
    _command('operations show', '查询原操作的结果，不执行。', argument: 'ID');
    _command('operations retry', '恢复原操作；无法确认已发送结果时不再次填写。', argument: 'ID');
    final doctor = _command('doctor', '检查连接和当前电脑能力；不弹权限、不申请资料、不执行填写。');
    doctor.addOption(
      'via',
      allowed: ['ego', 'chrome', 'focus'],
      help: '检查特定填写途径。',
    );
    doctor.addOption('browser', help: '检查 Chrome 时明确提供本机控制地址。');
  }

  final _root = ArgParser();
  final _parsers = <String, ArgParser>{};
  final _descriptions = <String, String>{};
  final _arguments = <String, String>{};
  final _examples = <String, String>{};
  bool _rootInitialized = false;

  ArgParser _command(
    String path,
    String description, {
    String? argument,
    String? example,
  }) {
    if (!_rootInitialized) {
      _common(_root);
      _parsers[''] = _root;
      _descriptions[''] = '知予命令行：查询资料、提交提案、申请和使用凭据。';
      _rootInitialized = true;
    }
    final names = path.split(' ');
    final parent = names.take(names.length - 1).join(' ');
    final parser = ArgParser();
    _common(parser);
    _parsers[parent]!.addCommand(names.last, parser);
    _parsers[path] = parser;
    _descriptions[path] = description;
    if (argument != null) _arguments[path] = argument;
    if (example != null) _examples[path] = example;
    return parser;
  }

  void _common(ArgParser parser) {
    parser.addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: '显示此命令的参数、子命令和示例。',
    );
    parser.addFlag(
      'json',
      negatable: false,
      help: '输出 schemaVersion=1 的 JSON。',
    );
  }

  void _page(ArgParser p) {
    p.addOption('offset', defaultsTo: '0', help: '从第几条开始。');
    p.addOption('limit', defaultsTo: '20', help: '每页 1–100 条。');
  }

  void _input(ArgParser p) =>
      p.addOption('input', help: '复杂业务内容的 JSON 文件；- 表示数据 stdin，不含上下文。');
  void _purpose(ArgParser p) =>
      p.addOption('purpose', help: '本次使用目的，不填写密码、Token 或私钥原文。');
  void _operation(ArgParser p) =>
      p.addOption('operation', help: '同一次提交或执行的稳定编号；省略则自动生成。');
  void _request(ArgParser p) => p.addOption('request', help: '之前返回的申请 ID。');
  void _credential(ArgParser p) {
    p.addOption('credential', help: '凭据 ID；不需要另起别名。');
    p.addOption('version', help: '固定凭据版本；省略则申请时解析并保存当前版本。');
    _purpose(p);
  }

  ChiyoInvocation parse(List<String> arguments) {
    ArgResults root;
    try {
      root = _root.parse(_opaqueIdentifiers(arguments));
    } on ArgParserException {
      throw const ChiyoUsageFailure('命令或参数不正确；使用 chiyo --help 查看用法。');
    }
    var result = root;
    var path = '';
    var json = root['json'] as bool;
    String? help = root['help'] as bool ? usage('') : null;
    while (result.command != null) {
      result = result.command!;
      path = path.isEmpty ? result.name! : '$path ${result.name}';
      json = json || result['json'] as bool;
      if (result['help'] as bool) help = usage(path);
    }
    final parser = _parsers[path]!;
    if (help == null && parser.commands.isNotEmpty) help = usage(path);
    if (help == null) {
      if (result.rest.length != (_arguments.containsKey(path) ? 1 : 0)) {
        throw const ChiyoUsageFailure('缺少编号或提供了多余位置参数；请查看此命令的 --help。');
      }
      if (root['context-stdin'] == true &&
          result.options.contains('input') &&
          result['input'] == '-') {
        throw const ChiyoUsageFailure('私有上下文和业务内容不能同时使用 stdin。');
      }
      _validate(path, result);
    }
    return ChiyoInvocation(path, result, root, json, help);
  }

  /// Server IDs are opaque base64url and may begin with '-'. Keep trailing
  /// flags as flags and put only that positional ID after the conventional
  /// terminator. Use the actual grammar to skip option values and commands.
  List<String> _opaqueIdentifiers(List<String> arguments) {
    var parser = _root, path = '';
    for (var i = 0; i < arguments.length; i++) {
      final token = arguments[i];
      if (token == '--') return arguments;
      if (_arguments.containsKey(path) &&
          RegExp(r'^-[A-Za-z0-9_-]{42}=?$').hasMatch(token)) {
        return [...arguments.take(i), ...arguments.skip(i + 1), '--', token];
      }
      if (token.startsWith('--')) {
        final name = token.substring(2).split('=').first;
        final option = parser.options[name] ?? _root.options[name];
        if (option != null && !option.isFlag && !token.contains('=')) i++;
        continue;
      }
      final command = parser.commands[token];
      if (command != null) {
        parser = command;
        path = path.isEmpty ? token : '$path $token';
      }
    }
    return arguments;
  }

  void _validate(String path, ArgResults options) {
    void required(String key) {
      final value = options[key] as String?;
      if (value == null || value.trim().isEmpty) {
        throw ChiyoUsageFailure('缺少 --$key；请查看此命令的 --help。');
      }
    }

    void number(String key, int min, int max) {
      if (!options.options.contains(key) || options[key] == null) return;
      final value = int.tryParse(options[key] as String);
      if (value == null || value < min || value > max) {
        throw ChiyoUsageFailure('--$key 必须是 $min–$max 的整数。');
      }
    }

    number('limit', 1, 100);
    number('offset', 0, 1000000);
    number('timeout', 0, 300);
    number('version', 1, 2147483647);
    if (path == 'proposals submit' &&
        options['check'] != null &&
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
        ).hasMatch(options['check'] as String)) {
      throw const ChiyoUsageFailure('--check 必须使用检查命令返回的编号。');
    }
    if (options.options.contains('operation') &&
        options['operation'] != null &&
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
        ).hasMatch(options['operation'] as String)) {
      throw const ChiyoUsageFailure(
        '--operation 必须是 1–128 位字母、数字、点、下划线、冒号或连字符。',
      );
    }
    if (path == 'chat start') {
      for (final key in ['agent', 'id', 'label', 'context-out']) {
        required(key);
      }
    } else if (path == 'browsers list') {
      required('browser');
    } else if ({
      'fill run',
      'exec run',
      'credentials reveal read',
    }.contains(path)) {
      required('request');
    } else if (path == 'access read') {
      for (final key in ['request', 'item', 'field']) {
        required(key);
      }
    } else if (path == 'access request') {
      required('purpose');
      if (options['input'] == null) {
        required('item');
        required('field');
      } else if (options['item'] != null || options['field'] != null) {
        throw const ChiyoUsageFailure('--input 不能和 --item / --field 混用。');
      }
    } else if (path == 'exec output') {
      required('operation');
      number('cursor', 0, 2147483647);
      number('limit', 1, 16);
    } else if (path == 'exec request') {
      const single = [
        'credential',
        'version',
        'purpose',
        'via',
        'executable',
        'cwd',
        'variable',
        'file-argument',
      ];
      final arguments = options['arg'] as List<String>;
      if (options['input'] != null) {
        if (arguments.isNotEmpty || single.any((k) => options[k] != null)) {
          throw const ChiyoUsageFailure('--input 的程序计划不能和单项程序参数混用。');
        }
        return;
      }
      for (final key in ['credential', 'purpose', 'via', 'executable', 'cwd']) {
        required(key);
      }
      if (arguments.length > 128) {
        throw const ChiyoUsageFailure('程序普通参数最多 128 项。');
      }
      final via = options['via'];
      if (via == 'env') {
        required('variable');
        if (options['file-argument'] != null) {
          throw const ChiyoUsageFailure(
            'env 方式使用 --variable，不使用 --file-argument。',
          );
        }
      } else if (via == 'stdin') {
        if (options['variable'] != null || options['file-argument'] != null) {
          throw const ChiyoUsageFailure('stdin 方式不使用环境变量名或文件参数位置。');
        }
      } else {
        if ((options['variable'] == null) ==
            (options['file-argument'] == null)) {
          throw const ChiyoUsageFailure(
            'file 方式的 --variable 和 --file-argument 必须选一个。',
          );
        }
        if (options['variable'] != null) required('variable');
        number('file-argument', 0, arguments.length);
      }
    } else if ({'proposals check', 'proposals submit'}.contains(path)) {
      required('input');
      if (path == 'proposals submit') required('check');
    } else if (path == 'credentials reveal request') {
      for (final key in ['credential', 'purpose', 'reason']) {
        required(key);
      }
    } else if (path == 'fill request') {
      const single = [
        'credential',
        'version',
        'purpose',
        'via',
        'space',
        'page',
        'browser',
        'tab',
        'url',
        'form',
        'selector',
      ];
      if (options['input'] != null) {
        if (single.any((k) => options[k] != null)) {
          throw const ChiyoUsageFailure('--input 的多项计划不能和单项填写参数混用。');
        }
        return;
      }
      for (final key in ['credential', 'purpose', 'via']) {
        required(key);
      }
      final via = options['via'];
      if (via == 'focus') {
        if ([
          'space',
          'page',
          'browser',
          'tab',
          'url',
          'form',
          'selector',
        ].any((k) => options[k] != null)) {
          throw const ChiyoUsageFailure('本机密码框填写不能使用网页表单参数。');
        }
      } else {
        for (final key in ['url', 'form', 'selector']) {
          required(key);
        }
        if (via == 'ego') {
          required('space');
          required('page');
          number('space', 1, 2147483647);
          if (options['browser'] != null ||
              options['tab'] != null ||
              !RegExp(r'^p[1-9][0-9]*$').hasMatch(options['page'] as String)) {
            throw const ChiyoUsageFailure(
              'ego 需要工作区编号和 p1 形式的页面，不使用 Chrome 参数。',
            );
          }
        } else {
          required('browser');
          required('tab');
          if (options['space'] != null || options['page'] != null) {
            throw const ChiyoUsageFailure(
              'Chrome 使用浏览器控制地址和标签页 ID，不使用 ego 参数。',
            );
          }
        }
      }
    }
    if (path == 'doctor' &&
        options['browser'] != null &&
        options['via'] != 'chrome') {
      throw const ChiyoUsageFailure('--browser 需要同时指定 --via chrome。');
    }
  }

  String usage(String path) {
    final parser = _parsers[path]!;
    final text = StringBuffer(
      '${_descriptions[path]}\n\n用法：chiyo${path.isEmpty ? '' : ' $path'}',
    );
    if (parser.commands.isNotEmpty) text.write(' <命令>');
    if (_arguments.containsKey(path)) text.write(' ${_arguments[path]}');
    text.writeln(' [选项]\n');
    if (parser.commands.isNotEmpty) {
      text.writeln('命令：');
      for (final name in parser.commands.keys) {
        final key = path.isEmpty ? name : '$path $name';
        text.writeln('  ${name.padRight(14)}${_descriptions[key]}');
      }
      text.writeln();
    }
    text.writeln(parser.usage);
    if (_examples.containsKey(path)) {
      text.writeln('\n示例：\n  ${_examples[path]}');
    }
    if (path.isEmpty) {
      text.writeln(
        '\n典型流程：查询目录和模板 → 提交提案／使用申请 → 等待批准 → 执行 → 查询结果。\n每一级命令都有 --help；动态模板请用 templates 查询。',
      );
    }
    return text.toString();
  }
}
