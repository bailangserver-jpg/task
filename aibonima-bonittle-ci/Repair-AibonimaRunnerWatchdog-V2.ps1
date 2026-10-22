$ErrorActionPreference = "Stop"

$repo = "bailangserver-jpg/AIBONIMA-BONITTLE"
$runnerName = "AIBONIMA-BONITTLE-GAMINGPC"
$runnerDir = "C:\AIBONIMA-CI\runner"
$ciRoot = "C:\AIBONIMA-CI"
$watchdogPath = Join-Path $ciRoot "Watch-AibonimaRunner.ps1"
$runnerLog = Join-Path $ciRoot "runner-live.log"

function Get-GhPath {
    $cmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $portable = Get-ChildItem -LiteralPath (Join-Path $ciRoot "gh") -Filter "gh.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName

    if (-not $portable) {
        throw "GitHub CLI was not found."
    }
    return $portable
}

function Get-RemoteRunner {
    param([Parameter(Mandatory)][string]$Gh)

    $json = & $Gh api "repos/$repo/actions/runners"
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        throw "Failed to query GitHub runner status."
    }

    $response = $json | ConvertFrom-Json
    return $response.runners |
        Where-Object { $_.name -eq $runnerName } |
        Select-Object -First 1
}

if (-not (Test-Path -LiteralPath (Join-Path $runnerDir "run.cmd") -PathType Leaf)) {
    throw "Runner installation is missing: $runnerDir"
}

$gh = Get-GhPath
$remote = Get-RemoteRunner -Gh $gh
if (-not $remote) {
    throw "Registered runner '$runnerName' was not found on GitHub."
}

Write-Host "GitHub runner status before repair: $($remote.status)"

$watchdogBody = @'
$ErrorActionPreference = "SilentlyContinue"
$runnerDir = "C:\AIBONIMA-CI\runner"
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "AIBONIMA_BONITTLE_RUNNER_WATCHDOG", [ref]$createdNew)

if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

try {
    while ($true) {
        $activeRunner = @(
            Get-Process -Name "Runner.Listener","Runner.Worker" -ErrorAction SilentlyContinue
        )

        if ($activeRunner.Count -eq 0) {
            Start-Process -FilePath "cmd.exe" `
                -WorkingDirectory $runnerDir `
                -ArgumentList "/c", "run.cmd" `
                -WindowStyle Hidden
            Start-Sleep -Seconds 20
        }
        else {
            Start-Sleep -Seconds 15
        }
    }
}
finally {
    if ($createdNew) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
'@

Set-Content -LiteralPath $watchdogPath -Value $watchdogBody -Encoding UTF8

$watchdogs = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -and
        $_.CommandLine -like "*Watch-AibonimaRunner.ps1*"
    }

foreach ($process in $watchdogs) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
}

# Stop only processes we can positively identify as belonging to this runner directory.
$runnerProcesses = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        ($_.Name -eq "Runner.Listener.exe" -or $_.Name -eq "Runner.Worker.exe") -and
        (
            ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($runnerDir, [StringComparison]::OrdinalIgnoreCase)) -or
            ($_.CommandLine -and $_.CommandLine -like "*$runnerDir*")
        )
    }

foreach ($process in $runnerProcesses) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
}

Start-Sleep -Seconds 2

Remove-Item -LiteralPath $runnerLog -Force -ErrorAction SilentlyContinue
$cmdLine = "call run.cmd >> `"$runnerLog`" 2>&1"
Start-Process -FilePath "cmd.exe" -WorkingDirectory $runnerDir -ArgumentList "/c", $cmdLine -WindowStyle Hidden

$online = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $remote = Get-RemoteRunner -Gh $gh
    Write-Host "GitHub runner status: $($remote.status)"
    if ($remote.status -eq "online") {
        $online = $true
        break
    }
}

if (-not $online) {
    Write-Host ""
    Write-Host "=== runner-live.log ==="
    if (Test-Path -LiteralPath $runnerLog) {
        Get-Content -LiteralPath $runnerLog -Tail 120
    }

    Write-Host ""
    Write-Host "=== latest runner diagnostic ==="
    $latestDiag = Get-ChildItem -LiteralPath (Join-Path $runnerDir "_diag") -Filter "Runner_*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($latestDiag) {
        Write-Host $latestDiag.FullName
        Get-Content -LiteralPath $latestDiag.FullName -Tail 120
    }

    throw "Runner did not become online on GitHub."
}

Start-Process -FilePath "pwsh.exe" `
    -ArgumentList "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$watchdogPath`"" `
    -WindowStyle Hidden

$startup = [Environment]::GetFolderPath("Startup")
$startupFile = Join-Path $startup "AIBONIMA-BONITTLE-Runner-Watchdog.cmd"
@"
@echo off
start "" /min pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$watchdogPath"
"@ | Set-Content -LiteralPath $startupFile -Encoding ASCII

Write-Host ""
Write-Host "AIBONIMA BONITTLE runner is ONLINE on GitHub."
Write-Host "Watchdog V2 is installed."
