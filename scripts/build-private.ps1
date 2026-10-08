$ErrorActionPreference = 'Stop'
if ($env:SOURCE_REVISION -notmatch '^[a-f0-9]{40}$' -or $env:PRODUCT_VERSION -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$' -or $env:BUILD_RUN_ID -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') { throw 'Invalid build input' }
if (-not $env:RUNNER_TEMP -or -not $env:SOURCE_READ_KEY) { throw 'Missing runner credential' }
$publicRoot = $PWD.Path
$sourceRoot = Join-Path $env:RUNNER_TEMP ('source-' + $env:BUILD_RUN_ID)
$privateOutput = Join-Path $env:RUNNER_TEMP ('candidate-' + $env:BUILD_RUN_ID)
$publicOutput = Join-Path $publicRoot 'public-output'
$key = Join-Path $env:RUNNER_TEMP ('source-key-' + $env:BUILD_RUN_ID)
$hosts = Join-Path $env:RUNNER_TEMP ('source-hosts-' + $env:BUILD_RUN_ID)
$bootstrapLog = Join-Path $env:RUNNER_TEMP ('bootstrap-' + $env:BUILD_RUN_ID + '.log')
$buildLog = Join-Path $env:RUNNER_TEMP ('build-' + $env:BUILD_RUN_ID + '.log')
$buildErrorLog = Join-Path $env:RUNNER_TEMP ('build-errors-' + $env:BUILD_RUN_ID + '.log')
$passed = $false
$failurePhase = 'source'
New-Item -ItemType Directory -Path $sourceRoot,$privateOutput,$publicOutput | Out-Null
try {
  [IO.File]::WriteAllText($key, $env:SOURCE_READ_KEY.Trim() + "`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($hosts, "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl`n", [Text.UTF8Encoding]::new($false))
  $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  & icacls.exe $key /inheritance:r /grant:r ($account + ':F') *> $bootstrapLog
  if ($LASTEXITCODE) { throw 'Credential access preparation failed' }
  $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="' + $hosts.Replace('\','/') + '" -i "' + $key.Replace('\','/') + '"'
  & git -C $sourceRoot init *>> $bootstrapLog
  if ($LASTEXITCODE) { throw 'Source initialization failed' }
  & git -C $sourceRoot remote add origin git@github.com:grusirna/zhubobanlv-source.git *>> $bootstrapLog
  if ($LASTEXITCODE) { throw 'Source remote preparation failed' }
  & git -C $sourceRoot fetch --no-tags origin main *>> $bootstrapLog
  if ($LASTEXITCODE) { throw 'Source read failed' }
  & git -C $sourceRoot cat-file -e ($env:SOURCE_REVISION + '^{commit}') *>> $bootstrapLog
  if ($LASTEXITCODE) { throw 'Unknown source commit' }
  & git -C $sourceRoot merge-base --is-ancestor $env:SOURCE_REVISION origin/main *>> $bootstrapLog
  if ($LASTEXITCODE) { throw 'Source commit is outside private main' }
  & git -C $sourceRoot checkout --detach $env:SOURCE_REVISION *>> $bootstrapLog
  if ($LASTEXITCODE) { throw 'Source checkout failed' }
  Remove-Item -LiteralPath $key,$hosts
  $env:SOURCE_READ_KEY = $null
  $env:GIT_SSH_COMMAND = $null
  $failurePhase = 'build'
  $env:PUBLIC_OUTPUT_DIR = $privateOutput
  $buildProcess = Start-Process -FilePath (Get-Command node).Source -ArgumentList ('"' + (Join-Path $sourceRoot 'scripts/github-build.mjs') + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput $buildLog -RedirectStandardError $buildErrorLog
  $null = $buildProcess.Handle
  $knownGates = @('install','dependencies','audit','lint','build','typecheck','tests','coverage','releaseTests','runtime','native','nativeTests','cjs','package','packageSecrets','backend','ui')
  $shown = @{}
  do {
    Start-Sleep -Seconds 5
    $buildProcess.Refresh()
    $currentReport = $null
    try { $currentReport = Get-Content -LiteralPath (Join-Path $sourceRoot 'output/github-build/private-evidence/build-report.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch {}
    if ($currentReport.sourceRevision -eq $env:SOURCE_REVISION -and $currentReport.productVersion -eq $env:PRODUCT_VERSION -and $currentReport.runId -eq $env:BUILD_RUN_ID) {
      foreach ($gate in $knownGates) {
        $status = $currentReport.checks.$gate.status
        if ($status -in @('pass','fail') -and $shown[$gate] -ne $status) {
          @{phase=$gate;status=$status;sourceRevision=$env:SOURCE_REVISION;productVersion=$env:PRODUCT_VERSION;runId=$env:BUILD_RUN_ID} | ConvertTo-Json -Compress | Write-Output
          $shown[$gate] = $status
        }
      }
    }
  } while (-not $buildProcess.HasExited)
  if ($buildProcess.ExitCode -ne 0) { throw 'Build gate failed' }
  $report = Get-Content -LiteralPath (Join-Path $privateOutput 'build-report.json') -Raw | ConvertFrom-Json
  $installer = Join-Path $privateOutput $report.artifact.filename
  $failurePhase = 'transfer'
  & node (Join-Path $sourceRoot 'scripts/build-transfer.mjs') encrypt $installer (Join-Path $publicRoot 'build-transfer-public.pem') (Join-Path $publicOutput ($report.artifact.filename + '.enc')) *>> $buildLog
  if ($LASTEXITCODE) { throw 'Encrypted transfer failed' }
  Copy-Item -LiteralPath (Join-Path $privateOutput 'build-report.json'),(Join-Path $privateOutput 'SHA256SUMS') -Destination $publicOutput
  $passed = $true
} catch {
  $failure = @{ status='fail'; phase=$failurePhase; sourceRevision=$env:SOURCE_REVISION; productVersion=$env:PRODUCT_VERSION; runId=$env:BUILD_RUN_ID }
  $failure | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $publicOutput 'failure.json') -Encoding utf8
} finally {
  foreach ($file in @($key,$hosts)) { if (Test-Path -LiteralPath $file) { if ((Get-Item -LiteralPath $file).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected credential link' }; Remove-Item -LiteralPath $file } }
  $env:SOURCE_READ_KEY = $null
  $env:GIT_SSH_COMMAND = $null
  if ((Test-Path -LiteralPath (Join-Path $sourceRoot 'scripts/build-transfer.mjs')) -and (Test-Path -LiteralPath $buildLog)) {
    $diagnosticZip = Join-Path $privateOutput 'diagnostics.zip'
    $logFiles = @($bootstrapLog,$buildLog) + @(Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'output/github-build/private-evidence') -File -ErrorAction SilentlyContinue | Where-Object Extension -in @('.log','.json') | ForEach-Object FullName)
    if (Test-Path -LiteralPath $buildErrorLog) { $logFiles += $buildErrorLog }
    Compress-Archive -LiteralPath $logFiles -DestinationPath $diagnosticZip
    & node (Join-Path $sourceRoot 'scripts/build-transfer.mjs') encrypt $diagnosticZip (Join-Path $publicRoot 'build-transfer-public.pem') (Join-Path $publicOutput 'diagnostics.enc') *>> $buildLog
    if ($LASTEXITCODE) { throw 'Encrypted diagnostics failed' }
  }
  'passed=' + $passed.ToString().ToLowerInvariant() >> $env:GITHUB_OUTPUT
  @{status= $(if ($passed) {'pass'} else {'fail'}); phase=$failurePhase; sourceRevision=$env:SOURCE_REVISION; productVersion=$env:PRODUCT_VERSION; runId=$env:BUILD_RUN_ID} | ConvertTo-Json -Compress | Write-Output
}
if (-not $passed) { exit 1 }
