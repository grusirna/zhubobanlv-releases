$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or
    $env:GITHUB_REPOSITORY -ne 'grusirna/zhubobanlv-releases' -or $env:GITHUB_REF -ne 'refs/heads/main' -or
    $env:GITHUB_JOB -ne 'installer' -or $env:GITHUB_ACTOR -ne 'grusirna' -or
    $env:SOURCE_REVISION -notmatch '^[a-f0-9]{40}$' -or $env:PRODUCT_VERSION -notmatch '^\d+\.\d+\.\d+$' -or
    $env:BUILD_RUN_ID -notmatch '^\d+-\d+$' -or -not $env:RUNNER_TEMP -or -not $env:SOURCE_READ_KEY -or
    -not $env:INSTALLER_TRANSFER_INPUTS) { throw 'Invalid isolated installer context' }
$publicRoot = $PWD.Path
$sourceRoot = Join-Path $env:RUNNER_TEMP ('installer-tools-' + $env:BUILD_RUN_ID)
$testRoot = Join-Path $env:RUNNER_TEMP ('installer-' + $env:BUILD_RUN_ID)
$publicOutput = Join-Path $publicRoot 'public-output'
$key = Join-Path $env:RUNNER_TEMP ('installer-source-key-' + $env:BUILD_RUN_ID)
$hosts = Join-Path $env:RUNNER_TEMP ('installer-source-hosts-' + $env:BUILD_RUN_ID)
$log = Join-Path $env:RUNNER_TEMP ('installer-bootstrap-' + $env:BUILD_RUN_ID + '.log')
$phase = 'source'
$process = $null
$passed = $false
New-Item -ItemType Directory -Path $sourceRoot,$publicOutput | Out-Null
try {
  [IO.File]::WriteAllText($key, $env:SOURCE_READ_KEY.Trim() + "`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($hosts, "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl`n", [Text.UTF8Encoding]::new($false))
  $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  & icacls.exe $key /inheritance:r /grant:r ($account + ':F') *> $log
  if ($LASTEXITCODE) { throw 'Credential access failed' }
  $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="' + $hosts.Replace('\','/') + '" -i "' + $key.Replace('\','/') + '"'
  & git -C $sourceRoot init *>> $log
  if ($LASTEXITCODE) { throw 'Source initialization failed' }
  & git -C $sourceRoot remote add origin git@github.com:grusirna/zhubobanlv-source.git *>> $log
  if ($LASTEXITCODE) { throw 'Source remote failed' }
  & git -C $sourceRoot fetch --no-tags origin main *>> $log
  if ($LASTEXITCODE) { throw 'Source read failed' }
  & git -C $sourceRoot merge-base --is-ancestor $env:SOURCE_REVISION origin/main *>> $log
  if ($LASTEXITCODE) { throw 'Source outside private main' }
  & git -C $sourceRoot checkout --detach $env:SOURCE_REVISION *>> $log
  if ($LASTEXITCODE) { throw 'Source checkout failed' }
  Remove-Item -LiteralPath $key,$hosts
  $env:SOURCE_READ_KEY = $null
  $env:GIT_SSH_COMMAND = $null
  $phase = 'inputs'
  $env:INSTALLER_TOOL_ROOT = $sourceRoot
  & node (Join-Path $publicRoot 'scripts/decrypt-installer.mjs') *>> $log
  if ($LASTEXITCODE) { throw 'Installer input preparation failed' }
  $env:INSTALLER_TRANSFER_INPUTS = $null
  $env:GH_TOKEN = $null
  $phase = 'installation'
  $arguments = '-NoProfile -File "' + (Join-Path $sourceRoot 'scripts/test-unified-installer.ps1') + '" -Version ' + $env:PRODUCT_VERSION + ' -PreviousVersion 0.1.14 -AcceptanceEnvironment GitHubHostedWindows -Share "' + (Join-Path $testRoot 'candidate') + '" -PreviousShare "' + (Join-Path $testRoot 'baseline') + '" -Results "' + (Join-Path $testRoot 'results') + '"'
  $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $testRoot 'results/acceptance.stdout.log') -RedirectStandardError (Join-Path $testRoot 'results/acceptance.stderr.log')
  $null = $process.Handle
  if (-not $process.WaitForExit(900000)) { & taskkill.exe /PID $process.Id /T /F | Out-Null; $null = $process.WaitForExit(10000); throw 'Owned installer acceptance timed out' }
  $result = Get-Content -LiteralPath (Join-Path $testRoot 'results/installer-result.json') -Raw | ConvertFrom-Json
  $passed = $process.ExitCode -eq 0 -and $result.status -eq 'pass' -and $result.acceptanceEnvironment -eq 'GitHubHostedWindows' -and $result.workflowRunId -eq $env:GITHUB_RUN_ID
  if (-not $passed) { throw 'Actual installer checks failed' }
} catch {
  @{status='fail';phase=$phase;runId=$env:BUILD_RUN_ID} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $publicOutput 'failure.json') -Encoding utf8
} finally {
  if ($process -and -not $process.HasExited) { & taskkill.exe /PID $process.Id /T /F | Out-Null; $null=$process.WaitForExit(10000) }
  foreach ($file in @($key,$hosts)) { if (Test-Path -LiteralPath $file) { if ((Get-Item -LiteralPath $file).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected credential link' }; Remove-Item -LiteralPath $file } }
  $env:SOURCE_READ_KEY = $null
  $env:GIT_SSH_COMMAND = $null
  $env:INSTALLER_TRANSFER_INPUTS = $null
  $env:GH_TOKEN = $null
  $files = @($log)
  if (Test-Path -LiteralPath (Join-Path $testRoot 'results')) {
    $items = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'results') -Recurse -Force)
    if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Unexpected result link' }
    $files += @($items | Where-Object { -not $_.PSIsContainer } | ForEach-Object FullName)
  }
  if ((Test-Path -LiteralPath (Join-Path $sourceRoot 'scripts/build-transfer.mjs')) -and $files.Count) {
    $zip = Join-Path $env:RUNNER_TEMP ('installer-evidence-' + $env:BUILD_RUN_ID + '.zip')
    Compress-Archive -LiteralPath $files -DestinationPath $zip
    & node (Join-Path $sourceRoot 'scripts/build-transfer.mjs') encrypt $zip (Join-Path $publicRoot 'build-transfer-public.pem') (Join-Path $publicOutput 'installer-evidence.enc') *>> $log
    if ($LASTEXITCODE) { throw 'Installer evidence encryption failed' }
  }
  @{status=$(if ($passed) {'pass'} else {'fail'});phase=$phase;runId=$env:BUILD_RUN_ID} | ConvertTo-Json -Compress | Write-Output
}
if (-not $passed) { exit 1 }
