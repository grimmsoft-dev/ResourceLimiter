# Builds the plugin for every installed UE5 engine and packages the installer zip.
#
#   .\Scripts\Build.ps1                  # all installed UE5 engines
#   .\Scripts\Build.ps1 -Engines 5.4,5.6 # just these
#   .\Scripts\Build.ps1 -PackageOnly     # re-zip existing builds
#
# Output: Build\UE<ver>\<Plugin> (packaged plugin per engine), Build\Logs, Dist\<Plugin>-<version>-Installer.zip

param(
    [string[]]$Engines,
    [switch]$PackageOnly
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $Root 'Installer\UEEngines.ps1')

$PluginFile = Get-ChildItem $Root -Filter *.uplugin -Recurse -Depth 1 | Select-Object -First 1
$Name = $PluginFile.BaseName
$PluginDir = $PluginFile.DirectoryName
$Descriptor = Get-Content $PluginFile.FullName -Raw | ConvertFrom-Json
$Version = $Descriptor.VersionName
$BuildDir = Join-Path $Root 'Build'
$LogDir = Join-Path $BuildDir 'Logs'
New-Item -ItemType Directory -Force $LogDir | Out-Null

if (-not $PackageOnly) {
    $all = @(Find-UE5Engines | Where-Object Installed)
    if ($Engines) { $all = @($all | Where-Object { $Engines -contains $_.Version }) }
    $all = @($all | Group-Object Version | ForEach-Object { $_.Group[0] }) # one build per engine version
    if (-not $all) { throw 'No matching UE5 engine installs found.' }

    # UE 5.0-5.3 don't compile with the newest MSVC; pin them to the newest 14.3x toolchain installed (14.36 is Epic's pick).
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $msvc = @(& $vswhere -products * -property installationPath | ForEach-Object { Get-ChildItem (Join-Path $_ 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue } |
        ForEach-Object { [version]$_.Name })
    $oldMsvc = $msvc | Where-Object { $_.Major -eq 14 -and $_.Minor -ge 30 -and $_.Minor -le 38 } | Sort-Object -Descending | Select-Object -First 1

    $results = foreach ($engine in $all) {
        $out = Join-Path $BuildDir "UE$($engine.Version)\$Name"
        $log = Join-Path $LogDir "UE$($engine.Version).log"
        if (Test-Path $out) { Remove-Item $out -Recurse -Force }
        Write-Host "[$Name] Building for UE $($engine.Patch) ($($engine.Root))..."

        # The modules are editor-only, so an editor build in a throwaway host project is all that ships
        # (it also writes Binaries\Win64\UnrealEditor.modules with the engine's build id).
        $hostDir = Join-Path $BuildDir "Host\UE$($engine.Version)"
        if (Test-Path $hostDir) { Remove-Item $hostDir -Recurse -Force }
        $hostPlugin = Join-Path $hostDir "Plugins\$Name"
        New-Item -ItemType Directory -Force $hostPlugin | Out-Null
        Copy-Item $PluginFile.FullName $hostPlugin
        foreach ($sub in 'Source', 'Resources', 'Config', 'Content') {
            if (Test-Path (Join-Path $PluginDir $sub)) { Copy-Item (Join-Path $PluginDir $sub) $hostPlugin -Recurse }
        }
        $hostProject = Join-Path $hostDir 'HostProject.uproject'
        @{ FileVersion = 3; Plugins = @(@{ Name = $Name; Enabled = $true }) } | ConvertTo-Json | Out-File $hostProject -Encoding ascii

        $extra = ''
        if ([version]$engine.Version -lt [version]'5.4' -and $oldMsvc) { $extra = " -CompilerVersion=$oldMsvc" }
        # UE 5.0/5.1 tools want the .NET Core 3.1 desktop runtime; let them run on a newer one if that's missing.
        $env:DOTNET_ROLL_FORWARD = if ([version]$engine.Version -lt [version]'5.2') { 'Major' } else { $null }

        $buildBat = Join-Path $engine.Root 'Engine\Build\BatchFiles\Build.bat'
        cmd /c "`"$buildBat`" UnrealEditor Win64 Development `"-Project=$hostProject`" `"-plugin=$hostPlugin\$Name.uplugin`" -noubtmakefiles -nohotreload `"-log=$LogDir\UBT-UE$($engine.Version).txt`"$extra > `"$log`" 2>&1"
        $ok = $LASTEXITCODE -eq 0
        if ($ok) {
            # Ship binaries and source only: drop intermediates and debug symbols.
            Copy-Item $hostPlugin $out -Recurse
            Remove-Item (Join-Path $out 'Intermediate') -Recurse -Force -ErrorAction SilentlyContinue
            Get-ChildItem $out -Recurse -Filter *.pdb | Remove-Item -Force
        }
        Remove-Item $hostDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ("[$Name]   UE $($engine.Version): " + $(if ($ok) { 'OK' } else { "FAILED (see $log)" }))
        [pscustomobject]@{ Engine = $engine.Version; Ok = $ok; Log = $log }
    }
    $results | Format-Table -AutoSize | Out-String | Write-Host
}

# Stage the installer: scripts, manifest, prebuilt plugin per engine version, plus a source copy.
$built = @(Get-ChildItem $BuildDir -Directory -Filter 'UE5.*' | Where-Object { Test-Path (Join-Path $_.FullName "$Name\$Name.uplugin") } |
    ForEach-Object { $_.Name -replace '^UE', '' } | Sort-Object { [version]$_ })
if (-not $built) { throw 'Nothing built to package.' }

$stage = Join-Path $BuildDir "Stage\$Name-$Version"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $stage 'Builds'), (Join-Path $stage 'Source') | Out-Null

Copy-Item (Join-Path $Root 'Installer\*') $stage
Copy-Item (Join-Path $Root 'README.md') $stage -ErrorAction SilentlyContinue
foreach ($v in $built) {
    Copy-Item (Join-Path $BuildDir "UE$v") (Join-Path $stage 'Builds') -Recurse
    # Ship the current descriptor (version, description) with older binaries, as long as the modules still match.
    $stagedDescriptor = Join-Path $stage "Builds\UE$v\$Name\$Name.uplugin"
    $builtModules = ((Get-Content $stagedDescriptor -Raw | ConvertFrom-Json).Modules.Name | Sort-Object) -join ','
    if ($builtModules -ne (($Descriptor.Modules.Name | Sort-Object) -join ',')) { throw "UE $v build is out of date (modules changed); run Build.ps1 without -PackageOnly." }
    Copy-Item $PluginFile.FullName $stagedDescriptor -Force
}
$src = New-Item -ItemType Directory -Force (Join-Path $stage "Source\$Name")
Copy-Item $PluginFile.FullName $src
foreach ($sub in 'Source', 'Resources', 'Config', 'Content') {
    if (Test-Path (Join-Path $PluginDir $sub)) { Copy-Item (Join-Path $PluginDir $sub) $src -Recurse }
}

[ordered]@{
    Name         = $Name
    FriendlyName = $Descriptor.FriendlyName
    Version      = $Version
    Builds       = $built
} | ConvertTo-Json | Out-File (Join-Path $stage 'manifest.json') -Encoding ascii

$dist = New-Item -ItemType Directory -Force (Join-Path $Root 'Dist')
$zip = Join-Path $dist "$Name-$Version-Installer.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Write-Host "[$Name] Packaged $zip (prebuilt for UE $($built -join ', '))"
