import 'package:info_core/info_core.dart';
import 'chiyo_command_line.dart';

/// Both the ordinary flags and a complex business file produce the same typed
/// launch contract. This module never probes a tool, asks for approval or reads
/// credential material. The real device Host will freeze the executable.
class ChiyoProgramRequest {
  const ChiyoProgramRequest._(this.purpose, this.launch);
  final String purpose;
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
    final purpose = business['purpose'];
    if (business.length != 2 ||
        !business.keys.toSet().containsAll({'purpose', 'launch'}) ||
        purpose is! String ||
        purpose.trim().isEmpty ||
        purpose.length > 2000 ||
        !validSubmissionMetadata(purpose: purpose) ||
        business['launch'] is! Map<String, dynamic>) {
      throw const ChiyoUsageFailure('程序业务文件只填写 purpose 和 launch。');
    }
    return ChiyoProgramRequest._(
      purpose,
      CredentialProgramPlan.fromJson(
        business['launch'] as Map<String, dynamic>,
      ),
    );
  }
  Map<String, Object?> toJson() => {
    'purpose': purpose,
    'launch': launch.toJson(),
  };
}
