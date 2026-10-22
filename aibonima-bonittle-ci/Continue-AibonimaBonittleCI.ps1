[CmdletBinding()]
param(
    [string]$RepoFullName = "bailangserver-jpg/AIBONIMA-BONITTLE",
    [string]$RunnerName = "AIBONIMA-BONITTLE-GAMINGPC",
    [string]$CiRoot = "C:\AIBONIMA-CI",
    [string]$ExpectedRunSha = "c10f6efe119b7bf4badf4119db76fe8aa957e16a"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Stop-Resume {
    param([Parameter(Mandatory)][string]$Message)
    throw $Message
}

function Get-GhPath {
    $existing = Get-Command gh -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }

    $portableRoot = Join-Path $CiRoot "gh"
    $ghExe = Get-ChildItem -LiteralPath $portableRoot -Filter "gh.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName

    if (-not $ghExe) {
        Stop-Resume "GitHub CLI was not found. Expected it under $portableRoot."
    }
    return $ghExe
}

function Get-RunnerRecord {
    param(
        [Parameter(Mandatory)][string]$GhPath
    )

    $json = & $GhPath api "repos/$RepoFullName/actions/runners"
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        Stop-Resume "Failed to query repository runners."
    }

    $response = $json | ConvertFrom-Json
    return $response.runners |
        Where-Object { $_.name -eq $RunnerName } |
        Select-Object -First 1
}

Write-Host "=== AIBONIMA BONITTLE CI resume ==="

$gh = Get-GhPath
$runnerDir = Join-Path $CiRoot "runner"
$runnerConfig = Join-Path $runnerDir ".runner"
$runCmd = Join-Path $runnerDir "run.cmd"

if (-not (Test-Path -LiteralPath $runnerConfig -PathType Leaf)) {
    Stop-Resume "Local runner configuration is missing: $runnerConfig"
}
if (-not (Test-Path -LiteralPath $runCmd -PathType Leaf)) {
    Stop-Resume "Runner executable is missing: $runCmd"
}

$runner = Get-RunnerRecord -GhPath $gh
if (-not $runner) {
    Stop-Resume "GitHub does not contain the expected runner '$RunnerName'."
}

Write-Host "Runner registration : found"
Write-Host "Runner status       : $($runner.status)"

if ($runner.status -ne "online") {
    Write-Host "Starting the registered runner..."
    Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "run.cmd") -WorkingDirectory $runnerDir -WindowStyle Minimized
}

$online = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $runner = Get-RunnerRecord -GhPath $gh
    if ($runner -and $runner.status -eq "online") {
        $online = $true
        break
    }
}

if (-not $online) {
    Stop-Resume "Runner did not become online. Check $runnerDir\_diag."
}

Write-Host "Runner status       : online"

$startupFolder = [Environment]::GetFolderPath("Startup")
$startupCmd = Join-Path $startupFolder "AIBONIMA-BONITTLE-GitHub-Runner.cmd"
if (-not (Test-Path -LiteralPath $startupCmd -PathType Leaf)) {
    @"
@echo off
cd /d "$runnerDir"
start "" /min run.cmd
"@ | Set-Content -LiteralPath $startupCmd -Encoding ASCII
}
Write-Host "Autostart           : configured"

$run = $null
for ($i = 0; $i -lt 20 -and -not $run; $i++) {
    $runJson = & $gh run list `
        --repo $RepoFullName `
        --workflow "bonittle-unity-ci.yml" `
        --limit 10 `
        --json "databaseId,status,conclusion,url,headSha,event,createdAt"

    if ($LASTEXITCODE -eq 0 -and $runJson) {
        $runs = @($runJson | ConvertFrom-Json)
        $run = $runs |
            Where-Object { $_.headSha -eq $ExpectedRunSha } |
            Select-Object -First 1
    }

    if (-not $run) {
        Start-Sleep -Seconds 2
    }
}

if (-not $run) {
    Stop-Resume "Could not find the corrected CI run for commit $ExpectedRunSha."
}

Write-Host "Workflow            : $($run.url)"
Write-Host "Workflow status     : $($run.status)"
Write-Host "Waiting for Compile + EditMode + PlayMode verification..."

& $gh run watch $run.databaseId --repo $RepoFullName --exit-status
$watchExit = $LASTEXITCODE

Write-Host ""
if ($watchExit -eq 0) {
    Write-Host "=== RESULT: CI PASSED ==="
    Write-Host "Self-hosted automation is operational."
    exit 0
}

Write-Host "=== RESULT: CI FAILED ==="
Write-Host "Runner automation is operational, but one of the Unity verification gates failed."
Write-Host "The failure can now be inspected from GitHub Actions logs/artifacts without manual PowerShell copy/paste."
exit $watchExit
