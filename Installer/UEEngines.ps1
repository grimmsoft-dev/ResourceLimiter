# Finds Unreal Engine 5 installs on this machine.
# Used by both the installer and Scripts\Build.ps1.

function Get-UEVersionInfo([string]$EngineRoot) {
    $versionFile = Join-Path $EngineRoot 'Engine\Build\Build.version'
    if (-not (Test-Path $versionFile)) { return $null }
    try { $v = Get-Content $versionFile -Raw | ConvertFrom-Json } catch { return $null }
    if ($v.MajorVersion -ne 5) { return $null }
    [pscustomobject]@{
        Version   = "$($v.MajorVersion).$($v.MinorVersion)"
        Patch     = "$($v.MajorVersion).$($v.MinorVersion).$($v.PatchVersion)"
        Root      = (Resolve-Path $EngineRoot).Path.TrimEnd('\')
        Installed = Test-Path (Join-Path $EngineRoot 'Engine\Build\InstalledBuild.txt')
    }
}

# A UE5 engine at a folder the user picked: the engine root (holding Engine\) or its Engine folder.
# Returns $null if the folder isn't a UE5 engine.
function Resolve-UEEngineFolder([string]$Path) {
    $Path = $Path.Trim('"', ' ').TrimEnd('\')
    if (-not $Path -or -not (Test-Path $Path -PathType Container)) { return $null }
    if ((Split-Path $Path -Leaf) -eq 'Engine' -and -not (Test-Path (Join-Path $Path 'Engine\Build\Build.version'))) {
        $Path = Split-Path $Path -Parent
    }
    $info = Get-UEVersionInfo $Path
    if ($info) { $info | Add-Member Association $null }
    $info
}

# Returns one object per UE5 install: Version ("5.6"), Patch ("5.6.1"), Root, Installed (launcher/binary build), Association.
function Find-UE5Engines {
    $found = @{}
    $add = {
        param($root, $association)
        if (-not $root) { return }
        $info = Get-UEVersionInfo $root
        if (-not $info -or $found.ContainsKey($info.Root.ToLower())) { return }
        $info | Add-Member Association $association
        $found[$info.Root.ToLower()] = $info
    }

    # Epic Games Launcher installs.
    $dat = Join-Path $env:ProgramData 'Epic\UnrealEngineLauncher\LauncherInstalled.dat'
    if (Test-Path $dat) {
        try {
            foreach ($app in (Get-Content $dat -Raw | ConvertFrom-Json).InstallationList) {
                if ($app.AppName -like 'UE_5.*') { & $add $app.InstallLocation ($app.AppName -replace '^UE_', '') }
            }
        } catch { }
    }

    # Launcher registry entries (also covers engines the launcher no longer lists).
    foreach ($key in Get-ChildItem 'HKLM:\SOFTWARE\EpicGames\Unreal Engine' -ErrorAction SilentlyContinue) {
        & $add (Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue).InstalledDirectory $key.PSChildName
    }

    # Source builds registered with UnrealVersionSelector ({GUID} = path).
    $builds = Get-ItemProperty 'HKCU:\SOFTWARE\Epic Games\Unreal Engine\Builds' -ErrorAction SilentlyContinue
    if ($builds) {
        foreach ($p in $builds.PSObject.Properties) {
            if ($p.Name -notlike 'PS*') { & $add $p.Value $p.Name }
        }
    }

    $found.Values | Sort-Object { [version]$_.Patch }
}
