[CmdletBinding()]
param(
    [string]$ProjectPath = "C:\Dev\AIBONIMA-BONITTLE",
    [string]$RepoFullName = "bailangserver-jpg/AIBONIMA-BONITTLE",
    [string]$UnityExe = "C:\Program Files\Unity\Hub\Editor\6000.3.25f1\Editor\Unity.exe",
    [string]$CiRoot = "C:\AIBONIMA-CI",
    [string]$RunnerName = "AIBONIMA-BONITTLE-GAMINGPC"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$BootstrapCommit = "bc576d562e45a968a6fcde0b2aad6b8cc0c0c6c2"
$BootstrapBase = "https://raw.githubusercontent.com/bailangserver-jpg/task/$BootstrapCommit/aibonima-bonittle-ci"

function Stop-Setup {
    param([Parameter(Mandatory)][string]$Message)
    throw $Message
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory = $null
    )

    if ($WorkingDirectory) { Push-Location $WorkingDirectory }
    try {
        & $File @Arguments
        if ($LASTEXITCODE -ne 0) {
            Stop-Setup "$File failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        if ($WorkingDirectory) { Pop-Location }
    }
}

function Get-GhPath {
    $existing = Get-Command gh -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }

    $portableRoot = Join-Path $CiRoot "gh"
    $existingPortable = Get-ChildItem -LiteralPath $portableRoot -Filter "gh.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if ($existingPortable) { return $existingPortable }

    Write-Host "GitHub CLI not found. Installing a portable copy under $portableRoot ..."
    New-Item -ItemType Directory -Path $portableRoot -Force | Out-Null
    $downloads = Join-Path $CiRoot "downloads"
    New-Item -ItemType Directory -Path $downloads -Force | Out-Null

    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/cli/cli/releases/latest" -Headers @{
        "User-Agent" = "AIBONIMA-BONITTLE-CI-Setup"
    }
    $asset = $release.assets |
        Where-Object { $_.name -match '^gh_.*_windows_amd64\.zip$' } |
        Select-Object -First 1

    if (-not $asset) {
        Stop-Setup "Could not find the GitHub CLI Windows amd64 ZIP."
    }

    $zipPath = Join-Path $downloads $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
    Expand-Archive -LiteralPath $zipPath -DestinationPath $portableRoot -Force

    $ghExe = Get-ChildItem -LiteralPath $portableRoot -Filter "gh.exe" -Recurse |
        Select-Object -First 1 -ExpandProperty FullName

    if (-not $ghExe) { Stop-Setup "Portable GitHub CLI installation failed." }
    return $ghExe
}

Write-Host "=== AIBONIMA BONITTLE CI setup ==="
Write-Host "Project : $ProjectPath"
Write-Host "Repo    : $RepoFullName"
Write-Host "CI root : $CiRoot"
Write-Host ""

if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
    Stop-Setup "Project directory does not exist: $ProjectPath"
}
if (-not (Test-Path -LiteralPath $UnityExe -PathType Leaf)) {
    Stop-Setup "Unity executable does not exist: $UnityExe"
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Stop-Setup "git.exe was not found in PATH."
}
if (-not (Test-Path -LiteralPath (Join-Path $ProjectPath ".git") -PathType Container)) {
    Stop-Setup "ProjectPath is not a Git repository: $ProjectPath"
}

$branch = (& git -C $ProjectPath branch --show-current).Trim()
if ($LASTEXITCODE -ne 0) { Stop-Setup "Failed to read current Git branch." }
if ($branch -ne "main") {
    Stop-Setup "Initial setup must run from local branch 'main'. Current branch: '$branch'."
}

$ciPaths = @(
    ".github/workflows/bonittle-unity-ci.yml",
    "Tools/CI/Invoke-AibonimaUnityCI.ps1"
)

$preExistingCiChanges = @(& git -C $ProjectPath status --porcelain=v1 -- $ciPaths)
if ($LASTEXITCODE -ne 0) { Stop-Setup "Failed to inspect CI file paths." }
if ($preExistingCiChanges.Count -gt 0) {
    Write-Host "Existing changes already exist in CI target paths:"
    $preExistingCiChanges | ForEach-Object { Write-Host "  $_" }
    Stop-Setup "Refusing to overwrite existing CI-file work."
}

$preStaged = @(& git -C $ProjectPath diff --cached --name-only)
if ($LASTEXITCODE -ne 0) { Stop-Setup "Failed to inspect staged Git changes." }
if ($preStaged.Count -gt 0) {
    Write-Host "Existing staged files:"
    $preStaged | ForEach-Object { Write-Host "  $_" }
    Stop-Setup "There are already staged changes. Setup will not mix them into the CI commit."
}

New-Item -ItemType Directory -Path $CiRoot -Force | Out-Null

$gh = Get-GhPath

& $gh auth status --hostname github.com *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "One-time GitHub browser authentication is required."
    Invoke-Checked -File $gh -Arguments @(
        "auth", "login",
        "--hostname", "github.com",
        "--git-protocol", "https",
        "--web",
        "--scopes", "repo,workflow"
    )
} else {
    Write-Host "GitHub CLI authentication already exists."
}

Invoke-Checked -File $gh -Arguments @("auth", "setup-git")

$login = (& $gh api user --jq ".login").Trim()
if ($LASTEXITCODE -ne 0) { Stop-Setup "Could not read authenticated GitHub account." }
if ($login -ne "bailangserver-jpg") {
    Stop-Setup "Authenticated GitHub account is '$login', expected 'bailangserver-jpg'."
}

& $gh repo view $RepoFullName --json "nameWithOwner,isPrivate" *> $null
$repoExists = ($LASTEXITCODE -eq 0)

if (-not $repoExists) {
    Write-Host "Creating private repository $RepoFullName ..."
    Invoke-Checked -File $gh -Arguments @(
        "repo", "create", $RepoFullName,
        "--private",
        "--description", "AIBONIMA BONITTLE - lane command battle project"
    )
} else {
    $isPrivate = (& $gh repo view $RepoFullName --json "isPrivate" --jq ".isPrivate").Trim()
    if ($isPrivate -ne "true") {
        Stop-Setup "Repository exists but is not private. Refusing to attach a self-hosted runner."
    }
    Write-Host "Private repository already exists: $RepoFullName"
}

Write-Host "Applying GitHub Actions permission restrictions..."
Invoke-Checked -File $gh -Arguments @(
    "api", "--method", "PUT",
    "repos/$RepoFullName/actions/permissions",
    "-F", "enabled=true",
    "-f", "allowed_actions=selected"
)
Invoke-Checked -File $gh -Arguments @(
    "api", "--method", "PUT",
    "repos/$RepoFullName/actions/permissions/selected-actions",
    "-F", "github_owned_allowed=true",
    "-F", "verified_allowed=false"
)
Invoke-Checked -File $gh -Arguments @(
    "api", "--method", "PUT",
    "repos/$RepoFullName/actions/permissions/workflow",
    "-f", "default_workflow_permissions=read",
    "-F", "can_approve_pull_request_reviews=false"
)

Write-Host "Installing pinned CI files into the BONITTLE project..."
$workflowDest = Join-Path $ProjectPath ".github\workflows\bonittle-unity-ci.yml"
$scriptDest = Join-Path $ProjectPath "Tools\CI\Invoke-AibonimaUnityCI.ps1"
New-Item -ItemType Directory -Path (Split-Path -Parent $workflowDest) -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $scriptDest) -Force | Out-Null

Invoke-WebRequest -Uri "$BootstrapBase/bonittle-unity-ci.yml" -OutFile $workflowDest
Invoke-WebRequest -Uri "$BootstrapBase/Invoke-AibonimaUnityCI.ps1" -OutFile $scriptDest

if (-not (Test-Path -LiteralPath $workflowDest -PathType Leaf)) {
    Stop-Setup "Workflow download failed."
}
if (-not (Test-Path -LiteralPath $scriptDest -PathType Leaf)) {
    Stop-Setup "CI script download failed."
}

Invoke-Checked -File "git" -Arguments @(
    "-C", $ProjectPath, "add", "--",
    ".github/workflows/bonittle-unity-ci.yml",
    "Tools/CI/Invoke-AibonimaUnityCI.ps1"
)

$staged = @(& git -C $ProjectPath diff --cached --name-only)
$unexpectedStaged = @($staged | Where-Object {
    $_ -notin @(
        ".github/workflows/bonittle-unity-ci.yml",
        "Tools/CI/Invoke-AibonimaUnityCI.ps1"
    )
})
if ($unexpectedStaged.Count -gt 0) {
    Stop-Setup "Unexpected files became staged: $($unexpectedStaged -join ', ')"
}

if ($staged.Count -gt 0) {
    Invoke-Checked -File "git" -Arguments @(
        "-C", $ProjectPath,
        "commit", "-m", "Add secure self-hosted Unity CI", "--",
        ".github/workflows/bonittle-unity-ci.yml",
        "Tools/CI/Invoke-AibonimaUnityCI.ps1"
    )
} else {
    Write-Host "CI files already match committed content."
}

$targetRemote = "https://github.com/$RepoFullName.git"
$originOutput = & git -C $ProjectPath remote get-url origin 2>$null
$hasOrigin = ($LASTEXITCODE -eq 0)

if ($hasOrigin) {
    $origin = $originOutput.Trim()
    $normalizedOrigin = $origin -replace '^git@github\.com:', 'https://github.com/' -replace '\.git$',''
    $normalizedTarget = $targetRemote -replace '\.git$',''

    if ($normalizedOrigin -ne $normalizedTarget) {
        $legacyName = "legacy-origin"
        $counter = 1
        $remoteNames = @(& git -C $ProjectPath remote)
        while ($remoteNames -contains $legacyName) {
            $legacyName = "legacy-origin-$counter"
            $counter++
        }
        Write-Host "Preserving old origin '$origin' as '$legacyName'."
        Invoke-Checked -File "git" -Arguments @("-C", $ProjectPath, "remote", "rename", "origin", $legacyName)
        Invoke-Checked -File "git" -Arguments @("-C", $ProjectPath, "remote", "add", "origin", $targetRemote)
    }
} else {
    Invoke-Checked -File "git" -Arguments @("-C", $ProjectPath, "remote", "add", "origin", $targetRemote)
}

Write-Host "Pushing main to dedicated BONITTLE repository (no force push)..."
Invoke-Checked -File "git" -Arguments @("-C", $ProjectPath, "push", "-u", "origin", "main")

$headSha = (& git -C $ProjectPath rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or -not $headSha) {
    Stop-Setup "Could not determine pushed HEAD SHA."
}

$runnerDir = Join-Path $CiRoot "runner"
New-Item -ItemType Directory -Path $runnerDir -Force | Out-Null
$runnerConfig = Join-Path $runnerDir ".runner"

if (-not (Test-Path -LiteralPath $runnerConfig -PathType Leaf)) {
    $configCmd = Join-Path $runnerDir "config.cmd"

    if (-not (Test-Path -LiteralPath $configCmd -PathType Leaf)) {
        $existingRunnerFiles = @(Get-ChildItem -LiteralPath $runnerDir -Force)
        if ($existingRunnerFiles.Count -gt 0) {
            Stop-Setup "Runner directory is non-empty but not configured. Refusing to delete it: $runnerDir"
        }

        Write-Host "Downloading latest GitHub Actions runner..."
        $releaseJson = & $gh api "repos/actions/runner/releases/latest"
        if ($LASTEXITCODE -ne 0) {
            Stop-Setup "Failed to query latest GitHub Actions runner."
        }
        $release = $releaseJson | ConvertFrom-Json
        $asset = $release.assets |
            Where-Object { $_.name -match '^actions-runner-win-x64-.*\.zip$' } |
            Select-Object -First 1

        if (-not $asset) { Stop-Setup "Could not find Windows x64 runner ZIP." }

        $downloads = Join-Path $CiRoot "downloads"
        New-Item -ItemType Directory -Path $downloads -Force | Out-Null
        $runnerZip = Join-Path $downloads $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $runnerZip
        Expand-Archive -LiteralPath $runnerZip -DestinationPath $runnerDir -Force
    }

    $remoteRunner = & $gh api "repos/$RepoFullName/actions/runners" --jq ".runners[] | select(.name==\"$RunnerName\") | [.id,.status] | @tsv"
    if ($LASTEXITCODE -eq 0 -and $remoteRunner) {
        Stop-Setup "GitHub already has a runner named '$RunnerName', but local configuration is missing. Refusing to replace it automatically."
    }

    $registrationToken = (& $gh api --method POST "repos/$RepoFullName/actions/runners/registration-token" --jq ".token").Trim()
    if ($LASTEXITCODE -ne 0 -or -not $registrationToken) {
        Stop-Setup "Failed to obtain one-time runner registration token."
    }

    try {
        Push-Location $runnerDir
        & $configCmd `
            --url "https://github.com/$RepoFullName" `
            --token $registrationToken `
            --name $RunnerName `
            --work "_work" `
            --labels "aibonima-bonittle,unity-6000.3.25f1" `
            --unattended

        if ($LASTEXITCODE -ne 0) {
            Stop-Setup "GitHub Actions runner configuration failed."
        }
    }
    finally {
        $registrationToken = $null
        Pop-Location
    }
} else {
    Write-Host "Local runner is already configured."
}

$startupFolder = [Environment]::GetFolderPath("Startup")
$startupCmd = Join-Path $startupFolder "AIBONIMA-BONITTLE-GitHub-Runner.cmd"
@"
@echo off
cd /d "$runnerDir"
start "" /min run.cmd
"@ | Set-Content -LiteralPath $startupCmd -Encoding ASCII

$currentStatus = (& $gh api "repos/$RepoFullName/actions/runners" --jq ".runners[] | select(.name==\"$RunnerName\") | .status").Trim()
if ($currentStatus -ne "online") {
    Write-Host "Starting runner with normal user privileges..."
    Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "run.cmd") -WorkingDirectory $runnerDir -WindowStyle Minimized
}

Write-Host "Waiting for runner online status..."
$online = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 2
    $status = (& $gh api "repos/$RepoFullName/actions/runners" --jq ".runners[] | select(.name==\"$RunnerName\") | .status").Trim()
    if ($status -eq "online") {
        $online = $true
        break
    }
}
if (-not $online) {
    Stop-Setup "Runner registered but did not become online. Check '$runnerDir\_diag'."
}

Write-Host "Runner is online."

$run = $null
Write-Host "Locating the CI run for pushed HEAD $headSha ..."
for ($i = 0; $i -lt 20 -and -not $run; $i++) {
    Start-Sleep -Seconds 2
    $runJson = & $gh run list `
        --repo $RepoFullName `
        --workflow "bonittle-unity-ci.yml" `
        --branch "main" `
        --limit 10 `
        --json "databaseId,event,status,conclusion,url,headSha,createdAt"

    if ($LASTEXITCODE -eq 0 -and $runJson) {
        $runs = @($runJson | ConvertFrom-Json)
        $run = $runs |
            Where-Object { $_.headSha -eq $headSha -and $_.event -eq "push" } |
            Select-Object -First 1
    }
}

if (-not $run) {
    Write-Host "No push-triggered run found. Starting one explicit workflow_dispatch run."
    Invoke-Checked -File $gh -Arguments @(
        "workflow", "run", "bonittle-unity-ci.yml",
        "--repo", $RepoFullName,
        "--ref", "main"
    )

    for ($i = 0; $i -lt 20 -and -not $run; $i++) {
        Start-Sleep -Seconds 2
        $runJson = & $gh run list `
            --repo $RepoFullName `
            --workflow "bonittle-unity-ci.yml" `
            --branch "main" `
            --limit 10 `
            --json "databaseId,event,status,conclusion,url,headSha,createdAt"

        if ($LASTEXITCODE -eq 0 -and $runJson) {
            $runs = @($runJson | ConvertFrom-Json)
            $run = $runs |
                Where-Object { $_.headSha -eq $headSha -and $_.event -eq "workflow_dispatch" } |
                Select-Object -First 1
        }
    }
}

if (-not $run) {
    Stop-Setup "Runner is online, but first workflow run could not be found."
}

Write-Host "Workflow run: $($run.url)"
Write-Host "Watching initial verification..."
& $gh run watch $run.databaseId --repo $RepoFullName --exit-status
$watchExit = $LASTEXITCODE

Write-Host ""
Write-Host "=== Setup result ==="
Write-Host "Repository : https://github.com/$RepoFullName"
Write-Host "Runner     : $RunnerName"
Write-Host "Work dir   : $runnerDir\_work"
Write-Host "Autostart  : $startupCmd"
Write-Host "Workflow   : $($run.url)"

if ($watchExit -eq 0) {
    Write-Host "First CI   : PASSED"
    exit 0
}

Write-Host "First CI   : FAILED"
Write-Host "Automation is installed. The failure is now a normal CI failure to inspect in GitHub logs/artifacts."
exit $watchExit
