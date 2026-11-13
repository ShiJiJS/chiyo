import 'dart:convert';

/// Runs in one page task. Neither metadata nor receipts include input values.
/// Writing addresses the checked element directly, without a focus/input gap.
String browserFormExpression({
  required String url,
  required String form,
  required String field,
  Object? expectedStructure,
  String? password,
}) =>
    '($_function)(${jsonEncode({'url': url, 'form': form, 'field': field, 'expectedStructure': expectedStructure, 'password': password})})';

const _function = r'''function(config) {
  let written = false;
  const refuse = code => ({status: written ? 'unknown' : 'refused', code});
  const attribute = (node, name) => node.getAttribute(name) || '';
  const identity = node => ({
    tag: node.tagName.toLowerCase(),
    id: attribute(node, 'id'), name: attribute(node, 'name'),
    type: attribute(node, 'type'), role: attribute(node, 'role'),
    autocomplete: attribute(node, 'autocomplete'),
    label: attribute(node, 'aria-label')
  });
  function inspect() {
    if (location.href !== config.url) return {code:'destination_changed'};
    const forms = document.querySelectorAll(config.form);
    if (forms.length !== 1) return {code:'ambiguous_form'};
    const form = forms[0];
    const fields = form.querySelectorAll(config.field);
    if (fields.length !== 1) return {code:'ambiguous_field'};
    const field = fields[0];
    if (!(field instanceof HTMLInputElement) || field.type !== 'password')
      return {code:'not_password_field'};
    const style = getComputedStyle(field);
    if (!form.isConnected || !field.isConnected || field.disabled ||
        field.readOnly || !field.getClientRects().length ||
        style.visibility !== 'visible' || Number(style.opacity) === 0)
      return {code:'unavailable_target'};
    const structure = {
      form: {...identity(form), action:attribute(form,'action'),
             method:attribute(form,'method')},
      fields:[...form.querySelectorAll('input,select,textarea,button')].map(identity),
      selected:identity(field)
    };
    return {form, field, structure};
  }
  try {
    const found = inspect();
    if (found.code) return refuse(found.code);
    if (config.password === null)
      return {status:'ready', structure:found.structure};
    if (typeof config.password !== 'string' || !config.password.length)
      return refuse('unsupported_password_value');
    if (JSON.stringify(found.structure) !== JSON.stringify(config.expectedStructure))
      return refuse('form_changed');
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value')?.set;
    if (!setter) return refuse('unavailable_target');
    written = true;
    setter.call(found.field, config.password);
    found.field.dispatchEvent(new Event('input',{bubbles:true}));
    found.field.dispatchEvent(new Event('change',{bubbles:true}));
    const after = inspect();
    if (after.code || after.form !== found.form || after.field !== found.field ||
        JSON.stringify(after.structure) !== JSON.stringify(found.structure))
      return refuse('destination_changed');
    const getter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value')?.get;
    if (!getter || getter.call(found.field) !== config.password)
      return refuse('value_not_retained');
    return {status:'filled'};
  } catch {
    return refuse('browser_operation_failed');
  }
}''';
