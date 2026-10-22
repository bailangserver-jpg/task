$ErrorActionPreference = "Stop"

$runnerDir = "C:\AIBONIMA-CI\runner"
$watchdogPath = "C:\AIBONIMA-CI\Watch-AibonimaRunner.ps1"

if (-not (Test-Path -LiteralPath (Join-Path $runnerDir "run.cmd") -PathType Leaf)) {
    throw "AIBONIMA BONITTLE runner was not found: $runnerDir"
}

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
        $activeRunner = Get-CimInstance Win32_Process |
            Where-Object {
                if ($_.Name -ne "Runner.Listener.exe" -and $_.Name -ne "Runner.Worker.exe") {
                    return $false
                }

                if ($_.ExecutablePath) {
                    return $_.ExecutablePath.StartsWith($runnerDir, [StringComparison]::OrdinalIgnoreCase)
                }

                if ($_.CommandLine) {
                    return $_.CommandLine -like "*$runnerDir*"
                }

                return $true
            }

        if (-not $activeRunner) {
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

$existingWatchdogs = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
    Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -and
        $_.CommandLine -like "*Watch-AibonimaRunner.ps1*"
    }

foreach ($process in $existingWatchdogs) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
}

$runnerProcesses = Get-CimInstance Win32_Process |
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

Start-Process -FilePath "cmd.exe" `
    -WorkingDirectory $runnerDir `
    -ArgumentList "/c", "run.cmd" `
    -WindowStyle Hidden

Start-Sleep -Seconds 3

Start-Process -FilePath "pwsh.exe" `
    -ArgumentList "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$watchdogPath`"" `
    -WindowStyle Hidden

$startup = [Environment]::GetFolderPath("Startup")
$startupFile = Join-Path $startup "AIBONIMA-BONITTLE-Runner-Watchdog.cmd"
@"
@echo off
start "" /min pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$watchdogPath"
"@ | Set-Content -LiteralPath $startupFile -Encoding ASCII

Start-Sleep -Seconds 3

$listener = Get-CimInstance Win32_Process -Filter "Name='Runner.Listener.exe'" |
    Where-Object {
        ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($runnerDir, [StringComparison]::OrdinalIgnoreCase)) -or
        ($_.CommandLine -and $_.CommandLine -like "*$runnerDir*")
    }

if (-not $listener) {
    Write-Warning "Runner listener could not be confirmed yet. The watchdog is installed and will continue retrying."
}
else {
    Write-Host "AIBONIMA BONITTLE runner is online locally and the watchdog was repaired."
}
