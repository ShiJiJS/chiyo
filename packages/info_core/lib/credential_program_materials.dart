part of 'info_core.dart';

/// Private Host delivery only. Ordinary CLI receipts use the operation's
/// public metadata; no caller-provided alias or arbitrary secret path exists.
class CredentialProgramMaterial {
  CredentialProgramMaterial({
    required this.executionId,
    required this.requestId,
    required this.operationId,
    required this.executionCapability,
    required this.jobName,
    required this.plan,
    required Iterable<String> itemIds,
    required Map<String, CredentialMaterialValue> materials,
  }) : itemIds = List.unmodifiable(itemIds),
       materials = Map.unmodifiable(materials);
  final String executionId,
      requestId,
      operationId,
      executionCapability,
      jobName;
  final CredentialProgramPlan plan;
  final List<String> itemIds;
  final Map<String, CredentialMaterialValue> materials;
  Map<String, Object?> toPrivateJson() => {
    'version': 1,
    'executionId': executionId,
    'requestId': requestId,
    'operationId': operationId,
    'executionCapability': executionCapability,
    'jobName': jobName,
    'plan': plan.toJson(),
    'itemIds': itemIds,
    'materials': {
      for (final entry in materials.entries)
        entry.key: entry.value.toPrivateJson(),
    },
  };
  factory CredentialProgramMaterial.fromPrivateJson(Map<String, dynamic> json) {
    _useShape(json, {
      'version',
      'executionId',
      'requestId',
      'operationId',
      'executionCapability',
      'jobName',
      'plan',
      'itemIds',
      'materials',
    });
    if (json['version'] != 1 ||
        json['plan'] is! Map<String, dynamic> ||
        json['itemIds'] is! List ||
        json['materials'] is! Map<String, dynamic> ||
        !RegExp(
          r'^[A-Za-z0-9_-]{43}=?$',
        ).hasMatch(json['executionCapability'] as String? ?? '') ||
        json['jobName'] is! String ||
        !_DeviceCredentialExecution.validJob(json['jobName'] as String)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final plan = CredentialProgramPlan.fromPreparedJson(
      json['plan'] as Map<String, dynamic>,
    );
    final ids = (json['itemIds'] as List).cast<String>(),
        raw = json['materials'] as Map<String, dynamic>;
    if (ids.isEmpty ||
        ids.length > 20 ||
        ids.toSet().length != ids.length ||
        ids.length != plan.bindings.length ||
        ids.any((id) => !RegExp(r'^b(?:[1-9]|1[0-9]|20)$').hasMatch(id)) ||
        raw.length != ids.length ||
        raw.keys.any((id) => !ids.contains(id))) {
      throw const CredentialUseFailure('invalid_reference');
    }
    final materials = <String, CredentialMaterialValue>{};
    final values = <String, CredentialMaterialValue>{};
    for (var index = 0; index < ids.length; index++) {
      final value = raw[ids[index]], binding = plan.bindings[index];
      if (value is! Map<String, dynamic>) {
        throw const CredentialUseFailure('invalid_type');
      }
      _useShape(value, {'credentialId', 'version', 'form', 'bytesBase64'});
      if (value['bytesBase64'] is! String ||
          (value['bytesBase64'] as String).length > 1398104) {
        throw const CredentialUseFailure('limit_exceeded');
      }
      final key = jsonEncode([
        binding.reference.credentialId,
        binding.reference.version,
      ]);
      final material =
          values[key] ?? CredentialMaterialValue.fromPrivateJson(value);
      if (material.credentialId != binding.reference.credentialId ||
          material.version != binding.reference.version ||
          !binding.acceptsForm(material.form) ||
          material.bytes.isEmpty ||
          material.bytes.length >
              (material.form == CredentialForm.file ? 1048576 : 65536) ||
          value['credentialId'] != binding.reference.credentialId ||
          value['version'] != binding.reference.version ||
          material.form.name != value['form'] ||
          base64Encode(material.bytes) != value['bytesBase64']) {
        throw const CredentialUseFailure('invalid_reference');
      }
      if (binding.via == 'env' && material.stringValue.contains('\x00')) {
        throw const CredentialUseFailure('material_prepare_failed');
      }
      materials[ids[index]] = material;
      values[key] = material;
    }
    return CredentialProgramMaterial(
      executionId: _useId(json['executionId'], 'executionId'),
      requestId: _useId(json['requestId'], 'requestId'),
      operationId: _batchOperationId(json['operationId']),
      executionCapability: json['executionCapability'] as String,
      jobName: json['jobName'] as String,
      plan: plan,
      itemIds: ids,
      materials: materials,
    );
  }
  @override
  String toString() => 'CredentialProgramMaterial($executionId)';
}

class CredentialProgramClaim {
  const CredentialProgramClaim(this.operation, {this.material});
  final CredentialProgramOperation operation;
  final CredentialProgramMaterial? material;
  Map<String, Object?> toPublicJson() => {
    ...operation.toPublicJson(),
    'duplicate': material == null,
  };
  Map<String, Object?> toPrivateJson() => {
    ...toPublicJson(),
    if (material != null) 'material': material!.toPrivateJson(),
  };
}
