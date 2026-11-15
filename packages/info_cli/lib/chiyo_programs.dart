import 'package:info_core/info_core.dart';
import 'chiyo_command_line.dart';

/// Both the ordinary flags and a complex business file produce the same typed
/// launch contract. This module never probes a tool, asks for approval or reads
/// credential material. The real device Host will freeze the executable.
class ChiyoProgramRequest {
  const ChiyoProgramRequest._(this.presentation, this.launch);
  final RequestPresentation presentation;
  String get purpose => presentation.summary;
  String get title => presentation.title;
  final CredentialProgramPlan launch;
  factory ChiyoProgramRequest.fromInvocation(
    ChiyoInvocation invocation, {
    Map<String, dynamic>? businessInput,
  }) {
    if (invocation.path != 'exec request') {
      throw const ChiyoUsageFailure('请使用 exec request 提交程序计划。');
    }
    final options = invocation.options;
    Map<String, dynamic> business;
    if (options['input'] != null) {
      if (businessInput == null) {
        throw const ChiyoUsageFailure('尚未读取程序业务文件。');
      }
      business = businessInput;
    } else {
      if (businessInput != null) {
        throw const ChiyoUsageFailure('单项程序参数不能另带业务文件。');
      }
      final credential = <String, dynamic>{
        'credentialId': options['credential'],
        if (options['version'] != null)
          'version': int.parse(options['version'] as String),
      };
      final arguments = <Object?>[...options['arg'] as List<String>];
      final environment = <String, dynamic>{};
      final via = options['via'];
      if (via == 'file' && options['file-argument'] != null) {
        arguments.insert(int.parse(options['file-argument'] as String), {
          'file': credential,
        });
      } else if (via != 'stdin') {
        environment[options['variable'] as String] = via == 'file'
            ? {'file': credential}
            : credential;
      }
      business = {
        if (options['title'] != null) 'title': options['title'],
        if (options['summary'] != null)
          'summary': options['summary']
        else
          'purpose': options['purpose'],
        'launch': {
          'executable': options['executable'],
          'cwd': options['cwd'],
          'argv': arguments,
          'env': environment,
          if (via == 'stdin') 'stdin': credential,
        },
      };
    }
    if (business.keys.any(
          (key) => !{'title', 'summary', 'purpose', 'launch'}.contains(key),
        ) ||
        business['launch'] is! Map<String, dynamic>) {
      throw const ChiyoUsageFailure(
        '程序申请只填写 title、summary 和 launch；旧 purpose 仍可使用。',
      );
    }
    try {
      return ChiyoProgramRequest._(
        RequestPresentation.fromJson(business),
        CredentialProgramPlan.fromJson(
          business['launch'] as Map<String, dynamic>,
        ),
      );
    } on FormatException catch (error) {
      throw ChiyoUsageFailure(error.message);
    }
  }

  Map<String, Object?> toJson() => {
    ...presentation.toJson(),
    'launch': launch.toJson(),
  };
}
