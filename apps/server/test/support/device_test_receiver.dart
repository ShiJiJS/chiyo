// Permissionless synthetic gh/aws receivers for native execution tests.
const syntheticCredentialReceiver = r'''#!/bin/sh
if [ "$1" = "--version" ]; then
  case "$0" in
    */gh) printf 'gh version 2.102.0\n';;
    */aws) printf 'aws-cli/2.38.1\n';;
  esac
  exit 0
fi
printf 'started\n' >> "$3"
printf 'CWD=%s\n' "$PWD"
case "$0" in
  */gh)
    [ "$GH_TOKEN" = "SYNTHETIC_DEVICE_TOKEN" ] || exit 41
    printf '%s\n' "$GH_TOKEN"
    ;;
  */aws)
    [ -n "$AWS_SHARED_CREDENTIALS_FILE" ] || exit 42
    [ ! -s "$AWS_CONFIG_FILE" ] || exit 43
    /usr/bin/grep -q 'SYNTHETIC_DEVICE_FILE' "$AWS_SHARED_CREDENTIALS_FILE" || exit 44
    printf '%s' "$AWS_SHARED_CREDENTIALS_FILE" > "$3.material-path"
    /bin/cat "$AWS_SHARED_CREDENTIALS_FILE"
    ;;
esac
while [ ! -f "$4" ]; do /bin/sleep 0.05; done
printf 'completed\n'
exit 0
''';
