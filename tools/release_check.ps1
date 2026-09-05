[CmdletBinding()]
param(
    [switch]$WorkingTree,
    [switch]$Runtime
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ($Runtime -and $env:OS -ne 'Windows_NT') {
    throw 'The automated window/runtime check currently supports Windows. Omit -Runtime for build validation.'
}
$compilerVersion = (& odin version | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not run the Odin compiler.' }
$sourceCommit = (& git -C $repositoryRoot rev-parse HEAD | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Run this check from a Rune Git checkout.' }
$workspace = Join-Path $repositoryRoot "build/release check $([Guid]::NewGuid().ToString('N'))"
$exportRoot = Join-Path $workspace 'Rune Engine'
$gameRoot = Join-Path $workspace 'New Game'
New-Item -ItemType Directory -Path $exportRoot -Force | Out-Null

function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code ${LASTEXITCODE}: $Executable" }
}

if ($WorkingTree) {
    Write-Warning 'Testing the working copy, including uncommitted files. This is not proof of the published commit.'
    $files = @(& git -C $repositoryRoot -c core.quotepath=false ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate candidate files.' }
    foreach ($relativePath in ($files | Sort-Object -Unique)) {
        $source = Join-Path $repositoryRoot $relativePath
        if (!(Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        $destination = Join-Path $exportRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination
    }
} else {
    $archive = Join-Path $workspace 'engine.zip'
    Invoke-Checked 'git' @('-C', $repositoryRoot, 'archive', '--format=zip', "--output=$archive", $sourceCommit)
    Expand-Archive -LiteralPath $archive -DestinationPath $exportRoot -Force
}

# Git archives omit submodule contents. Export the exact recorded dependency,
# using local objects so the check cannot silently fetch a different version.
$submodule = 'third_party/r3d-odin'
$dependencyRoot = Join-Path $repositoryRoot $submodule
if (!(Test-Path -LiteralPath (Join-Path $dependencyRoot 'r3d/r3d_core.odin'))) {
    throw 'Initialize dependencies with git submodule update --init --recursive.'
}
$dependencyCommit = if ($WorkingTree) {
    (& git -C $dependencyRoot rev-parse HEAD | Out-String).Trim()
} else {
    (& git -C $repositoryRoot rev-parse "${sourceCommit}:$submodule" | Out-String).Trim()
}
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the r3d dependency revision.' }
if ($WorkingTree -and @(& git -C $dependencyRoot status --porcelain).Count -gt 0) {
    throw 'The r3d submodule is dirty. Commit or discard its changes before exporting a release candidate.'
}
$dependencyArchive = Join-Path $workspace 'r3d.zip'
Invoke-Checked 'git' @('-C', $dependencyRoot, 'archive', '--format=zip', "--output=$dependencyArchive", $dependencyCommit)
Expand-Archive -LiteralPath $dependencyArchive -DestinationPath (Join-Path $exportRoot $submodule) -Force

$requiredFiles = @('toolchain.json', 'tools/new_project.ps1', 'templates/blank_project/build.ps1', 'docs/asset_credits.json')
foreach ($relativePath in $requiredFiles) {
    if (!(Test-Path -LiteralPath (Join-Path $exportRoot $relativePath))) {
        throw "The exported commit is missing $relativePath. Commit the release tooling, or use -WorkingTree to test it first."
    }
}
$toolchain = Get-Content -LiteralPath (Join-Path $exportRoot 'toolchain.json') -Raw | ConvertFrom-Json
if (!$compilerVersion.Contains($toolchain.odin_release)) {
    throw "Expected Odin $($toolchain.odin_release); found $compilerVersion"
}
if (!$compilerVersion.Contains($toolchain.tested_odin_version)) {
    Write-Warning "Compiler differs from the recorded tested revision: $($toolchain.tested_odin_version)"
}

$shell = (Get-Process -Id $PID).Path
Invoke-Checked $shell @('-NoProfile', '-File', (Join-Path $exportRoot 'tools/validate.ps1'), '-AllExamples')
& (Join-Path $exportRoot 'tools/new_project.ps1') -Path $gameRoot -Name 'Release Check Game'
Invoke-Checked $shell @('-NoProfile', '-File', (Join-Path $gameRoot 'build.ps1'), '-RuneRoot', $exportRoot)
Invoke-Checked (Join-Path $exportRoot 'build/project_validator.exe') @((Join-Path $gameRoot 'project.json'))
foreach ($relativePath in @('project.json', 'scenes/main.scene.json', 'input/default.input.json')) {
    $file = Join-Path $gameRoot $relativePath
    $document = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if (!(Test-Path -LiteralPath (Join-Path (Split-Path -Parent $file) $document.'$schema'))) {
        throw "Generated schema reference does not resolve: $relativePath"
    }
}

$runtimePassed = $false
if ($Runtime) {
    $inbox = Join-Path $gameRoot 'build/console'
    $gameProcess = Start-Process -FilePath (Join-Path $gameRoot 'build/game.exe') -ArgumentList '"--console-dir=build/console"' -WorkingDirectory $gameRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $workspace 'game.stdout.log') -RedirectStandardError (Join-Path $workspace 'game.stderr.log')
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (!(Test-Path -LiteralPath $inbox)) {
            if ($gameProcess.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw 'New project failed to start.' }
            Start-Sleep -Milliseconds 100
        }
        $consoleHelper = Join-Path $exportRoot 'tools/console.ps1'
        $status = & $consoleHelper -Directory $inbox -Command 'status' -Json | ConvertFrom-Json
        if (!$status.ok -or $status.data.recent_errors.Count -gt 0) { throw 'New project reported runtime errors.' }
        $capture = & $consoleHelper -Directory $inbox -Command 'capture build/first-frame.png' -Json | ConvertFrom-Json
        if (!$capture.ok -or !(Test-Path -LiteralPath $capture.data.path)) { throw 'New project capture failed.' }
        $runtimePassed = $true
    }
    finally {
        if (!$gameProcess.HasExited) {
            $gameProcess.CloseMainWindow() | Out-Null
            if (!$gameProcess.WaitForExit(5000)) { Stop-Process -Id $gameProcess.Id }
        }
    }
}

$credits = Get-Content -LiteralPath (Join-Path $exportRoot 'docs/asset_credits.json') -Raw | ConvertFrom-Json
$pendingCredits = @($credits.groups | Where-Object { $_.status -ne 'documented' })
$mediaExtensions = @('.png', '.jpg', '.jpeg', '.ttf', '.wav', '.mp3', '.ogg', '.obj', '.mtl', '.glb', '.gltf', '.hdr', '.fnt')
$uncoveredAssets = @()
Get-ChildItem -LiteralPath (Join-Path $exportRoot 'examples') -Recurse -File |
    Where-Object { $_.Extension.ToLowerInvariant() -in $mediaExtensions } |
    ForEach-Object {
        $relativePath = $_.FullName.Substring($exportRoot.Length + 1).Replace('\', '/')
        $covered = $false
        foreach ($group in $credits.groups) {
            foreach ($pattern in $group.paths) {
                if ($relativePath -like $pattern) { $covered = $true }
            }
        }
        if (!$covered) { $uncoveredAssets += $relativePath }
    }
$licensePresent = Test-Path -LiteralPath (Join-Path $exportRoot 'LICENSE')
$report = [ordered]@{
    source_commit = $sourceCommit
    source_mode = $(if ($WorkingTree) { 'working-tree' } else { 'committed' })
    dependency_commit = $dependencyCommit
    compiler = $compilerVersion
    engineering_passed = $true
    runtime_checked = $runtimePassed
    engine_license_present = $licensePresent
    asset_credit_groups_pending = @($pendingCredits.name)
    assets_without_credit_entry = @($uncoveredAssets)
    export_directory = $exportRoot
    project_directory = $gameRoot
}
$reportPath = Join-Path $workspace 'report.json'
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
Write-Host "Engineering checks passed. Report: $reportPath"
if (!$licensePresent -or $pendingCredits.Count -gt 0 -or $uncoveredAssets.Count -gt 0) {
    Write-Warning 'Publication prerequisites remain: engine licensing and/or asset credits. See docs/release.md.'
}
