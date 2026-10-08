$ErrorActionPreference = 'Stop'
if ($env:SOURCE_REVISION -notmatch '^[a-f0-9]{40}$' -or $env:PRODUCT_VERSION -notmatch '^\d+\.\d+\.\d+$' -or $env:BUILD_RUN_ID -notmatch '^\d+-\d+$') { throw 'Invalid diagnostic input' }
if (-not $env:RUNNER_TEMP -or -not $env:SOURCE_READ_KEY -or -not $env:DIAGNOSTIC_TRANSFER_KEY) { throw 'Missing diagnostic credential' }
$publicRoot = $PWD.Path
$sourceRoot = Join-Path $env:RUNNER_TEMP ('source-' + $env:BUILD_RUN_ID)
$diagnosticRoot = Join-Path $env:RUNNER_TEMP ('exit-diagnostic-' + $env:BUILD_RUN_ID)
$publicOutput = Join-Path $publicRoot 'public-output'
$key = Join-Path $env:RUNNER_TEMP ('source-key-' + $env:BUILD_RUN_ID)
$hosts = Join-Path $env:RUNNER_TEMP ('source-hosts-' + $env:BUILD_RUN_ID)
$log = Join-Path $env:RUNNER_TEMP ('exit-diagnostic-' + $env:BUILD_RUN_ID + '.log')
$errors = Join-Path $env:RUNNER_TEMP ('exit-diagnostic-errors-' + $env:BUILD_RUN_ID + '.log')
$phase = 'source'
$process = $null
$passed = $false
New-Item -ItemType Directory -Path $sourceRoot,$publicOutput | Out-Null
try {
  [IO.File]::WriteAllText($key, $env:SOURCE_READ_KEY.Trim() + "`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($hosts, "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl`n", [Text.UTF8Encoding]::new($false))
  $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  & icacls.exe $key /inheritance:r /grant:r ($account + ':F') *> $log
  if ($LASTEXITCODE) { throw 'Credential access preparation failed' }
  $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="' + $hosts.Replace('\','/') + '" -i "' + $key.Replace('\','/') + '"'
  & git -C $sourceRoot init *>> $log
  if ($LASTEXITCODE) { throw 'Source initialization failed' }
  & git -C $sourceRoot remote add origin git@github.com:grusirna/zhubobanlv-source.git *>> $log
  if ($LASTEXITCODE) { throw 'Source remote preparation failed' }
  & git -C $sourceRoot fetch --no-tags origin main *>> $log
  if ($LASTEXITCODE) { throw 'Source read failed' }
  & git -C $sourceRoot merge-base --is-ancestor $env:SOURCE_REVISION origin/main *>> $log
  if ($LASTEXITCODE) { throw 'Diagnostic source outside main' }
  & git -C $sourceRoot checkout --detach $env:SOURCE_REVISION *>> $log
  if ($LASTEXITCODE) { throw 'Source checkout failed' }
  Remove-Item -LiteralPath $key,$hosts
  $env:SOURCE_READ_KEY = $null
  $env:GIT_SSH_COMMAND = $null
  $phase = 'decrypt'
  & node (Join-Path $publicRoot 'scripts/decrypt-diagnostic.mjs') *>> $log
  if ($LASTEXITCODE) { throw 'Diagnostic transfer failed' }
  $env:DIAGNOSTIC_TRANSFER_KEY = $null
  $env:GH_TOKEN = $null
  $phase = 'prepare'
  & pnpm -C $sourceRoot install --frozen-lockfile *>> $log
  if ($LASTEXITCODE) { throw 'Diagnostic dependency preparation failed' }
  $outer = Join-Path $diagnosticRoot 'nsis'
  $package = Join-Path $diagnosticRoot 'win-unpacked'
  & 'C:\Program Files\7-Zip\7z.exe' x (Join-Path $diagnosticRoot 'candidate.exe') ('-o' + $outer) -y -bso0 -bsp0 *>> $log
  if ($LASTEXITCODE) { throw 'Diagnostic NSIS extraction failed' }
  & 'C:\Program Files\7-Zip\7z.exe' x (Join-Path $outer '$PLUGINSDIR/app-64.7z') ('-o' + $package) -y -bso0 -bsp0 *>> $log
  if ($LASTEXITCODE) { throw 'Diagnostic package extraction failed' }
  $env:DIAGNOSTIC_PACKAGE_DIR = $package
  & node (Join-Path $sourceRoot 'scripts/diagnose-ui-exit.mjs') *>> $log
  if ($LASTEXITCODE) { throw 'Diagnostic instrumentation failed' }
  $phase = 'ui'
  $env:UNIFIED_PACKAGE_DIR = $package
  $env:ELECTRON_USER_DATA_PATH = Join-Path $diagnosticRoot 'codex-test-user-data'
  $env:STREAMER_COMPANION_ACCEPTANCE_TEST = '1'
  $process = Start-Process -FilePath (Get-Command node).Source -ArgumentList ('"' + (Join-Path $sourceRoot 'scripts/unified-ui-acceptance.mjs') + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput $errors -RedirectStandardError ($errors + '.stderr')
  $null = $process.Handle
  if (-not $process.WaitForExit(300000)) { throw 'Owned diagnostic UI exceeded its deadline' }
  $passed = $process.ExitCode -eq 0
} catch {
  @{status='fail';diagnosticOnly=$true;phase=$phase;runId=$env:BUILD_RUN_ID} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $publicOutput 'failure.json') -Encoding utf8
} finally {
  if ($process -and -not $process.HasExited) { & taskkill.exe /PID $process.Id /T /F | Out-Null; $null=$process.WaitForExit(10000) }
  foreach ($file in @($key,$hosts)) { if (Test-Path -LiteralPath $file) { if ((Get-Item -LiteralPath $file).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected credential link' }; Remove-Item -LiteralPath $file } }
  $env:SOURCE_READ_KEY = $null
  $env:GIT_SSH_COMMAND = $null
  $env:DIAGNOSTIC_TRANSFER_KEY = $null
  $env:GH_TOKEN = $null
  $files = @($log) + @(Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'output/unified-ui') -File -Recurse -ErrorAction SilentlyContinue | Where-Object Name -in @('desktop.log','failure.json','result.json') | ForEach-Object FullName)
  foreach ($file in @($errors,($errors + '.stderr'),(Join-Path $diagnosticRoot 'identity.json'))) { if (Test-Path -LiteralPath $file) { $files += $file } }
  if ((Test-Path -LiteralPath (Join-Path $sourceRoot 'scripts/build-transfer.mjs')) -and $files.Count) {
    $zip = Join-Path $env:RUNNER_TEMP ('exit-logs-' + $env:BUILD_RUN_ID + '.zip')
    Compress-Archive -LiteralPath $files -DestinationPath $zip
    & node (Join-Path $sourceRoot 'scripts/build-transfer.mjs') encrypt $zip (Join-Path $publicRoot 'build-transfer-public.pem') (Join-Path $publicOutput 'diagnostics.enc') *>> $log
    if ($LASTEXITCODE) { throw 'Diagnostic encryption failed' }
  }
  @{status=$(if ($passed) {'pass'} else {'fail'});diagnosticOnly=$true;phase=$phase;runId=$env:BUILD_RUN_ID} | ConvertTo-Json -Compress | Write-Output
}
if (-not $passed) { exit 1 }
