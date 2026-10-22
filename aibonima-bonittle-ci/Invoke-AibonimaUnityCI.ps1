[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ProjectPath = $env:GITHUB_WORKSPACE,

    [Parameter(Mandatory = $false)]
    [string]$UnityExe = "C:\Program Files\Unity\Hub\Editor\6000.3.25f1\Editor\Unity.exe",

    [Parameter(Mandatory = $false)]
    [int]$MinEditModeTests = 4,

    [Parameter(Mandatory = $false)]
    [int]$MinPlayModeTests = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ExpectedRepository = "bailangserver-jpg/AIBONIMA-BONITTLE"
$RequiredScenes = @(
    "Assets\Scenes\TitleMenu.unity",
    "Assets\Scenes\Battle.unity"
)

$artifactDir = $null
$failure = $null
$summary = [ordered]@{
    repository = $env:GITHUB_REPOSITORY
    ref = $env:GITHUB_REF
    sha = $env:GITHUB_SHA
    runner = $env:RUNNER_NAME
    startedAtUtc = [DateTime]::UtcNow.ToString("o")
    finishedAtUtc = $null
    status = "Running"
    compile = [ordered]@{
        result = $null
        exitCode = $null
        log = $null
    }
    editMode = [ordered]@{
        result = $null
        total = $null
        passed = $null
        failed = $null
        skipped = $null
        inconclusive = $null
        exitCode = $null
        log = $null
        xml = $null
    }
    playMode = [ordered]@{
        result = $null
        total = $null
        passed = $null
        failed = $null
        skipped = $null
        inconclusive = $null
        exitCode = $null
        log = $null
        xml = $null
    }
    scenes = @()
    git = [ordered]@{
        before = @()
        after = @()
        clean = $null
    }
    error = $null
}

function Resolve-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path).TrimEnd('\')
}

function Assert-RepositoryContext {
    param([Parameter(Mandatory)][string]$ResolvedProjectPath)

    if ($env:GITHUB_REPOSITORY -and $env:GITHUB_REPOSITORY -ne $ExpectedRepository) {
        throw "Refusing to run: repository '$($env:GITHUB_REPOSITORY)' is not '$ExpectedRepository'."
    }

    if ($env:GITHUB_REF) {
        $allowedRef =
            ($env:GITHUB_REF -eq "refs/heads/main") -or
            ($env:GITHUB_REF -like "refs/heads/chatgpt/*")

        if (-not $allowedRef) {
            throw "Refusing to run on disallowed ref '$($env:GITHUB_REF)'."
        }
    }

    if ($env:RUNNER_WORKSPACE) {
        $resolvedRunnerWorkspace = Resolve-NormalizedPath -Path $env:RUNNER_WORKSPACE
        $workspacePrefix = $resolvedRunnerWorkspace + "\"
        if (-not $ResolvedProjectPath.StartsWith($workspacePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Project path must stay under RUNNER_WORKSPACE. Project='$ResolvedProjectPath', RunnerWorkspace='$resolvedRunnerWorkspace'."
        }
    }
}

function Get-GitStatus {
    param([Parameter(Mandatory)][string]$ResolvedProjectPath)

    $output = & git -C $ResolvedProjectPath status --porcelain=v1 --untracked-files=all 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git status failed: $($output -join [Environment]::NewLine)"
    }
    return @($output)
}

function Invoke-UnityProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $UnityExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    foreach ($arg in $Arguments) {
        [void]$psi.ArgumentList.Add($arg)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi

    Write-Host "[$Name] Starting Unity..."
    if (-not $process.Start()) {
        throw "[$Name] Failed to start Unity."
    }

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try {
            $process.Kill($true)
            $process.WaitForExit(10000) | Out-Null
        } catch {
            Write-Warning "[$Name] Failed to terminate timed-out Unity process: $($_.Exception.Message)"
        }
        throw "[$Name] Timed out after $TimeoutSeconds seconds."
    }

    Write-Host "[$Name] Unity exit code: $($process.ExitCode)"
    return $process.ExitCode
}

function Assert-NoCompilerErrors {
    param([Parameter(Mandatory)][string]$LogPath)

    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        throw "Compile log was not created: $LogPath"
    }

    $patterns = @(
        '(?im)^\s*error\s+CS\d+\s*:',
        '(?im)Scripts have compiler errors',
        '(?im)Compilation failed',
        '(?im)Aborting batchmode due to failure',
        '(?im)Unhandled Exception'
    )

    $log = Get-Content -LiteralPath $LogPath -Raw
    foreach ($pattern in $patterns) {
        if ($log -match $pattern) {
            throw "Compiler/fatal error pattern found in compile log: $pattern"
        }
    }
}

function Read-TestResult {
    param(
        [Parameter(Mandatory)][string]$ResultPath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$MinimumTests
    )

    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        throw "[$Name] Test result XML was not created: $ResultPath"
    }

    [xml]$xml = Get-Content -LiteralPath $ResultPath -Raw
    $root = $xml.'test-run'
    if ($null -eq $root) {
        throw "[$Name] Unsupported or empty Unity test result XML."
    }

    $total = [int]$root.total
    $passed = [int]$root.passed
    $failed = [int]$root.failed
    $skipped = [int]$root.skipped
    $inconclusive = [int]$root.inconclusive
    $result = [string]$root.result

    if ($total -lt $MinimumTests) {
        throw "[$Name] Only $total tests ran; minimum required is $MinimumTests."
    }

    if ($failed -ne 0 -or $result -ne "Passed") {
        throw "[$Name] Tests failed. Result=$result Total=$total Passed=$passed Failed=$failed Skipped=$skipped Inconclusive=$inconclusive"
    }

    return [ordered]@{
        result = $result
        total = $total
        passed = $passed
        failed = $failed
        skipped = $skipped
        inconclusive = $inconclusive
    }
}

try {
    if (-not $ProjectPath) {
        throw "ProjectPath is empty."
    }
    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
        throw "Unity project directory does not exist: $ProjectPath"
    }
    if (-not (Test-Path -LiteralPath $UnityExe -PathType Leaf)) {
        throw "Unity executable does not exist: $UnityExe"
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git.exe was not found in PATH."
    }

    $resolvedProject = Resolve-NormalizedPath -Path $ProjectPath
    Assert-RepositoryContext -ResolvedProjectPath $resolvedProject

    foreach ($required in @(
        "Assets",
        "Packages\manifest.json",
        "ProjectSettings\ProjectVersion.txt"
    )) {
        $candidate = Join-Path $resolvedProject $required
        if (-not (Test-Path -LiteralPath $candidate)) {
            throw "Required Unity project item is missing: $required"
        }
    }

    if ($env:AIBONIMA_CI_ARTIFACT_DIR) {
        $artifactDir = [System.IO.Path]::GetFullPath($env:AIBONIMA_CI_ARTIFACT_DIR)
    } else {
        $artifactDir = Join-Path ([System.IO.Path]::GetTempPath()) ("AIBONIMA-BONITTLE-CI-" + [Guid]::NewGuid().ToString("N"))
    }
    New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null

    $beforeStatus = @(Get-GitStatus -ResolvedProjectPath $resolvedProject)
    $summary["git"]["before"] = $beforeStatus
    if ($beforeStatus.Count -ne 0) {
        $beforePath = Join-Path $artifactDir "git-status-before.txt"
        $beforeStatus | Set-Content -LiteralPath $beforePath -Encoding UTF8
        throw "CI checkout is not clean before Unity execution. Refusing to delete or overwrite unknown files."
    }

    foreach ($scene in $RequiredScenes) {
        $scenePath = Join-Path $resolvedProject $scene
        $metaPath = $scenePath + ".meta"
        if (-not (Test-Path -LiteralPath $scenePath -PathType Leaf)) {
            throw "Required scene is missing: $scene"
        }
        if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
            throw "Required scene meta file is missing: $scene.meta"
        }
        $summary["scenes"] += $scene
    }

    $compileLog = Join-Path $artifactDir "compile-editor.log"
    $compileArgs = @(
        "-batchmode",
        "-nographics",
        "-quit",
        "-projectPath", $resolvedProject,
        "-logFile", $compileLog,
        "-stackTraceLogType", "Full"
    )
    $compileExit = Invoke-UnityProcess -Name "Compile" -Arguments $compileArgs -TimeoutSeconds 900
    $summary["compile"]["exitCode"] = $compileExit
    $summary["compile"]["log"] = [System.IO.Path]::GetFileName($compileLog)
    if ($compileExit -ne 0) {
        throw "[Compile] Unity returned exit code $compileExit."
    }
    Assert-NoCompilerErrors -LogPath $compileLog
    $summary["compile"]["result"] = "Passed"

    $editXml = Join-Path $artifactDir "editmode-test-results.xml"
    $editLog = Join-Path $artifactDir "editmode-editor.log"
    $editArgs = @(
        "-batchmode",
        "-nographics",
        "-projectPath", $resolvedProject,
        "-runTests",
        "-testPlatform", "EditMode",
        "-testResults", $editXml,
        "-logFile", $editLog,
        "-stackTraceLogType", "Full"
    )
    $editExit = Invoke-UnityProcess -Name "EditMode" -Arguments $editArgs -TimeoutSeconds 1200
    $editResult = Read-TestResult -ResultPath $editXml -Name "EditMode" -MinimumTests $MinEditModeTests
    foreach ($key in $editResult.Keys) {
        $summary["editMode"][$key] = $editResult[$key]
    }
    $summary["editMode"]["exitCode"] = $editExit
    $summary["editMode"]["log"] = [System.IO.Path]::GetFileName($editLog)
    $summary["editMode"]["xml"] = [System.IO.Path]::GetFileName($editXml)
    if ($editExit -ne 0) {
        throw "[EditMode] Unity returned exit code $editExit even though a result XML was produced."
    }

    $playXml = Join-Path $artifactDir "playmode-test-results.xml"
    $playLog = Join-Path $artifactDir "playmode-editor.log"
    $playArgs = @(
        "-batchmode",
        "-projectPath", $resolvedProject,
        "-runTests",
        "-testPlatform", "PlayMode",
        "-testResults", $playXml,
        "-logFile", $playLog,
        "-stackTraceLogType", "Full"
    )
    $playExit = Invoke-UnityProcess -Name "PlayMode" -Arguments $playArgs -TimeoutSeconds 1500
    $playResult = Read-TestResult -ResultPath $playXml -Name "PlayMode" -MinimumTests $MinPlayModeTests
    foreach ($key in $playResult.Keys) {
        $summary["playMode"][$key] = $playResult[$key]
    }
    $summary["playMode"]["exitCode"] = $playExit
    $summary["playMode"]["log"] = [System.IO.Path]::GetFileName($playLog)
    $summary["playMode"]["xml"] = [System.IO.Path]::GetFileName($playXml)
    if ($playExit -ne 0) {
        throw "[PlayMode] Unity returned exit code $playExit even though a result XML was produced."
    }

    $afterStatus = @(Get-GitStatus -ResolvedProjectPath $resolvedProject)
    $summary["git"]["after"] = $afterStatus
    $summary["git"]["clean"] = ($afterStatus.Count -eq 0)

    $afterPath = Join-Path $artifactDir "git-status-after.txt"
    if ($afterStatus.Count -eq 0) {
        "CLEAN" | Set-Content -LiteralPath $afterPath -Encoding UTF8
    } else {
        $afterStatus | Set-Content -LiteralPath $afterPath -Encoding UTF8
        throw "Unity/test execution changed the checked-out repository. CI will not auto-delete, auto-commit, or auto-push these changes."
    }

    $summary["status"] = "Passed"
}
catch {
    $failure = $_
    $summary["status"] = "Failed"
    $summary["error"] = $_.Exception.Message
}
finally {
    $summary["finishedAtUtc"] = [DateTime]::UtcNow.ToString("o")

    if (-not $artifactDir) {
        $artifactDir = Join-Path ([System.IO.Path]::GetTempPath()) ("AIBONIMA-BONITTLE-CI-" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
    }

    $summaryPath = Join-Path $artifactDir "ci-summary.json"
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    Write-Host "CI summary: $summaryPath"
    Write-Host "CI status: $($summary["status"])"
}

if ($null -ne $failure) {
    Write-Error $failure.Exception.Message
    exit 1
}

exit 0
