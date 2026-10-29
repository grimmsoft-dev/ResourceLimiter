# Installer for a packaged GrimmSoft Unreal Engine 5 plugin.
#
# Run Install.bat for the window, or from a console:
#   Install.bat -Engine 5.6                          # into an engine (all projects using it)
#   Install.bat -Project "D:\MyGame\MyGame.uproject" # into one project
#   Install.bat -Engine 5.6 -Uninstall
#
# The zip holds Builds\UE<ver>\<Plugin> (prebuilt per engine version) and Source\<Plugin> (for engines
# without a prebuilt copy: C++ projects and source-built engines compile it themselves).

param(
    [string[]]$Engine,
    [string]$Project,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
. (Join-Path $Here 'UEEngines.ps1')

$Manifest = Get-Content (Join-Path $Here 'manifest.json') -Raw | ConvertFrom-Json
$Name = $Manifest.Name
$Title = "$($Manifest.FriendlyName) $($Manifest.Version)"
$Engines = @(Find-UE5Engines)

function Write-Log([string]$Text) {
    if ($script:LogBox) { $script:LogBox.AppendText("$Text`r`n") } else { Write-Host $Text }
}

function Get-EngineTarget($EngineInfo) { Join-Path $EngineInfo.Root "Engine\Plugins\Marketplace\$Name" }
function Get-ProjectTarget([string]$UProject) { Join-Path (Split-Path $UProject -Parent) "Plugins\$Name" }

function Get-InstalledVersion([string]$Target) {
    $file = Join-Path $Target "$Name.uplugin"
    if (Test-Path $file) { try { return (Get-Content $file -Raw | ConvertFrom-Json).VersionName } catch { return '?' } }
    return $null
}

function Get-PrebuiltPath([string]$Version) {
    if ($Manifest.Builds -contains $Version) { return Join-Path $Here "Builds\UE$Version\$Name" }
    return $null
}

# The engine a .uproject opens with, or $null (in-tree source build / unknown association).
function Get-ProjectEngine([string]$UProject) {
    $association = (Get-Content $UProject -Raw | ConvertFrom-Json).EngineAssociation
    if (-not $association) { return $null }
    $match = $Engines | Where-Object { $_.Association -eq $association -or $_.Version -eq $association } | Select-Object -First 1
    if ($match) { return $match }
    if ($association -match '^\d+\.\d+$') { return [pscustomobject]@{ Version = $association; Root = $null; Installed = $true } }
    return $null
}

function Copy-Plugin([string]$Source, [string]$Target) {
    if (Test-Path $Target) {
        # Renaming first fails cleanly (instead of half-deleting) when the editor has the DLL loaded.
        $old = "$Target.old"
        if (Test-Path $old) { Remove-Item $old -Recurse -Force }
        try { Rename-Item $Target (Split-Path $old -Leaf) }
        catch { throw "Can't replace '$Target'. Close Unreal Editor and try again." }
        Remove-Item $old -Recurse -Force
    }
    New-Item -ItemType Directory -Force (Split-Path $Target -Parent) | Out-Null
    Copy-Item $Source $Target -Recurse
}

function Remove-Plugin([string]$Target) {
    if (-not (Test-Path $Target)) { Write-Log "  Not installed at $Target"; return }
    try { Remove-Item $Target -Recurse -Force }
    catch { throw "Can't remove '$Target'. Close Unreal Editor and try again." }
    Write-Log "  Removed $Target"
}

function Install-ToEngine($EngineInfo) {
    Write-Log "UE $($EngineInfo.Patch) ($($EngineInfo.Root)):"
    $target = Get-EngineTarget $EngineInfo
    if ($Uninstall) { Remove-Plugin $target; return }

    $prebuilt = Get-PrebuiltPath $EngineInfo.Version
    if ($prebuilt) {
        Copy-Plugin $prebuilt $target
        Write-Log "  Installed $Title to $target"
    } elseif (-not $EngineInfo.Installed) {
        Copy-Plugin (Join-Path $Here "Source\$Name") $target
        Write-Log "  Installed source to $target. Rebuild the editor from your engine solution to compile it."
    } else {
        throw "No prebuilt copy for UE $($EngineInfo.Version) (have: $($Manifest.Builds -join ', ')). Install into a C++ project instead; it compiles the plugin itself."
    }
}

function Install-ToProject([string]$UProject) {
    if (-not (Test-Path $UProject) -or [IO.Path]::GetExtension($UProject) -ne '.uproject') { throw "'$UProject' is not a .uproject file." }
    Write-Log "Project $UProject :"
    $target = Get-ProjectTarget $UProject
    if ($Uninstall) { Remove-Plugin $target; return }

    $projectEngine = Get-ProjectEngine $UProject
    $prebuilt = if ($projectEngine) { Get-PrebuiltPath $projectEngine.Version } else { $null }
    if ($prebuilt) {
        Copy-Plugin $prebuilt $target
        Write-Log "  Installed $Title (prebuilt for UE $($projectEngine.Version)) to $target"
    } else {
        Copy-Plugin (Join-Path $Here "Source\$Name") $target
        $isCpp = Test-Path (Join-Path (Split-Path $UProject -Parent) 'Source')
        Write-Log "  Installed source to $target; the editor compiles it when the project opens."
        if (-not $isCpp) { Write-Log "  WARNING: this is a Blueprint-only project, which can't compile plugins. Add a C++ class to it first (Tools > New C++ Class)." }
    }

    if ($projectEngine -and $projectEngine.Root -and (Get-InstalledVersion (Get-EngineTarget $projectEngine))) {
        Write-Log "  Note: UE $($projectEngine.Version) also has $Name installed engine-wide; uninstall one of the two copies."
    }
}

# ---- Console mode -------------------------------------------------------------------------------

if ($Engine -or $Project) {
    $failed = $false
    foreach ($e in $Engine) {
        $info = $Engines | Where-Object { $_.Version -eq $e -or $_.Root -eq $e.TrimEnd('\') } | Select-Object -First 1
        try {
            if (-not $info) { throw "UE $e not found. Found: $(($Engines | ForEach-Object Version) -join ', ')" }
            Install-ToEngine $info
        } catch { Write-Log "  ERROR: $($_.Exception.Message)"; $failed = $true }
    }
    if ($Project) {
        try { Install-ToProject $Project } catch { Write-Log "  ERROR: $($_.Exception.Message)"; $failed = $true }
    }
    exit $(if ($failed) { 1 } else { 0 })
}

# ---- Window -------------------------------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form -Property @{
    Text = "$Title - Installer"; Size = New-Object Drawing.Size(720, 560); StartPosition = 'CenterScreen'
    MinimumSize = New-Object Drawing.Size(600, 480); Font = New-Object Drawing.Font('Segoe UI', 9)
}

$header = New-Object Windows.Forms.Label -Property @{
    Text = "$Title for Unreal Engine 5`r`nPrebuilt for UE $($Manifest.Builds -join ', ')."
    Location = '12,10'; Size = '680,36'; Anchor = 'Top,Left,Right'
}

$engineGroup = New-Object Windows.Forms.GroupBox -Property @{
    Text = 'Install into an engine (every project that uses it)'; Location = '12,52'; Size = '680,200'; Anchor = 'Top,Left,Right'
}
$engineList = New-Object Windows.Forms.ListView -Property @{
    View = 'Details'; CheckBoxes = $true; FullRowSelect = $true; Location = '10,20'; Size = '660,170'; Anchor = 'Top,Bottom,Left,Right'
}
[void]$engineList.Columns.Add('Engine', 70)
[void]$engineList.Columns.Add('Location', 330)
[void]$engineList.Columns.Add('Prebuilt', 70)
[void]$engineList.Columns.Add('Installed', 90)
$engineGroup.Controls.Add($engineList)

function Update-EngineList {
    $engineList.Items.Clear()
    foreach ($e in $Engines) {
        $item = New-Object Windows.Forms.ListViewItem("UE $($e.Patch)")
        [void]$item.SubItems.Add($e.Root)
        $hasBuild = [bool](Get-PrebuiltPath $e.Version)
        [void]$item.SubItems.Add($(if ($hasBuild) { 'Yes' } elseif (-not $e.Installed) { 'Source' } else { 'No' }))
        $installed = Get-InstalledVersion (Get-EngineTarget $e)
        [void]$item.SubItems.Add($(if ($installed) { $installed } else { '-' }))
        if (-not $hasBuild -and $e.Installed) { $item.ForeColor = [Drawing.Color]::Gray }
        $item.Tag = $e
        [void]$engineList.Items.Add($item)
    }
}

$projectGroup = New-Object Windows.Forms.GroupBox -Property @{
    Text = 'Or install into one project'; Location = '12,258'; Size = '680,78'; Anchor = 'Top,Left,Right'
}
$projectBox = New-Object Windows.Forms.TextBox -Property @{ Location = '10,22'; Size = '560,23'; Anchor = 'Top,Left,Right' }
$browse = New-Object Windows.Forms.Button -Property @{ Text = 'Browse...'; Location = '580,21'; Size = '90,25'; Anchor = 'Top,Right' }
$projectInfo = New-Object Windows.Forms.Label -Property @{ Location = '10,50'; Size = '660,20'; Anchor = 'Top,Left,Right'; ForeColor = [Drawing.Color]::DimGray }
$projectGroup.Controls.AddRange(@($projectBox, $browse, $projectInfo))

$browse.Add_Click({
    $dialog = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'Unreal project (*.uproject)|*.uproject'; Title = 'Choose a project' }
    if ($dialog.ShowDialog() -eq 'OK') { $projectBox.Text = $dialog.FileName }
})
$projectBox.Add_TextChanged({
    $path = $projectBox.Text.Trim('"', ' ')
    if (-not $path) { $projectInfo.Text = ''; return }
    if (-not (Test-Path $path)) { $projectInfo.Text = 'File not found.'; return }
    try {
        $pe = Get-ProjectEngine $path
        $installed = Get-InstalledVersion (Get-ProjectTarget $path)
        $projectInfo.Text = $(if ($pe) { "Uses UE $($pe.Version)" } else { 'Engine unknown' }) +
            $(if ($pe -and (Get-PrebuiltPath $pe.Version)) { ' - prebuilt copy available.' } else { ' - source copy (project compiles it).' }) +
            $(if ($installed) { "  Installed: $installed" } else { '' })
    } catch { $projectInfo.Text = 'Not a valid .uproject.' }
})

$logBox = New-Object Windows.Forms.TextBox -Property @{
    Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; Location = '12,344'; Size = '680,130'; Anchor = 'Top,Bottom,Left,Right'
}
$script:LogBox = $logBox

$installButton = New-Object Windows.Forms.Button -Property @{ Text = 'Install'; Location = '420,484'; Size = '86,28'; Anchor = 'Bottom,Right' }
$uninstallButton = New-Object Windows.Forms.Button -Property @{ Text = 'Uninstall'; Location = '512,484'; Size = '86,28'; Anchor = 'Bottom,Right' }
$closeButton = New-Object Windows.Forms.Button -Property @{ Text = 'Close'; Location = '604,484'; Size = '86,28'; Anchor = 'Bottom,Right' }
$closeButton.Add_Click({ $form.Close() })

$run = {
    param([bool]$Remove)
    $script:Uninstall = $Remove
    $targets = @($engineList.CheckedItems | ForEach-Object { $_.Tag })
    $path = $projectBox.Text.Trim('"', ' ')
    if (-not $targets -and -not $path) { Write-Log 'Tick an engine or choose a project first.'; return }
    $denied = $false
    foreach ($t in $targets) {
        try { Install-ToEngine $t }
        catch [UnauthorizedAccessException] { Write-Log "  ERROR: $($_.Exception.Message)"; $denied = $true }
        catch { Write-Log "  ERROR: $($_.Exception.Message)" }
    }
    if ($path) { try { Install-ToProject $path } catch { Write-Log "  ERROR: $($_.Exception.Message)" } }
    if ($denied) { Write-Log 'Access denied: right-click Install.bat and choose "Run as administrator".' }
    Write-Log 'Done. Restart Unreal Editor to load the change.'
    Update-EngineList
    $projectBox.Text = $projectBox.Text
}
$installButton.Add_Click({ & $run $false })
$uninstallButton.Add_Click({ & $run $true })

$form.Controls.AddRange(@($header, $engineGroup, $projectGroup, $logBox, $installButton, $uninstallButton, $closeButton))
$form.AcceptButton = $installButton
Update-EngineList
if (-not $Engines) { Write-Log 'No Unreal Engine 5 installs found. You can still install into a project.' }
[void]$form.ShowDialog()
