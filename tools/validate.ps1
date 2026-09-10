#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$AllExamples,
    [switch]$Runtime
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$buildDirectory = Join-Path $repositoryRoot "build"
$r3dDirectory = Join-Path $repositoryRoot "third_party/r3d-odin"
$failures = [System.Collections.Generic.List[string]]::new()
$builtValidators = [System.Collections.Generic.List[string]]::new()
$executableSuffix = if ($IsWindows) { '.exe' } else { '' }
$runtimeValidators = @(
	'asset_validation',
    'terrain_validation',
    'skybox_validation', 'post_processing_validation', 'model_animation_validation', 'sprite_animation_validation',
    'particle_validation', 'component_features_validation', 'collider_2d_validation', 'polygon_2d_validation', 'resolution_validation', 'ui_validation',
    'window_validation', 'mixer_validation'
)
if ($Runtime -and $IsLinux -and !$env:DISPLAY -and !$env:WAYLAND_DISPLAY) {
    throw 'Runtime validation needs a display. On headless Linux, run under xvfb-run -a.'
}

New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
Push-Location $repositoryRoot

try {
    function Invoke-OdinBuild {
        param(
            [string]$Name,
            [string]$Package,
            [string[]]$Collections = @()
        )

        $arguments = @("build", $Package, "-collection:rune=rune", "-out:build/$Name$executableSuffix")
        $arguments += $Collections
        & odin @arguments
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("build $Name")
            return $false
        }
        Write-Host "PASS build $Name"
        if ($Name.EndsWith('_validation')) {
            $builtValidators.Add((Join-Path $buildDirectory "$Name$executableSuffix"))
        }
        return $true
    }

    Get-ChildItem "tools" -Directory | Sort-Object Name | ForEach-Object {
        $collections = @()
        if ($_.Name -in @("terrain_validation", "skybox_validation", "post_processing_validation", "r3d_cache_validation", "model_animation_validation")) {
            $collections += "-collection:r3d=third_party/r3d-odin"
        }
        Invoke-OdinBuild -Name $_.Name -Package $_.FullName -Collections $collections | Out-Null
    }

    $builtValidators | Sort-Object | ForEach-Object {
        & $_
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("run $([IO.Path]::GetFileNameWithoutExtension($_))")
        }
    }

    if ($Runtime) {
        foreach ($name in $runtimeValidators) {
            $executable = Join-Path $buildDirectory "$name$executableSuffix"
            if (!$builtValidators.Contains($executable)) { continue }
            $stdout = Join-Path $buildDirectory "$name.runtime.stdout.log"
            $stderr = Join-Path $buildDirectory "$name.runtime.stderr.log"
            $start = @{
                FilePath = $executable
                ArgumentList = '--runtime'
                WorkingDirectory = $repositoryRoot
                PassThru = $true
                RedirectStandardOutput = $stdout
                RedirectStandardError = $stderr
            }
            if ($IsWindows) { $start.WindowStyle = 'Hidden' }
            $process = Start-Process @start
            try {
                if (!$process.WaitForExit(90000)) {
                    $failures.Add("runtime $name timed out after 90 seconds")
                } elseif ($process.ExitCode -ne 0) {
                    $failures.Add("runtime $name (exit $($process.ExitCode))")
                } else {
                    Write-Host "PASS runtime $name"
                }
            } finally {
                if (!$process.HasExited) { $process.Kill($true) }
                $process.WaitForExit()
                $process.Dispose()
                Get-Content -LiteralPath $stdout, $stderr | Write-Host
            }
        }
    }

    $projectValidator = Join-Path $buildDirectory "project_validator$executableSuffix"
    if (Test-Path -LiteralPath $projectValidator) {
        $projectFiles = @(Get-ChildItem "examples/*/project.json")
        if (Test-Path "templates/blank_project/project.json") {
            $projectFiles += Get-Item "templates/blank_project/project.json"
        }
        $projectFiles | Sort-Object FullName | ForEach-Object {
            & $projectValidator $_.FullName
            if ($LASTEXITCODE -ne 0) {
                $failures.Add("validate $($_.FullName)")
            }
        }
    }

    Invoke-OdinBuild -Name "blank_project_template" -Package "templates/blank_project" | Out-Null
    Invoke-OdinBuild -Name "hello_world" -Package "examples/hello_world" | Out-Null

    $hasR3d = Test-Path (Join-Path $r3dDirectory "r3d")
    if ($hasR3d) {
        Invoke-OdinBuild -Name "hello_3d" -Package "examples/hello_3d" -Collections @("-collection:r3d=third_party/r3d-odin") | Out-Null
    } else {
        $failures.Add("r3d submodule is not initialized; run git submodule update --init --recursive")
    }

    if ($AllExamples) {
        Invoke-OdinBuild -Name "launcher" -Package "examples/launcher" | Out-Null
        $manifest = Get-Content "examples/examples.json" -Raw | ConvertFrom-Json
        foreach ($example in $manifest.examples) {
            $collections = @()
            foreach ($collection in $example.collections) {
                $collections += "-collection:$($collection.name)=$($collection.path)"
            }
            Invoke-OdinBuild -Name $example.path -Package "examples/$($example.path)" -Collections $collections | Out-Null
        }
    }
}
finally {
    Pop-Location
}

if ($failures.Count -gt 0) {
    Write-Error ("Validation failed:`n- " + ($failures -join "`n- "))
    exit 1
}

Write-Host "Rune validation passed."
