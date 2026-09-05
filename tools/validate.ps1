[CmdletBinding()]
param(
    [switch]$AllExamples
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$buildDirectory = Join-Path $repositoryRoot "build"
$r3dDirectory = Join-Path $repositoryRoot "third_party/r3d-odin"
$failures = [System.Collections.Generic.List[string]]::new()
$builtValidators = [System.Collections.Generic.List[string]]::new()

New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
Push-Location $repositoryRoot

try {
    function Invoke-OdinBuild {
        param(
            [string]$Name,
            [string]$Package,
            [string[]]$Collections = @()
        )

        $arguments = @("build", $Package, "-collection:rune=rune", "-out:build/$Name.exe")
        $arguments += $Collections
        & odin @arguments
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("build $Name")
            return $false
        }
        Write-Host "PASS build $Name"
        if ($Name.EndsWith('_validation')) {
            $builtValidators.Add((Join-Path $buildDirectory "$Name.exe"))
        }
        return $true
    }

    Get-ChildItem "tools" -Directory | Sort-Object Name | ForEach-Object {
        $collections = @()
        if ($_.Name -in @("r3d_cache_validation", "model_animation_validation")) {
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

    if (Test-Path "build/project_validator.exe") {
        $projectFiles = @(Get-ChildItem "examples/*/project.json")
        if (Test-Path "templates/blank_project/project.json") {
            $projectFiles += Get-Item "templates/blank_project/project.json"
        }
        $projectFiles | Sort-Object FullName | ForEach-Object {
            & "build/project_validator.exe" $_.FullName
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
