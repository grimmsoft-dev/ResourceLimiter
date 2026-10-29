# Smoke-tests the packaged installer on every engine it has a prebuilt copy for.
#
#   .\Scripts\Test.ps1                  # after .\Scripts\Build.ps1
#   .\Scripts\Test.ps1 -Engines 5.0,5.6
#
# For each engine: makes a Blueprint-only test project, installs the plugin into it with the installer,
# opens it in a hidden editor that runs Test.py, and checks the log for the lines in TestConfig.json.

param([string[]]$Engines)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $Root 'Installer\UEEngines.ps1')

$Name = (Get-ChildItem $Root -Filter *.uplugin -Recurse -Depth 1 | Select-Object -First 1).BaseName
$Config = Get-Content (Join-Path $PSScriptRoot 'TestConfig.json') -Raw | ConvertFrom-Json
$Stage = Get-ChildItem (Join-Path $Root 'Build\Stage') -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $Stage) { throw 'Run .\Scripts\Build.ps1 first.' }
$Manifest = Get-Content (Join-Path $Stage.FullName 'manifest.json') -Raw | ConvertFrom-Json

$targets = @(Find-UE5Engines | Where-Object { $Manifest.Builds -contains $_.Version })
if ($Engines) { $targets = @($targets | Where-Object { $Engines -contains $_.Version }) }
$targets = @($targets | Group-Object Version | ForEach-Object { $_.Group[0] }) # one run per engine version

$results = foreach ($engine in $targets) {
    Write-Host "[$Name] Testing on UE $($engine.Patch)..."
    $dir = Join-Path $Root "Build\Test\UE$($engine.Version)"
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force (Join-Path $dir 'Content\Python'), (Join-Path $dir 'Config'), (Join-Path $dir 'Saved\Config\WindowsEditor') | Out-Null
    $project = Join-Path $dir 'TestProject.uproject'
    @{ FileVersion = 3; EngineAssociation = $engine.Version; Plugins = @(@{ Name = 'PythonScriptPlugin'; Enabled = $true }) } |
        ConvertTo-Json -Depth 4 | Out-File $project -Encoding ascii
    # Open an empty map instead of the default open-world template, which takes minutes to load.
    "[/Script/EngineSettings.GameMapsSettings]`r`nEditorStartupMap=/Engine/Maps/Entry" | Out-File (Join-Path $dir 'Config\DefaultEngine.ini') -Encoding ascii

    Copy-Item (Join-Path $PSScriptRoot 'Test.py') (Join-Path $dir 'Content\Python\init_unreal.py')
    Copy-Item (Join-Path $PSScriptRoot 'TestConfig.json') (Join-Path $dir 'Content\Python\TestConfig.json')
    if (Test-Path (Join-Path $PSScriptRoot 'TestChecks.py')) { Copy-Item (Join-Path $PSScriptRoot 'TestChecks.py') (Join-Path $dir 'Content\Python\') }
    if ($Config.Ini) {
        $ini = foreach ($section in $Config.Ini.PSObject.Properties) {
            "[$($section.Name)]"; foreach ($kv in $section.Value.PSObject.Properties) { "$($kv.Name)=$($kv.Value)" }
        }
        $ini | Out-File (Join-Path $dir 'Saved\Config\WindowsEditor\EditorPerProjectUserSettings.ini') -Encoding ascii
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Stage.FullName 'Install.ps1') -Project $project | Write-Host
    $installed = $LASTEXITCODE -eq 0

    # Before 5.1-ish, offscreen windows hit a Fatal in FGenericWindow::GetRestoredDimensions whenever a window
    # closes, so those engines get a real (briefly visible) editor window instead.
    $genericWindow = Join-Path $engine.Root 'Engine\Source\Runtime\ApplicationCore\Private\GenericPlatform\GenericWindow.cpp'
    $offscreen = if ((Test-Path $genericWindow) -and -not (Select-String -Path $genericWindow -Pattern 'RenderOffScreen' -Quiet)) { '' } else { ' -RenderOffscreen' }

    $editor = Join-Path $engine.Root 'Engine\Binaries\Win64\UnrealEditor.exe'
    $proc = Start-Process $editor -ArgumentList "`"$project`"$offscreen -nosound -unattended -nosplash -NoLoadStartupPackages" -PassThru
    if (-not $proc.WaitForExit(8 * 60 * 1000)) { $proc.Kill(); Write-Host '  Timed out.' }

    $log = Join-Path $dir 'Saved\Logs\TestProject.log'
    $text = if (Test-Path $log) { Get-Content $log -Raw } else { '' }
    $missing = @($Config.Expect | Where-Object { $text -notmatch $_ }) + @($Config.Forbid | Where-Object { $_ -and $text -match $_ } | ForEach-Object { "forbidden: $_" })
    # The D3D12 RHI can ensure on its swap chain under -RenderOffscreen; that's the test setup, not the plugin.
    $ensures = @([regex]::Matches($text, 'Ensure condition failed:[^\r\n]*') | Where-Object { $_.Value -notmatch 'RHI\\Private' }).Count
    $ok = $installed -and $text -match 'TEST done' -and -not $missing -and $ensures -eq 0
    Write-Host ("  " + $(if ($ok) { 'PASS' } else { "FAIL: missing [$($missing -join '; ')], ensures $ensures, log $log" }))
    [pscustomobject]@{ Engine = $engine.Version; Pass = $ok; Missing = ($missing -join '; '); Ensures = $ensures }
}
$results | Format-Table -AutoSize | Out-String | Write-Host
if ($results | Where-Object { -not $_.Pass }) { exit 1 }
