import 'information.dart';

/// A template definition is a form aid, never an information field or a grant.
class TemplateFieldInput {
  const TemplateFieldInput(
    this.name,
    this.description, {
    this.kind = FieldKind.structured,
    this.definitionId,
  });
  final String name, description;
  final FieldKind kind;

  /// Retain an unchanged definition; changed meaning receives a fresh identity.
  final String? definitionId;
}

class TemplateFieldDefinition {
  const TemplateFieldDefinition(
    this.id,
    this.name,
    this.description,
    this.kind,
  );
  final String id, name, description;
  final FieldKind kind;
}

class InformationTemplate {
  InformationTemplate(
    this.id,
    this.name,
    this.description,
    this.version,
    Iterable<TemplateFieldDefinition> fields,
  ) : fields = List.unmodifiable(fields);
  final String id, name, description;
  final int version;
  final List<TemplateFieldDefinition> fields;
}
