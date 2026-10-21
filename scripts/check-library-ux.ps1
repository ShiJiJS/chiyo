param(
  [Parameter(Mandatory=$true)][string]$FlutterBin,
  [ValidateSet('core','storage','cli','desktop','all')][string]$Scope='all',
  [switch]$FullDesktop,
  [switch]$FullCli
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
$dartExe=Join-Path $FlutterBin 'cache/dart-sdk/bin/dart.exe'
$flutterExe=Join-Path $FlutterBin 'flutter.bat'
$snapshots=@{}
$oldMirror=$env:PUB_HOSTED_URL
foreach($package in @('packages/info_core','packages/info_storage','packages/info_cli','apps/desktop')) {
  $path=Join-Path $projectRoot "$package/pubspec.lock"
  $snapshots[$path]=[IO.File]::ReadAllBytes($path)
}
function Invoke-Checked([string]$Executable,[string[]]$Arguments) {
  & $Executable @Arguments
  if($LASTEXITCODE -ne 0){throw "Check failed: $Executable $($Arguments -join ' ')"}
}
try {
  $env:PUB_HOSTED_URL='https://pub.flutter-io.cn'
  foreach($path in $snapshots.Keys) {
    [IO.File]::WriteAllText($path,[Text.Encoding]::UTF8.GetString($snapshots[$path]).Replace('https://pub.dev','https://pub.flutter-io.cn'),(New-Object Text.UTF8Encoding($false)))
  }
  foreach($package in @('packages/info_core','packages/info_storage','packages/info_cli','apps/desktop')) {
    $kind=if($package -eq 'apps/desktop'){'desktop'}elseif($package.EndsWith('info_core')){'core'}elseif($package.EndsWith('info_cli')){'cli'}else{'storage'}
    if($Scope -ne 'all' -and $Scope -ne $kind){continue}
    Push-Location (Join-Path $projectRoot $package)
    try {
      $exe=if($kind -eq 'desktop'){$flutterExe}else{$dartExe}
      Invoke-Checked $exe @('pub','get','--offline','--enforce-lockfile')
      if($kind -eq 'desktop') {
        Invoke-Checked $flutterExe @('analyze','--no-pub','--fatal-infos')
        $testFiles=if($FullDesktop){@('test/')}else{@('test/desktop_controls_test.dart','test/library_ux_controls_test.dart','test/library_filter_state_test.dart','test/organization_widget_test.dart','test/settings_round05_test.dart')}
        Invoke-Checked $flutterExe (@('test','--no-pub') + $testFiles + @('--reporter','expanded'))
      }elseif($kind -eq 'core') {
        Invoke-Checked $dartExe @('analyze','--fatal-infos')
        Invoke-Checked $dartExe @('test','test/organization_management_test.dart','test/library_test.dart','test/organization_tasks_test.dart','test/recycle_test.dart','--reporter','expanded')
      }elseif($kind -eq 'cli') {
        Invoke-Checked $dartExe @('analyze','--fatal-infos')
        $testFiles=if($FullCli){@('test/')}else{@('test/file_credential_runtime_test.dart','test/file_json_lines_test.dart','test/codex_process_test.dart','test/bundle_preparation_test.dart','test/codex_focused_fill_test.dart','test/codex_information_files_test.dart')}
        Invoke-Checked $dartExe (@('test','--concurrency','1','--reporter','expanded') + $testFiles)
      }else {
        Invoke-Checked $dartExe @('analyze','--fatal-infos')
        Invoke-Checked $dartExe @('test','test/organization_management_test.dart','test/organization_tasks_test.dart','test/backup_test.dart','test/complete_backup_test.dart','test/recycle_test.dart','test/revisions_test.dart','--reporter','expanded')
      }
    }finally{Pop-Location}
  }
}finally{
  foreach($path in $snapshots.Keys){[IO.File]::WriteAllBytes($path,$snapshots[$path])}
  $env:PUB_HOSTED_URL=$oldMirror
}
