# ================================================================
# DIVoptimizer
# Author  : Kaz
#
# Single self-contained script - console AND GUI in one file, no
# other files needed. Meant to be run the way Chris Titus's WinUtil
# is run: paste one command into an elevated PowerShell window and
# it just runs - nothing is saved to disk, nothing to unblock.
#
#   irm <hosted-raw-url>/DIVoptimizer.ps1 | iex        (GUI, default)
#   $Console=$true; irm <hosted-raw-url>/DIVoptimizer.ps1 | iex   (console)
#
# Fill in $Script:SourceUrl below once you host this file (e.g. a
# raw.githubusercontent.com link) so it can re-fetch itself when it
# needs to relaunch elevated - see the note above Start-Elevated.
#
# Needs Windows PowerShell 5.1 (built into every Windows 10/11 PC).
# No #Requires line on purpose - that directive throws when this
# text is piped into iex rather than run as a saved .ps1 file.
# ================================================================

# $Console may already be set by the caller (e.g. "$Console=$true; irm ... | iex").
# Only default it here if nothing set it - never overwrite an existing value.
if (-not (Test-Path variable:Console)) { $Console = $false }
if ($args -contains '-Console' -or $args -contains '-console') { $Console = $true }

$Script:AppName      = "DIVoptimizer"

$Script:Author       = "Kaz"
$Script:Version      = "0.6.0"
$Script:Width        = 78
$Script:SysCache     = $null
$Script:ProgramData  = Join-Path $env:ProgramData "DIVoptimizer"
$Script:BackupsDir   = Join-Path $Script:ProgramData "Backups"
$Script:LogsDir      = Join-Path $Script:ProgramData "Logs"
# $PSScriptRoot is an empty string (not null) when this runs via `irm ... | iex`,
# and Join-Path rejects an empty string outright - only build a config.ini path
# when there's an actual folder this script is running from.
$Script:ConfigPath   = $null
if ($PSScriptRoot) { $Script:ConfigPath = Join-Path $PSScriptRoot "config.ini" }
$Script:CurrentBackupDir = $null
$Script:ManifestPath = $null
$Script:SessionLogPath = $null
$Script:Counters = @{ Success = 0; Skipped = 0; Failed = 0 }
$Script:RestartNeeded = $false
$Script:RestartReasons = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------
# CORE INFRASTRUCTURE
# ---------------------------------------------------------------

function Ensure-Directories {
    foreach ($d in @($Script:ProgramData, $Script:BackupsDir, $Script:LogsDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-WinGeneration {
    # 11 = Windows 11 (build 22000+), 10 = Windows 10, 0 = not supported
    $b = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    if ($b -ge 22000) { return 11 }
    if ($b -ge 10240) { return 10 }
    return 0
}

function Get-ReleaseLabel {
    # 22H2 / 23H2 / 24H2 on Windows 11 and Windows 10 21H2 / 22H2 (older builds use ReleaseId)
    try {
        $k = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if ($k.DisplayVersion) { return [string]$k.DisplayVersion }
        if ($k.ReleaseId) { return [string]$k.ReleaseId }
    } catch { }
    return ''
}

function Test-Compatibility {
    $os = Get-CimInstance Win32_OperatingSystem
    $gen = Get-WinGeneration
    $build = [int]$os.BuildNumber
    if ($os.ProductType -ne 1 -or $gen -eq 0) {
        Write-Tag FAIL 'DIVoptimizer supports Windows 10 and Windows 11 (client editions) only.'
        Write-Tag INFO ("Detected: {0} (build {1})" -f $os.Caption, $build)
        return $false
    }
    if ($build -lt 17763) {
        Write-Tag WARN 'Windows 10 builds older than 1809 (17763) are untested. Unsupported features will be skipped.'
    }
    return $true
}

function Require-Admin {
    param([string]$What = 'This operation')
    if (Test-IsAdmin) { return $true }
    Write-Tag WARN "$What requires Administrator privileges. Restart DIVoptimizer as Administrator."
    Start-Sleep -Seconds 2
    return $false
}

function Request-Elevation {
    # Offers to relaunch this script elevated. Returns $true if an elevated copy was started.
    Write-Tag WARN 'Administrator privileges are required for some operations.'
    Write-Menu 'Y' 'Restart as Administrator'
    Write-Menu 'N' 'Continue in read-only mode'
    $a = Read-Host '   Choice'
    if ($a -match '^(y|yes)$') {
        try {
            $exe = (Get-Process -Id $PID).Path
            if (-not $exe) { $exe = 'powershell.exe' }
            Start-Process -FilePath $exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
            return $true
        } catch {
            Write-Tag WARN 'Elevation was cancelled or failed. Continuing in read-only mode.'
        }
    }
    return $false
}

function Write-Tag {
    param([string]$Tag, [string]$Message)
    $color = switch ($Tag) {
        "OK"    { "Green" }
        "FAIL"  { "Red" }
        "SKIP"  { "DarkYellow" }
        "WARN"  { "Yellow" }
        "INFO"  { "Cyan" }
        default { "Gray" }
    }
    Write-Host ("[{0}] " -f $Tag) -ForegroundColor $color -NoNewline
    Write-Host $Message
    Write-Log $Tag $Message
}

function Write-Log {
    param([string]$Level, [string]$Message)
    if (-not $Script:SessionLogPath) { return }
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $Script:SessionLogPath -Value $line
}

# ---------------------------------------------------------------
# UI HELPERS (DIVoptimizer look & feel)
# ---------------------------------------------------------------

function Initialize-Console {
    try {
        $ui = $Host.UI.RawUI
        $ui.WindowTitle = "$($Script:AppName) v$($Script:Version)  |  by $($Script:Author)"
        $buf = $ui.BufferSize
        if ($buf.Width -lt 100) {
            $ui.BufferSize = New-Object System.Management.Automation.Host.Size(100, [Math]::Max($buf.Height, 3000))
        }
        $win = $ui.WindowSize
        $maxH = $ui.MaxWindowSize.Height
        $wantW = [Math]::Min(96, $ui.MaxWindowSize.Width)
        $wantH = [Math]::Min(42, $maxH)
        if ($win.Width -lt $wantW -or $win.Height -lt $wantH) {
            $ui.WindowSize = New-Object System.Management.Automation.Host.Size([Math]::Max($win.Width, $wantW), [Math]::Max($win.Height, $wantH))
        }
    } catch { }
}

function Show-Banner {
    $logo = @'
    ____  _____    __
   / __ \/  _/ |  / /
  / / / // / | | / / 
 / /_/ // /  | |/ /  
/_____/___/  |___/   
'@
    $colors = @('Cyan','Cyan','Cyan','DarkCyan','DarkCyan')
    $lines = $logo -split "`r?`n"
    Write-Host ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $c = if ($i -lt $colors.Count) { $colors[$i] } else { 'DarkCyan' }
        Write-Host ('  ' + $lines[$i]) -ForegroundColor $c
    }
    Write-Host '  O P T I M I Z E R' -ForegroundColor White -NoNewline
    Write-Host ("      v{0}   |   by {1}" -f $Script:Version, $Script:Author) -ForegroundColor DarkGray
    Write-Host ('  ' + ('=' * ($Script:Width - 4))) -ForegroundColor DarkCyan
}

function Show-Header {
    param([string]$Title)
    $sub = ''
    if ($Title -match '^(.*?)\s*\((.*)\)\s*$') { $Title = $Matches[1].Trim(); $sub = $Matches[2].Trim() }
    $Title = $Title.ToUpper()
    $left  = " DIVoptimizer  >  $Title"
    $right = "v$($Script:Version) "
    $pad = [Math]::Max(1, $Script:Width - $left.Length - $right.Length)
    Write-Host ''
    Write-Host ' DIV' -ForegroundColor Cyan -NoNewline
    Write-Host 'optimizer' -ForegroundColor White -NoNewline
    Write-Host '  >  ' -ForegroundColor DarkGray -NoNewline
    Write-Host $Title -ForegroundColor Cyan -NoNewline
    Write-Host (' ' * $pad) -NoNewline
    Write-Host $right -ForegroundColor DarkGray
    Write-Host (' ' + ('=' * ($Script:Width - 2))) -ForegroundColor DarkCyan
    if ($sub) { Write-Host (' ' + $sub) -ForegroundColor DarkGray }
    Write-Host ''
}

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host (' ' + $Text.ToUpper()) -ForegroundColor DarkCyan
    Write-Host (' ' + ('-' * ($Script:Width - 2))) -ForegroundColor DarkGray
}

function Write-Menu {
    param([string]$Key, [string]$Text, [string]$Note = '')
    Write-Host '   ' -NoNewline
    Write-Host ('[{0}]' -f $Key).PadRight(6) -ForegroundColor Cyan -NoNewline
    Write-Host $Text -NoNewline
    if ($Note) { Write-Host ('  ' + $Note) -ForegroundColor DarkGray -NoNewline }
    Write-Host ''
}

function Write-KV {
    param([string]$Key, $Value, [string]$Color = 'White')
    Write-Host ('   {0,-14}' -f $Key) -ForegroundColor DarkGray -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Write-Cell {
    # Prints one cell of the two-column main menu and pads it to $Width characters.
    param($Cell, [int]$Width)
    if ($null -eq $Cell) { Write-Host (' ' * $Width) -NoNewline; return }
    switch ($Cell.Kind) {
        'H' {
            $t = ' ' + $Cell.Text.ToUpper()
            Write-Host $t -ForegroundColor DarkCyan -NoNewline
            Write-Host (' ' * [Math]::Max(0, $Width - $t.Length)) -NoNewline
        }
        'I' {
            $k = ('[{0,2}]' -f $Cell.Key)
            Write-Host '  ' -NoNewline
            Write-Host $k -ForegroundColor Cyan -NoNewline
            Write-Host (' ' + $Cell.Text) -NoNewline
            $used = 2 + $k.Length + 1 + $Cell.Text.Length
            Write-Host (' ' * [Math]::Max(0, $Width - $used)) -NoNewline
        }
        default { Write-Host (' ' * $Width) -NoNewline }
    }
}

function Start-Session {
    Ensure-Directories
    $stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $Script:SessionLogPath = Join-Path $Script:LogsDir "$stamp.log"
    Add-Content -Path $Script:SessionLogPath -Value "$($Script:AppName) v$($Script:Version) by $($Script:Author)"
    Add-Content -Path $Script:SessionLogPath -Value "Session started $stamp"
    Add-Content -Path $Script:SessionLogPath -Value "Windows: $((Get-CimInstance Win32_OperatingSystem).Caption) Build $((Get-CimInstance Win32_OperatingSystem).BuildNumber)"
}

function New-BackupSession {
    if ($Script:CurrentBackupDir) { return $Script:CurrentBackupDir }
    $stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $Script:CurrentBackupDir = Join-Path $Script:BackupsDir $stamp
    New-Item -ItemType Directory -Path $Script:CurrentBackupDir -Force | Out-Null
    $Script:ManifestPath = Join-Path $Script:CurrentBackupDir "manifest.txt"
    Add-Content -Path $Script:ManifestPath -Value "TOOLKIT_VERSION|$Script:Version"
    Add-Content -Path $Script:ManifestPath -Value "TIMESTAMP|$stamp"
    Add-Content -Path $Script:ManifestPath -Value "WINDOWS_BUILD|$((Get-CimInstance Win32_OperatingSystem).BuildNumber)"
    Write-Tag INFO "Backup session created: $Script:CurrentBackupDir"
    return $Script:CurrentBackupDir
}

function Add-ManifestRecord {
    param([string]$Line)
    New-BackupSession | Out-Null
    Add-Content -Path $Script:ManifestPath -Value $Line
}

# ---- Tracked backup helpers (record ORIGINAL state before touching it) ----

function Get-ServiceMode {
    # Returns the service start type in sc.exe terms: auto | delayed-auto | demand | disabled | keep
    param([string]$Name)
    $wmi = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $wmi) { return $null }
    switch ($wmi.StartMode) {
        'Auto' {
            $delayed = $false
            try {
                $d = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name DelayedAutostart -ErrorAction Stop
                $delayed = ($d.DelayedAutostart -eq 1)
            } catch { }
            if ($delayed) { return 'delayed-auto' } else { return 'auto' }
        }
        'Manual'   { return 'demand' }
        'Disabled' { return 'disabled' }
        default    { return 'keep' }
    }
}

function Set-ServiceMode {
    param([string]$Name, [string]$Mode)
    if ($Mode -eq 'keep') { return $true }
    $null = & sc.exe config $Name start= $Mode 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Backup-ServiceState {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    $mode = Get-ServiceMode -Name $Name
    if (-not $mode) { $mode = 'keep' }
    Add-ManifestRecord "SERVICE|$Name|$mode|$($svc.Status)"
    return $true
}

function Backup-RegistryValue {
    param([string]$Path, [string]$Name)
    if (Test-Path $Path) {
        $existing = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            $val = $existing.$Name
            $item = Get-Item $Path
            $kind = $item.GetValueKind($Name)
            Add-ManifestRecord "REGISTRY|$Path|$Name|$val|$kind|True"
            return
        }
    }
    Add-ManifestRecord "REGISTRY|$Path|$Name|__NONE__|DWord|False"
}

function Backup-PowerPlanState {
    $active = powercfg /getactivescheme
    if ($active -match '([0-9a-fA-F-]{36})') {
        Add-ManifestRecord "POWERPLAN|$($Matches[1])"
    }
}

function Backup-TaskState {
    param([string]$TaskPath, [string]$TaskName)
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
        Add-ManifestRecord "TASK|$TaskPath$TaskName|$($t.State)"
        return $true
    } catch { return $false }
}

function Record-AppxRemoval {
    param([string]$Name)
    Add-ManifestRecord "APPX|$Name"
}

# ---- Dry-run confirmation ----

function Confirm-Changes {
    param([string[]]$Changes, [string]$Title = "The following changes WILL be made:")
    if (-not (Test-IsAdmin)) {
        Write-Tag WARN 'Administrator privileges are required to apply changes. Restart DIVoptimizer as Administrator.'
        return $false
    }
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ""
    $i = 1
    foreach ($c in $Changes) {
        Write-Host "  $i. $c"
        $i++
    }
    Write-Host ""
    $resp = Read-Host "Continue? [Y] Apply  [N] Cancel"
    return ($resp -match '^(y|yes)$')
}

# ---- Tracked apply helpers ----

function Set-RegTracked {
    param([string]$Path, [string]$Name, $Value, [string]$Type, [string]$Description)
    Backup-RegistryValue -Path $Path -Name $Name
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-Tag OK $Description
        $Script:Counters.Success++
    } catch {
        Write-Tag FAIL "$Description ($($_.Exception.Message))"
        $Script:Counters.Failed++
    }
}

function Set-ServiceTracked {
    param([string]$Name, [string]$StartupType, [string]$FriendlyName = $Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Tag SKIP "$FriendlyName not present on this system"
        $Script:Counters.Skipped++
        return
    }
    Backup-ServiceState -Name $Name | Out-Null
    $mode = switch ($StartupType) {
        'Disabled'         { 'disabled' }
        'Automatic'        { 'auto' }
        'AutomaticDelayed' { 'delayed-auto' }
        default            { 'demand' }
    }
    try {
        if (-not (Set-ServiceMode -Name $Name -Mode $mode)) { throw "sc.exe could not change the start type (access denied or protected service)" }
        if ($mode -eq 'disabled') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        Write-Tag OK "$FriendlyName -> $StartupType"
        $Script:Counters.Success++
    } catch {
        Write-Tag FAIL "$FriendlyName ($($_.Exception.Message))"
        $Script:Counters.Failed++
    }
}

# ---------------------------------------------------------------
# SYSTEM DETECTION
# ---------------------------------------------------------------

function Get-SysInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $ramBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1
    $sysDrive = $env:SystemDrive
    $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sysDrive'"

    $storageType = "Unknown"
    try {
        $letter = $sysDrive.TrimEnd(':')
        $disk = Get-Partition -DriveLetter $letter -ErrorAction Stop | Get-Disk -ErrorAction Stop
        $phys = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq $disk.Number }
        if ($phys) {
            $storageType = [string]$phys.MediaType
            if ($phys.BusType -eq 'NVMe') { $storageType = 'NVMe SSD' }
            elseif (-not $storageType -or $storageType -eq 'Unspecified') { $storageType = 'Unknown' }
        }
    } catch { }

    $powerPlan = "Unknown"
    try {
        $out = powercfg /getactivescheme
        if ($out -match '\(([^)]+)\)\s*$') { $powerPlan = $Matches[1] }
    } catch { }

    $secureBoot = "Not Supported (Legacy BIOS or unavailable)"
    try { $secureBoot = if (Confirm-SecureBootUEFI) { "Enabled" } else { "Disabled" } }
    catch { if (-not (Test-IsAdmin)) { $secureBoot = "Requires Administrator" } }

    $tpm = "Unknown"
    try {
        $t = Get-Tpm -ErrorAction Stop
        $tpm = if ($t.TpmPresent) { if ($t.TpmReady) { "Present, Ready" } else { "Present, Not Ready" } } else { "Not Present" }
    } catch { $tpm = if (-not (Test-IsAdmin)) { "Requires Administrator" } else { "Unable to query" } }

    $gameMode = "Unknown"
    try {
        $v = Get-ItemProperty "HKCU:\Software\Microsoft\GameBar" -Name AutoGameModeEnabled -ErrorAction Stop
        $gameMode = if ($v.AutoGameModeEnabled -eq 1) { "Enabled" } else { "Disabled" }
    } catch { $gameMode = "Default (not explicitly set)" }

    $hags = "Unknown"
    try {
        $v = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name HwSchMode -ErrorAction Stop
        $hags = if ($v.HwSchMode -eq 2) { "Enabled" } else { "Disabled" }
    } catch { $hags = "Default (not explicitly set)" }

    $wsearch = Get-Service -Name WSearch -ErrorAction SilentlyContinue
    $wsearchStatus = if ($wsearch) { "$($wsearch.Status) / Startup: $((Get-CimInstance Win32_Service -Filter "Name='WSearch'").StartMode)" } else { "Not present" }

    $xboxSvc = Get-Service -Name XblAuthManager, XboxNetApiSvc, XboxGipSvc -ErrorAction SilentlyContinue
    $xboxStatus = if ($xboxSvc) { ($xboxSvc | ForEach-Object { "$($_.Name):$($_.Status)" }) -join ", " } else { "Not present" }

    $oneDrive = Get-AppxPackage -Name "*OneDrive*" -ErrorAction SilentlyContinue
    $oneDriveDesktop = Test-Path "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
    $oneDriveStatus = if ($oneDrive -or $oneDriveDesktop) { "Installed" } else { "Not detected" }

    $startupCount = 0
    try { $startupCount = (Get-CimInstance Win32_StartupCommand -ErrorAction Stop | Measure-Object).Count } catch { }

    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    $deviceType = if ($battery) { "Laptop" } else { "Desktop" }

    [ordered]@{
        "Windows Edition"    = $os.Caption
        "Windows Version"    = $os.Version
        "Windows Build"      = $os.BuildNumber
        "Windows Release"    = (Get-ReleaseLabel)
        "Architecture"       = $os.OSArchitecture
        "Device Type"        = $deviceType
        "CPU"                = $cpu.Name
        "CPU Cores/Threads"  = "$($cpu.NumberOfCores)C / $($cpu.NumberOfLogicalProcessors)T"
        "RAM"                = "{0:N1} GB" -f ($ramBytes / 1GB)
        "GPU"                = $gpu.Name
        "GPU Driver Version" = $gpu.DriverVersion
        "System Drive"       = $sysDrive
        "Storage Type"       = $storageType
        "Total Disk Space"   = "{0:N1} GB" -f ($vol.Size / 1GB)
        "Free Disk Space"    = "{0:N1} GB" -f ($vol.FreeSpace / 1GB)
        "Power Plan"         = $powerPlan
        "Secure Boot"        = $secureBoot
        "TPM"                = $tpm
        "Game Mode"          = $gameMode
        "HAGS"               = $hags
        "Windows Search"     = $wsearchStatus
        "Xbox Services"      = $xboxStatus
        "OneDrive"           = $oneDriveStatus
        "Startup Items"      = $startupCount
        "Administrator"      = if (Test-IsAdmin) { "YES" } else { "NO" }
    }
}

function Show-SystemInfo {
    Clear-Host
    Show-Header "SYSTEM INFORMATION (read-only)"
    $info = Get-SysInfo
    foreach ($k in $info.Keys) {
        Write-Host ("  {0,-20}: {1}" -f $k, $info[$k])
    }
    Write-Host ""
    Read-Host "Press Enter to return"
}

# ---------------------------------------------------------------
# ANALYZE SYSTEM (read-only)
# ---------------------------------------------------------------

function Get-InstalledBloatCandidates {
    # Only apps actually present on this system
    $catalog = @(
        "Microsoft.3DBuilder","Microsoft.Print3D","Microsoft.MixedReality.Portal",
        "Microsoft.WindowsFeedbackHub","Microsoft.Getstarted","Microsoft.MicrosoftSolitaireCollection",
        "Microsoft.XboxApp","Microsoft.XboxGameOverlay","Microsoft.XboxGamingOverlay",
        "Microsoft.XboxIdentityProvider","Microsoft.XboxSpeechToTextOverlay","Microsoft.Xbox.TCUI",
        "Microsoft.GamingApp","Microsoft.549981C3F5F10","Microsoft.MicrosoftOfficeHub",
        "Microsoft.MicrosoftStickyNotes","Microsoft.OneDrive","Microsoft.People",
        "Microsoft.SkypeApp","Microsoft.YourPhone","Microsoft.ZuneMusic","Microsoft.ZuneVideo",
        "Microsoft.BingNews","Microsoft.BingWeather","Microsoft.GetHelp","Microsoft.WindowsMaps",
        "Microsoft.WindowsSoundRecorder","Microsoft.WindowsAlarms","Microsoft.Office.OneNote",
        "Clipchamp.Clipchamp","Microsoft.Todos","Microsoft.PowerAutomateDesktop"
    )
    $found = @()
    foreach ($id in $catalog) {
        $pkg = Get-AppxPackage -Name "*$id*" -ErrorAction SilentlyContinue
        if ($pkg) { $found += [pscustomobject]@{ Id = $id; DisplayName = $pkg.Name } }
    }
    return $found
}

function Get-FolderSize {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        return (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    } catch { return 0 }
}

function Show-AnalyzeSystem {
    Clear-Host
    Show-Header "SYSTEM ANALYSIS (read-only - no changes are made)"
    $info = Get-SysInfo

    Write-Host ""
    Write-Host "PERFORMANCE" -ForegroundColor Cyan
    Write-Host "  Power Plan       : $($info['Power Plan'])"
    Write-Host "  Startup Items    : $($info['Startup Items'])"
    Write-Host "  Storage Type     : $($info['Storage Type'])"
    Write-Host "  Free Disk Space  : $($info['Free Disk Space'])"
    $mem = Get-CimInstance Win32_OperatingSystem
    $usedPct = [math]::Round((($mem.TotalVisibleMemorySize - $mem.FreePhysicalMemory) / $mem.TotalVisibleMemorySize) * 100, 1)
    Write-Host "  Memory Usage     : $usedPct%"

    Write-Host ""
    Write-Host "DEBLOAT" -ForegroundColor Cyan
    $apps = Get-InstalledBloatCandidates
    Write-Host "  Removable consumer apps detected: $($apps.Count)"
    foreach ($a in $apps) { Write-Host "    - $($a.DisplayName)" }

    Write-Host ""
    Write-Host "PRIVACY" -ForegroundColor Cyan
    $adId = try { (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name Enabled -ErrorAction Stop).Enabled } catch { "Default" }
    $telemetry = try { (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name AllowTelemetry -ErrorAction Stop).AllowTelemetry } catch { "Default (not policy-managed)" }
    $tailored = try { (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" -Name TailoredExperiencesWithDiagnosticDataEnabled -ErrorAction Stop).TailoredExperiencesWithDiagnosticDataEnabled } catch { "Default" }
    Write-Host "  Advertising ID           : $adId"
    Write-Host "  Diagnostic data policy   : $telemetry"
    Write-Host "  Tailored experiences     : $tailored"

    Write-Host ""
    Write-Host "GAMING" -ForegroundColor Cyan
    Write-Host "  Game Mode  : $($info['Game Mode'])"
    Write-Host "  HAGS       : $($info['HAGS'])"
    Write-Host "  Power Plan : $($info['Power Plan'])"

    Write-Host ""
    Write-Host "MAINTENANCE" -ForegroundColor Cyan
    $tempSize = Get-FolderSize $env:TEMP
    $winTempSize = Get-FolderSize "$env:SystemRoot\Temp"
    $rbSize = 0
    try {
        $shell = New-Object -ComObject Shell.Application
        $rb = $shell.Namespace(10)
        foreach ($item in $rb.Items()) { $rbSize += $item.Size }
    } catch { }
    Write-Host ("  User Temp        : {0:N1} MB" -f ($tempSize / 1MB))
    Write-Host ("  Windows Temp     : {0:N1} MB" -f ($winTempSize / 1MB))
    Write-Host ("  Recycle Bin      : {0:N1} MB" -f ($rbSize / 1MB))

    Write-Host ""
    Write-Host "No changes have been made." -ForegroundColor Green
    Write-Host ""
    Read-Host "Press Enter to return"
}

# ---------------------------------------------------------------
# SAFE DEBLOAT
# ---------------------------------------------------------------

$Script:SafeApps = @("Microsoft.3DBuilder","Microsoft.Print3D","Microsoft.MixedReality.Portal",
    "Microsoft.WindowsFeedbackHub","Microsoft.Getstarted","Microsoft.MicrosoftSolitaireCollection")
$Script:AskApps = @("Microsoft.XboxApp","Microsoft.XboxGameOverlay","Microsoft.XboxGamingOverlay",
    "Microsoft.XboxIdentityProvider","Microsoft.XboxSpeechToTextOverlay","Microsoft.Xbox.TCUI",
    "Microsoft.GamingApp","Microsoft.549981C3F5F10","Clipchamp.Clipchamp","Microsoft.Office.OneNote",
    "Microsoft.WindowsMaps","Microsoft.OneDrive","Microsoft.YourPhone","Microsoft.SkypeApp",
    "Microsoft.People","Microsoft.ZuneMusic","Microsoft.ZuneVideo","Microsoft.BingNews",
    "Microsoft.BingWeather","Microsoft.MicrosoftStickyNotes","Microsoft.Todos","Microsoft.PowerAutomateDesktop")
$Script:NeverTouch = @("Microsoft.WindowsStore","Microsoft.DesktopAppInstaller","Microsoft.VCLibs",
    "Microsoft.WindowsSecurityCenter","Microsoft.Windows.WebViewHost")

function Invoke-SafeDebloat {
    Clear-Host
    Show-Header "SAFE DEBLOAT"
    $installed = Get-AppxPackage
    $safeFound = @()
    $askFound = @()
    foreach ($id in $Script:SafeApps) {
        $p = $installed | Where-Object { $_.Name -like "*$id*" }
        if ($p) { $safeFound += [pscustomobject]@{ Id = $id; Name = $p.Name } }
    }
    foreach ($id in $Script:AskApps) {
        $p = $installed | Where-Object { $_.Name -like "*$id*" }
        if ($p) { $askFound += [pscustomobject]@{ Id = $id; Name = $p.Name } }
    }

    if ($safeFound.Count -eq 0 -and $askFound.Count -eq 0) {
        Write-Tag INFO "No removable consumer apps from the catalog were detected."
        Read-Host "Press Enter to return"
        return
    }

    Write-Host ""
    Write-Host "SAFE / OPTIONAL (low impact for most people):"
    for ($i = 0; $i -lt $safeFound.Count; $i++) { Write-Menu "$($i+1)" "$($safeFound[$i].Name)" }
    Write-Host ""
    Write-Host "ASK BEFORE REMOVING (some workflows depend on these):"
    for ($i = 0; $i -lt $askFound.Count; $i++) { Write-Menu "$($safeFound.Count + $i + 1)" "$($askFound[$i].Name)" }
    Write-Host ""
    Write-Menu "A" "Select all SAFE apps only"
    Write-Menu "C" "Custom selection" "(comma-separated numbers)"
    Write-Menu "B" "Back - no changes"
    $choice = Read-Host "Choice"

    $toRemove = @()
    $all = $safeFound + $askFound
    if ($choice -match '^[Aa]$') {
        $toRemove = $safeFound
    } elseif ($choice -match '^[Cc]$') {
        $nums = Read-Host "Enter numbers to remove (e.g. 1,3,4)"
        $indices = $nums -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ - 1 }
        foreach ($idx in $indices) { if ($idx -ge 0 -and $idx -lt $all.Count) { $toRemove += $all[$idx] } }
    } else {
        Write-Tag INFO "No changes made."
        Read-Host "Press Enter to return"
        return
    }

    if ($toRemove.Count -eq 0) {
        Write-Tag INFO "Nothing selected. No changes made."
        Read-Host "Press Enter to return"
        return
    }

    $preview = $toRemove | ForEach-Object { "Remove application: $($_.Name)" }
    if (-not (Confirm-Changes -Changes $preview)) {
        Write-Tag INFO "Cancelled - no changes made."
        Read-Host "Press Enter to return"
        return
    }

    New-BackupSession | Out-Null
    foreach ($app in $toRemove) {
        try {
            Get-AppxPackage -Name "*$($app.Id)*" -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction Stop
            Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*$($app.Id)*" } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
            Record-AppxRemoval -Name $app.Id
            Write-Tag OK "Removed $($app.Name)"
            $Script:Counters.Success++
        } catch {
            Write-Tag FAIL "$($app.Name) ($($_.Exception.Message))"
            $Script:Counters.Failed++
        }
    }
    Read-Host "Press Enter to return"
}

# ---------------------------------------------------------------
# PRIVACY
# ---------------------------------------------------------------

function Invoke-Privacy {
    while ($true) {
        Clear-Host
        Show-Header "PRIVACY OPTIONS"
        Write-Menu "1" "Advertising ID"
        Write-Menu "2" "Diagnostic data reduction"
        Write-Menu "3" "Tailored experiences"
        Write-Menu "4" "Feedback notifications"
        Write-Menu "5" "Search personalization" "(Cortana / web search)"
        Write-Menu "6" "View current configuration"
        Write-Menu "B" "Back"
        $c = Read-Host "Choice"
        switch ($c) {
            "1" { Toggle-PrivacySetting -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Type DWord -OffValue 0 -OnValue 1 -Description "Advertising ID lets apps show personalized ads using an ID tied to your account." }
            "2" { Toggle-PrivacySetting -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Type DWord -OffValue 0 -OnValue 3 -Description "Reduces diagnostic/telemetry collection where supported. Does not guarantee zero data is ever sent." }
            "3" { Toggle-PrivacySetting -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" -Name "TailoredExperiencesWithDiagnosticDataEnabled" -Type DWord -OffValue 0 -OnValue 1 -Description "Stops Windows from using your diagnostic data to suggest tips/ads." }
            "4" { Toggle-PrivacySetting -Path "HKCU:\Software\Microsoft\Siuf\Rules" -Name "NumberOfSIUFInPeriod" -Type DWord -OffValue 0 -OnValue -1 -Description "Reduces how often Windows asks for feedback." }
            "5" { Invoke-SearchPersonalization }
            "6" { Show-PrivacyStatus }
            { $_ -match '^[Bb]$' } { return }
            default { Write-Tag WARN "Invalid choice"; Start-Sleep -Seconds 1 }
        }
    }
}

function Toggle-PrivacySetting {
    param([string]$Path, [string]$Name, [string]$Type, $OffValue, $OnValue, [string]$Description)
    Clear-Host
    $current = try { (Get-ItemProperty $Path -Name $Name -ErrorAction Stop).$Name } catch { "Not set (default)" }
    Write-Host "CURRENT: $current"
    Write-Host "DESCRIPTION: $Description"
    Write-Host ""
    Write-Menu "1" "Turn OFF" "(value = $OffValue)"
    Write-Menu "2" "Turn ON" "(value = $OnValue)"
    Write-Menu "B" "Back"
    $c = Read-Host "Choice"
    if ($c -eq "1") {
        if (Confirm-Changes -Changes @("$Name : $current -> $OffValue")) {
            New-BackupSession | Out-Null
            Set-RegTracked -Path $Path -Name $Name -Value $OffValue -Type $Type -Description "Disabled: $Name"
        }
    } elseif ($c -eq "2") {
        if (Confirm-Changes -Changes @("$Name : $current -> $OnValue")) {
            New-BackupSession | Out-Null
            Set-RegTracked -Path $Path -Name $Name -Value $OnValue -Type $Type -Description "Enabled: $Name"
        }
    }
    Read-Host "Press Enter to continue"
}

function Invoke-SearchPersonalization {
    Clear-Host
    $gen = Get-WinGeneration
    if ($gen -eq 11) { Write-Host "Web results in Start Menu search (Windows 11)." } else { Write-Host "Cortana / web results in Start Menu search (Windows 10)." }
    $c = Read-Host "Disable? [y/N]"
    if ($c -match '^(y|yes)$') {
        if ($gen -eq 11) {
            if (Confirm-Changes -Changes @("Turn off web results in Start Menu search")) {
                New-BackupSession | Out-Null
                Set-RegTracked -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Value 1 -Type DWord -Description "Web results in Start search off"
            }
        } else {
            if (Confirm-Changes -Changes @("Disable Cortana", "Disable Bing web search in Start Menu")) {
                New-BackupSession | Out-Null
                Set-RegTracked -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Value 0 -Type DWord -Description "Cortana disabled"
                Set-RegTracked -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchEnabled" -Value 0 -Type DWord -Description "Web search in Start Menu disabled"
            }
        }
    }
    Read-Host "Press Enter to continue"
}

function Show-PrivacyStatus {
    Clear-Host
    Write-Host "CURRENT PRIVACY CONFIGURATION"
    Write-Host ""
    $paths = @(
        @{ P = "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"; N = "Enabled"; L = "Advertising ID" },
        @{ P = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; N = "AllowTelemetry"; L = "Diagnostic data policy" },
        @{ P = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"; N = "TailoredExperiencesWithDiagnosticDataEnabled"; L = "Tailored experiences" },
        @{ P = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; N = "BingSearchEnabled"; L = "Web search (Win10 setting)" },
        @{ P = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; N = "DisableSearchBoxSuggestions"; L = "Web search off (Win11 policy)" }
    )
    foreach ($p in $paths) {
        $val = try { (Get-ItemProperty $p.P -Name $p.N -ErrorAction Stop).($p.N) } catch { "Default" }
        Write-Host ("  {0,-28}: {1}" -f $p.L, $val)
    }
    Read-Host "Press Enter to continue"
}

# ---------------------------------------------------------------
# PERFORMANCE / POWER PLAN / VISUAL EFFECTS / SEARCH
# ---------------------------------------------------------------

function Invoke-Performance {
    while ($true) {
        Clear-Host
        Show-Header "PERFORMANCE"
        Write-Menu "1" "Power Plan"
        Write-Menu "2" "Visual Effects"
        Write-Menu "3" "Windows Search"
        Write-Menu "4" "Storage Cleanup" "(see Cleanup menu)"
        Write-Menu "B" "Back"
        $c = Read-Host "Choice"
        switch ($c) {
            "1" { Invoke-PowerPlanMenu }
            "2" { Invoke-VisualEffectsMenu }
            "3" { Invoke-WindowsSearchMenu }
            "4" { Write-Tag INFO "See main menu option 9 - Cleanup."; Start-Sleep -Seconds 1 }
            { $_ -match '^[Bb]$' } { return }
            default { Write-Tag WARN "Invalid choice"; Start-Sleep -Seconds 1 }
        }
    }
}

function Get-PowerPlans {
    $raw = powercfg /list
    $plans = @()
    foreach ($line in $raw) {
        if ($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+\(([^)]+)\)(\s*\*)?') {
            $plans += [pscustomobject]@{ Guid = $Matches[1]; Name = $Matches[2]; Active = [bool]$Matches[3] }
        }
    }
    return $plans
}

function Invoke-PowerPlanMenu {
    Clear-Host
    $plans = Get-PowerPlans
    $current = $plans | Where-Object { $_.Active }
    Write-Host "Current Power Plan: $($current.Name)"
    Write-Host ""
    Write-Host "Power plans affect power/performance behavior and may increase power consumption."
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($battery) {
        Write-Tag WARN "This device has a battery. High Performance may increase power consumption, heat, and fan activity."
    }
    Write-Host ""
    for ($i = 0; $i -lt $plans.Count; $i++) { Write-Menu "$($i+1)" "$($plans[$i].Name)" }
    Write-Menu "R" "Restore original" "(from last backup)"
    Write-Menu "B" "Back"
    $c = Read-Host "Choice"
    if ($c -match '^[Rr]$') {
        Restore-PowerPlanFromBackup
        Read-Host "Press Enter to continue"
        return
    }
    if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $plans.Count) {
        $target = $plans[[int]$c - 1]
        if (Confirm-Changes -Changes @("Power plan: $($current.Name) -> $($target.Name)")) {
            New-BackupSession | Out-Null
            Backup-PowerPlanState
            try {
                powercfg -setactive $target.Guid
                Write-Tag OK "Power plan set to $($target.Name)"
                $Script:Counters.Success++
            } catch {
                Write-Tag FAIL "Could not set power plan"
                $Script:Counters.Failed++
            }
        }
    }
    Read-Host "Press Enter to continue"
}

function Invoke-VisualEffectsMenu {
    Clear-Host
    Write-Menu "1" "Windows default" "(let Windows choose)"
    Write-Menu "2" "Performance-oriented" "(disable animations/transparency)"
    Write-Menu "B" "Back"
    $c = Read-Host "Choice"
    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
    if ($c -eq "1") {
        if (Confirm-Changes -Changes @("Visual effects -> Windows default")) {
            New-BackupSession | Out-Null
            Set-RegTracked -Path $path -Name "VisualFXSetting" -Value 0 -Type DWord -Description "Visual effects: Windows default"
        }
    } elseif ($c -eq "2") {
        if (Confirm-Changes -Changes @("Visual effects -> Best performance (fewer animations/transparency)")) {
            New-BackupSession | Out-Null
            Set-RegTracked -Path $path -Name "VisualFXSetting" -Value 2 -Type DWord -Description "Visual effects: best performance"
        }
    }
    Read-Host "Press Enter to continue"
}

function Invoke-WindowsSearchMenu {
    Clear-Host
    $svc = Get-Service -Name WSearch -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Tag SKIP "Windows Search service not present."; Read-Host "Press Enter"; return }
    $wmi = Get-CimInstance Win32_Service -Filter "Name='WSearch'"
    Write-Host "Windows Search is currently:"
    Write-Host "  State   : $($svc.Status)"
    Write-Host "  Startup : $($wmi.StartMode)"
    Write-Host ""
    Write-Host "Disabling Windows Search can reduce indexing activity but can"
    Write-Host "also reduce search functionality in Start Menu and File Explorer."
    Write-Host ""
    Write-Menu "1" "Disable"
    Write-Menu "2" "Enable" "(Automatic, delayed start - the Windows default)"
    Write-Menu "B" "Back"
    $c = Read-Host "Choice"
    if ($c -eq "1") {
        if (Confirm-Changes -Changes @("WSearch: $($wmi.StartMode) -> Disabled")) {
            New-BackupSession | Out-Null
            Set-ServiceTracked -Name "WSearch" -StartupType Disabled -FriendlyName "Windows Search"
        }
    } elseif ($c -eq "2") {
        if (Confirm-Changes -Changes @("WSearch: $($wmi.StartMode) -> Automatic (Delayed Start)")) {
            New-BackupSession | Out-Null
            Set-ServiceTracked -Name "WSearch" -StartupType AutomaticDelayed -FriendlyName "Windows Search"
        }
    }
    Read-Host "Press Enter to continue"
}

function Restore-PowerPlanFromBackup {
    $latest = Get-ChildItem $Script:BackupsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { Write-Tag SKIP "No backup found."; return }
    $manifest = Join-Path $latest.FullName "manifest.txt"
    $line = Get-Content $manifest | Where-Object { $_ -like "POWERPLAN|*" } | Select-Object -Last 1
    if (-not $line) { Write-Tag SKIP "No original power plan recorded in latest backup."; return }
    $guid = ($line -split '\|')[1]
    try {
        powercfg -setactive $guid
        Write-Tag OK "Power plan restored to original (GUID $guid)"
    } catch {
        Write-Tag FAIL "Could not restore power plan"
    }
}

# ---------------------------------------------------------------
# GAMING OPTIMIZATION
# ---------------------------------------------------------------

function Invoke-Gaming {
    while ($true) {
        Clear-Host
        Show-Header "GAMING OPTIMIZATION"
        $info = Get-SysInfo
        Write-Host "Game Mode: $($info['Game Mode'])   HAGS: $($info['HAGS'])   Power Plan: $($info['Power Plan'])"
        Write-Host ""
        Write-Menu "1" "Game Mode"
        Write-Menu "2" "Game DVR / Background Recording"
        Write-Menu "3" "Hardware-Accelerated GPU Scheduling" "(HAGS)"
        Write-Menu "4" "Power Plan" "(see Performance menu)"
        Write-Menu "B" "Back"
        $c = Read-Host "Choice"
        switch ($c) {
            "1" {
                $on = Read-Host "Enable Game Mode? [y/N]"
                if ($on -match '^(y|yes)$') {
                    if (Confirm-Changes -Changes @("Game Mode -> Enabled")) {
                        New-BackupSession | Out-Null
                        Set-RegTracked -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 1 -Type DWord -Description "Game Mode enabled"
                        Set-RegTracked -Path "HKCU:\Software\Microsoft\GameBar" -Name "AllowAutoGameMode" -Value 1 -Type DWord -Description "Game Mode allowed"
                    }
                }
            }
            "2" {
                $off = Read-Host "Disable Game DVR/overlay capture? [y/N]"
                if ($off -match '^(y|yes)$') {
                    if (Confirm-Changes -Changes @("Game DVR -> Disabled")) {
                        New-BackupSession | Out-Null
                        Set-RegTracked -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Value 0 -Type DWord -Description "Game DVR capture disabled"
                        Set-RegTracked -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -Type DWord -Description "GameConfigStore DVR disabled"
                    }
                }
            }
            "3" { Invoke-HagsMenu }
            "4" { Invoke-PowerPlanMenu }
            { $_ -match '^[Bb]$' } { return }
            default { Write-Tag WARN "Invalid choice"; Start-Sleep -Seconds 1 }
        }
    }
}

function Invoke-HagsMenu {
    Clear-Host
    $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    if ($build -lt 19041) {
        Write-Tag SKIP "HAGS needs Windows 10 version 2004 (build 19041) or later. Not available on this build."
        Read-Host "Press Enter to continue"
        return
    }
    Write-Host "HAGS behavior depends on your Windows version and GPU driver."
    Write-Host "It does not guarantee a specific FPS improvement - effects vary by system."
    Write-Host ""
    Write-Menu "1" "Enable"
    Write-Menu "2" "Disable"
    Write-Menu "B" "Back"
    $c = Read-Host "Choice"
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    if ($c -eq "1") {
        if (Confirm-Changes -Changes @("HAGS -> Enabled (restart required)")) {
            New-BackupSession | Out-Null
            Set-RegTracked -Path $path -Name "HwSchMode" -Value 2 -Type DWord -Description "HAGS enabled"
            $Script:RestartNeeded = $true
            $Script:RestartReasons.Add("HAGS change")
        }
    } elseif ($c -eq "2") {
        if (Confirm-Changes -Changes @("HAGS -> Disabled (restart required)")) {
            New-BackupSession | Out-Null
            Set-RegTracked -Path $path -Name "HwSchMode" -Value 1 -Type DWord -Description "HAGS disabled"
            $Script:RestartNeeded = $true
            $Script:RestartReasons.Add("HAGS change")
        }
    }
    Read-Host "Press Enter to continue"
}

# ---------------------------------------------------------------
# SERVICES (classified, existence-checked, per-service confirm)
# ---------------------------------------------------------------

$Script:ServiceCatalog = @(
    @{ Name = "DiagTrack"; Class = "SAFE"; Desc = "Connected User Experiences and Telemetry"; Impact = "Low - reduces telemetry upload" }
    @{ Name = "dmwappushservice"; Class = "SAFE"; Desc = "WAP push message routing"; Impact = "Low" }
    @{ Name = "MapsBroker"; Class = "SAFE"; Desc = "Downloaded Maps Manager"; Impact = "Low unless you use offline Maps" }
    @{ Name = "RetailDemo"; Class = "SAFE"; Desc = "Retail demo mode"; Impact = "None for normal use" }
    @{ Name = "Fax"; Class = "SAFE"; Desc = "Fax service"; Impact = "None unless you fax" }
    @{ Name = "RemoteRegistry"; Class = "SAFE"; Desc = "Allows remote registry access"; Impact = "Low - rarely needed, some security benefit to disabling" }
    @{ Name = "WSearch"; Class = "USER-DEPENDENT"; Desc = "Windows Search indexing"; Impact = "Slower Start Menu / Explorer search" }
    @{ Name = "SysMain"; Class = "USER-DEPENDENT"; Desc = "Superfetch/Prefetch caching"; Impact = "Depends on workload; mainly helps HDDs" }
    @{ Name = "XblAuthManager"; Class = "USER-DEPENDENT"; Desc = "Xbox Live Auth Manager"; Impact = "Breaks Xbox app / Game Pass sign-in" }
    @{ Name = "XblGameSave"; Class = "USER-DEPENDENT"; Desc = "Xbox Live Game Save"; Impact = "Breaks Xbox cloud saves" }
    @{ Name = "XboxNetApiSvc"; Class = "USER-DEPENDENT"; Desc = "Xbox Live Networking"; Impact = "Breaks Xbox multiplayer features" }
    @{ Name = "PhoneSvc"; Class = "USER-DEPENDENT"; Desc = "Phone service"; Impact = "Breaks Your Phone / cellular features" }
    @{ Name = "WerSvc"; Class = "USER-DEPENDENT"; Desc = "Windows Error Reporting"; Impact = "Loses crash diagnostic reporting" }
    @{ Name = "TabletInputService"; Class = "USER-DEPENDENT"; Desc = "Touch keyboard and handwriting"; Impact = "Breaks touch keyboard on 2-in-1 devices" }
)
$Script:DoNotTouchServices = @("wuauserv","WinDefend","RpcSs","PlugPlay","msiserver","Dnscache","Dhcp","BFE","LanmanWorkstation","LanmanServer")

function Invoke-Services {
    Clear-Host
    Show-Header "SERVICES"
    Write-Tag INFO "Windows Update, Defender, RPC, Plug and Play, and other core services are never shown here."
    Write-Host ""
    foreach ($entry in $Script:ServiceCatalog) {
        $svc = Get-Service -Name $entry.Name -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Tag SKIP "$($entry.Name) - not present on this system"
            continue
        }
        $wmi = Get-CimInstance Win32_Service -Filter "Name='$($entry.Name)'"
        Write-Host ""
        Write-Host "Service          : $($entry.Name)"
        Write-Host "Class            : $($entry.Class)"
        Write-Host "Current startup  : $($wmi.StartMode)"
        Write-Host "Current state    : $($svc.Status)"
        Write-Host "Description      : $($entry.Desc)"
        Write-Host "Potential impact : $($entry.Impact)"
        $ans = Read-Host "Disable this service? [y/N]"
        if ($ans -match '^(y|yes)$') {
            if (Confirm-Changes -Changes @("$($entry.Name): $($wmi.StartMode) -> Disabled")) {
                New-BackupSession | Out-Null
                Set-ServiceTracked -Name $entry.Name -StartupType Disabled -FriendlyName $entry.Name
            }
        }
    }
    Write-Host ""
    Read-Host "Press Enter to return"
}

# ---------------------------------------------------------------
# STARTUP APPS
# ---------------------------------------------------------------

function Get-StartupItems {
    $items = @()
    $runKeys = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    )
    foreach ($key in $runKeys) {
        if (Test-Path $key) {
            $props = Get-ItemProperty $key
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -notmatch '^PS(Path|ParentPath|ChildName|Provider)$' -and $p.Name -notlike "Disabled_*") {
                    $items += [pscustomobject]@{ Name = $p.Name; Command = $p.Value; Location = $key; Enabled = $true }
                } elseif ($p.Name -like "Disabled_*") {
                    $items += [pscustomobject]@{ Name = ($p.Name -replace '^Disabled_',''); Command = $p.Value; Location = $key; Enabled = $false }
                }
            }
        }
    }
    $folders = @(
        [Environment]::GetFolderPath('Startup'),
        [Environment]::GetFolderPath('CommonStartup')
    )
    foreach ($f in $folders) {
        if (Test-Path $f) {
            Get-ChildItem $f -File | ForEach-Object {
                $items += [pscustomobject]@{ Name = $_.BaseName; Command = $_.FullName; Location = $f; Enabled = $true }
            }
        }
    }
    return $items
}

function Invoke-StartupApps {
    while ($true) {
        Clear-Host
        Show-Header "STARTUP APPS"
        $items = Get-StartupItems
        if ($items.Count -eq 0) {
            Write-Tag INFO "No startup items found."
            Read-Host "Press Enter to return"
            return
        }
        for ($i = 0; $i -lt $items.Count; $i++) {
            $status = if ($items[$i].Enabled) { "Enabled" } else { "Disabled" }
            Write-Menu "$($i+1)" "$($items[$i].Name)" "[$status]"
            Write-Host "        Location: $($items[$i].Location)"
        }
        Write-Host ""
        Write-Host "  Enter a number to toggle enable/disable, or B to go back."
        $c = Read-Host "Choice"
        if ($c -match '^[Bb]$') { return }
        if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $items.Count) {
            $item = $items[[int]$c - 1]
            Toggle-StartupItem -Item $item
        }
    }
}

function Toggle-StartupItem {
    param($Item)
    New-BackupSession | Out-Null
    if ($Item.Location -like "HKCU:*" -or $Item.Location -like "HKLM:*") {
        try {
            if ($Item.Enabled) {
                Rename-ItemProperty -Path $Item.Location -Name $Item.Name -NewName "Disabled_$($Item.Name)" -ErrorAction Stop
                Write-Tag OK "Disabled startup entry: $($Item.Name)"
            } else {
                Rename-ItemProperty -Path $Item.Location -Name "Disabled_$($Item.Name)" -NewName $Item.Name -ErrorAction Stop
                Write-Tag OK "Enabled startup entry: $($Item.Name)"
            }
            $Script:Counters.Success++
        } catch {
            Write-Tag FAIL "Could not toggle $($Item.Name): $($_.Exception.Message)"
            $Script:Counters.Failed++
        }
    } else {
        # Startup folder shortcut - move to/from a disabled subfolder
        $disabledDir = Join-Path $Script:ProgramData "DisabledStartupItems"
        if (-not (Test-Path $disabledDir)) { New-Item -ItemType Directory -Path $disabledDir -Force | Out-Null }
        try {
            if ($Item.Enabled) {
                Move-Item -Path $Item.Command -Destination $disabledDir -Force
                Write-Tag OK "Disabled startup shortcut: $($Item.Name)"
            } else {
                Move-Item -Path $Item.Command -Destination $Item.Location -Force
                Write-Tag OK "Enabled startup shortcut: $($Item.Name)"
            }
            $Script:Counters.Success++
        } catch {
            Write-Tag FAIL "Could not toggle $($Item.Name): $($_.Exception.Message)"
            $Script:Counters.Failed++
        }
    }
    Start-Sleep -Seconds 1
}

# ---------------------------------------------------------------
# CLEANUP
# ---------------------------------------------------------------

function Invoke-Cleanup {
    if (-not (Require-Admin "Cleanup")) { return }
    while ($true) {
        Clear-Host
        Show-Header "CLEANUP"
        Write-Menu "1" "User temporary files"
        Write-Menu "2" "Windows temporary files"
        Write-Menu "3" "Windows Update cache" "(may affect update troubleshooting)"
        Write-Menu "4" "Delivery Optimization cache"
        Write-Menu "5" "Thumbnail cache"
        Write-Menu "6" "Recycle Bin" "(confirmation required)"
        Write-Menu "7" "Analyze storage sizes"
        Write-Menu "B" "Back"
        Write-Tag INFO "Prefetch is intentionally never touched by this tool - it is managed by Windows."
        $c = Read-Host "Choice"
        switch ($c) {
            "1" { Clear-FolderSafely -Path $env:TEMP -Label "User temp files" }
            "2" { Clear-FolderSafely -Path "$env:SystemRoot\Temp" -Label "Windows temp files" }
            "3" {
                Write-Tag WARN "This may remove files needed to resume an in-progress Windows Update."
                $c2 = Read-Host "Continue? [y/N]"
                if ($c2 -match '^(y|yes)$') {
                    $wuWasRunning = ((Get-Service wuauserv -ErrorAction SilentlyContinue).Status -eq 'Running')
                    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
                    Clear-FolderSafely -Path "$env:SystemRoot\SoftwareDistribution\Download" -Label "Windows Update cache"
                    if ($wuWasRunning) { Start-Service wuauserv -ErrorAction SilentlyContinue }
                }
            }
            "4" {
                if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
                    try {
                        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
                        Write-Tag OK "Delivery Optimization cache cleared"
                        $Script:Counters.Success++
                    } catch {
                        Write-Tag FAIL "Delivery Optimization cache ($($_.Exception.Message))"
                        $Script:Counters.Failed++
                    }
                } else {
                    Clear-FolderSafely -Path "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" -Label "Delivery Optimization cache"
                }
            }
            "5" { Clear-FolderSafely -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Label "Thumbnail cache" -Filter "thumbcache_*.db" }
            "6" {
                $c2 = Read-Host "Empty Recycle Bin? [y/N]"
                if ($c2 -match '^(y|yes)$') {
                    try {
                        Clear-RecycleBin -Force -ErrorAction Stop
                        Write-Tag OK "Recycle Bin emptied"
                        $Script:Counters.Success++
                    } catch {
                        Write-Tag FAIL "Could not empty Recycle Bin"
                        $Script:Counters.Failed++
                    }
                } else {
                    Write-Tag INFO "No changes made."
                }
            }
            "7" {
                Write-Host ("User Temp        : {0:N1} MB" -f ((Get-FolderSize $env:TEMP)/1MB))
                Write-Host ("Windows Temp     : {0:N1} MB" -f ((Get-FolderSize "$env:SystemRoot\Temp")/1MB))
                Write-Host ("Update Cache     : {0:N1} MB" -f ((Get-FolderSize "$env:SystemRoot\SoftwareDistribution\Download")/1MB))
            }
            { $_ -match '^[Bb]$' } { return }
            default { Write-Tag WARN "Invalid choice" }
        }
        Start-Sleep -Milliseconds 800
    }
}

function Clear-FolderSafely {
    param([string]$Path, [string]$Label, [string]$Filter = "*")
    if (-not (Test-Path $Path)) { Write-Tag SKIP "$Label - path not found"; return }
    try {
        Get-ChildItem -Path $Path -Filter $Filter -Recurse -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        Write-Tag OK "$Label cleared"
        $Script:Counters.Success++
    } catch {
        Write-Tag FAIL "$Label ($($_.Exception.Message))"
        $Script:Counters.Failed++
    }
}

# ---------------------------------------------------------------
# NETWORK
# ---------------------------------------------------------------

function Invoke-Network {
    while ($true) {
        Clear-Host
        Show-Header "NETWORK"
        Write-Menu "1" "Show IP configuration"
        Write-Menu "2" "DNS server information"
        Write-Menu "3" "Ping test"
        Write-Menu "4" "Flush DNS cache"
        Write-Menu "5" "Reset Winsock" "(requires confirmation + restart)"
        Write-Menu "6" "Reset TCP/IP" "(requires confirmation + restart)"
        Write-Menu "7" "Network adapter information"
        Write-Menu "B" "Back"
        $c = Read-Host "Choice"
        switch ($c) {
            "1" { Get-NetIPConfiguration | Format-List | Out-Host }
            "2" { Get-DnsClientServerAddress | Format-Table -AutoSize | Out-Host }
            "3" { $target = Read-Host "Host to ping"; Test-Connection -ComputerName $target -Count 4 | Out-Host }
            "4" { ipconfig /flushdns | Out-Null; Write-Tag OK "DNS cache flushed" }
            "5" {
                if ((Require-Admin "Winsock reset") -and ((Read-Host "This resets Winsock catalog. Confirm? [y/N]") -match '^(y|yes)$')) {
                    netsh winsock reset | Out-Null
                    Write-Tag OK "Winsock reset (restart required)"
                    $Script:RestartNeeded = $true
                    $Script:RestartReasons.Add("Winsock reset")
                }
            }
            "6" {
                if ((Require-Admin "TCP/IP reset") -and ((Read-Host "This resets the TCP/IP stack. Confirm? [y/N]") -match '^(y|yes)$')) {
                    netsh int ip reset | Out-Null
                    Write-Tag OK "TCP/IP reset (restart required)"
                    $Script:RestartNeeded = $true
                    $Script:RestartReasons.Add("TCP/IP reset")
                }
            }
            "7" { Get-NetAdapter | Format-Table -AutoSize | Out-Host }
            { $_ -match '^[Bb]$' } { return }
            default { Write-Tag WARN "Invalid choice" }
        }
        Read-Host "Press Enter to continue"
    }
}

# ---------------------------------------------------------------
# WINDOWS MAINTENANCE
# ---------------------------------------------------------------

function Invoke-Maintenance {
    if (-not (Require-Admin "Windows Maintenance")) { return }
    while ($true) {
        Clear-Host
        Show-Header "WINDOWS MAINTENANCE"
        Write-Menu "1" "CHECK  - DISM CheckHealth" "(fast, read-only)"
        Write-Menu "2" "CHECK  - DISM ScanHealth" "(slower, read-only)"
        Write-Menu "3" "REPAIR - DISM RestoreHealth" "(downloads fixes, confirmation required)"
        Write-Menu "4" "REPAIR - SFC /scannow" "(confirmation required)"
        Write-Menu "5" "CLEANUP - Component store cleanup" "(confirmation required)"
        Write-Menu "6" "Storage analysis"
        Write-Menu "B" "Back"
        $c = Read-Host "Choice"
        switch ($c) {
            "1" { DISM /Online /Cleanup-Image /CheckHealth }
            "2" { DISM /Online /Cleanup-Image /ScanHealth }
            "3" {
                if ((Read-Host "This may download files and take a while. Confirm? [y/N]") -match '^(y|yes)$') {
                    DISM /Online /Cleanup-Image /RestoreHealth
                }
            }
            "4" {
                if ((Read-Host "SFC scan can take several minutes. Confirm? [y/N]") -match '^(y|yes)$') {
                    sfc /scannow
                }
            }
            "5" {
                if ((Read-Host "This removes superseded component versions. Confirm? [y/N]") -match '^(y|yes)$') {
                    DISM /Online /Cleanup-Image /StartComponentCleanup
                }
            }
            "6" {
                Get-PSDrive -PSProvider FileSystem | Format-Table Name, @{L="Used(GB)";E={[math]::Round($_.Used/1GB,1)}}, @{L="Free(GB)";E={[math]::Round($_.Free/1GB,1)}} -AutoSize | Out-Host
            }
            { $_ -match '^[Bb]$' } { return }
            default { Write-Tag WARN "Invalid choice" }
        }
        Read-Host "Press Enter to continue"
    }
}

# ---------------------------------------------------------------
# BACKUP / RESTORE
# ---------------------------------------------------------------

function Invoke-BackupRestoreMenu {
    while ($true) {
        Clear-Host
        Show-Header "BACKUP / RESTORE"
        Write-Menu "1" "Restore latest backup"
        Write-Menu "2" "Choose a backup to restore"
        Write-Menu "3" "View a backup's manifest"
        Write-Menu "4" "Delete old backups"
        Write-Menu "B" "Back"
        $c = Read-Host "Choice"
        switch ($c) {
            "1" { Restore-FromBackup -BackupDir (Get-LatestBackupDir) }
            "2" {
                $dirs = Get-ChildItem $Script:BackupsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
                if (-not $dirs) { Write-Tag SKIP "No backups found."; Start-Sleep -Seconds 1; continue }
                for ($i=0; $i -lt $dirs.Count; $i++) { Write-Menu "$($i+1)" "$($dirs[$i].Name)" }
                $sel = Read-Host "Choose a backup number"
                if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $dirs.Count) {
                    Restore-FromBackup -BackupDir $dirs[[int]$sel-1].FullName
                }
            }
            "3" {
                $dir = Get-LatestBackupDir
                if ($dir) { Get-Content (Join-Path $dir "manifest.txt") | Out-Host } else { Write-Tag SKIP "No backups found." }
                Read-Host "Press Enter to continue"
            }
            "4" {
                $dirs = Get-ChildItem $Script:BackupsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -Skip 5
                if (-not $dirs) { Write-Tag INFO "Nothing to delete (5 or fewer backups kept)." }
                else {
                    foreach ($d in $dirs) { Remove-Item $d.FullName -Recurse -Force; Write-Tag OK "Deleted $($d.Name)" }
                }
                Start-Sleep -Seconds 1
            }
            { $_ -match '^[Bb]$' } { return }
            default { Write-Tag WARN "Invalid choice" }
        }
    }
}

function Get-LatestBackupDir {
    Get-ChildItem $Script:BackupsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
}

function Restore-FromBackup {
    param([string]$BackupDir)
    if (-not $BackupDir -or -not (Test-Path $BackupDir)) { Write-Tag SKIP "No backup found."; Start-Sleep -Seconds 1; return }
    $manifest = Join-Path $BackupDir "manifest.txt"
    if (-not (Test-Path $manifest)) { Write-Tag SKIP "manifest.txt missing in this backup."; Start-Sleep -Seconds 1; return }
    if (-not (Require-Admin "Restore")) { return }
    Write-Host "Restoration may require a restart."
    $restoreAns = Read-Host "Proceed with restore from $BackupDir? [y/N]"
    if ($restoreAns -notmatch '^(y|yes)$') {
        Write-Tag INFO "Restore cancelled - no changes made."
        Start-Sleep -Seconds 1
        return
    }

    Get-Content $manifest | ForEach-Object {
        $parts = $_ -split '\|'
        switch ($parts[0]) {
            "SERVICE" {
                $name = $parts[1]
                $mode = switch -Regex ($parts[2]) {
                    '^(auto|automatic)$' { 'auto' }
                    '^delayed-auto$'     { 'delayed-auto' }
                    '^(demand|manual)$'  { 'demand' }
                    '^disabled$'         { 'disabled' }
                    default              { 'keep' }
                }
                $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
                if ($svc) {
                    if (Set-ServiceMode -Name $name -Mode $mode) {
                        if ($parts[3] -eq 'Running') { Start-Service -Name $name -ErrorAction SilentlyContinue }
                        Write-Tag OK "Restored service $name -> $mode (was $($parts[3]))"
                    } else { Write-Tag FAIL "Could not restore $name" }
                } else { Write-Tag SKIP "$name not present" }
            }
            "REGISTRY" {
                $path = $parts[1]; $name = $parts[2]; $val = $parts[3]; $type = $parts[4]; $existed = $parts[5]
                if ($existed -eq "True" -and $type -notin @('DWord','QWord','String','ExpandString')) {
                    Write-Tag SKIP "Not restorable automatically (type $type): $path\$name"
                    return
                }
                try {
                    if ($existed -eq "True") {
                        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
                        New-ItemProperty -Path $path -Name $name -Value $val -PropertyType $type -Force | Out-Null
                        Write-Tag OK "Restored registry $path\$name"
                    } else {
                        if (Test-Path $path) { Remove-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue }
                        Write-Tag OK "Removed registry value $path\$name (it did not exist originally)"
                    }
                } catch { Write-Tag FAIL "Could not restore $path\$name" }
            }
            "POWERPLAN" {
                try { powercfg -setactive $parts[1]; Write-Tag OK "Restored original power plan" }
                catch { Write-Tag FAIL "Could not restore power plan" }
            }
            "TASK" {
                try {
                    $full = $parts[1]
                    $tp = Split-Path $full -Parent
                    $tn = Split-Path $full -Leaf
                    if ($parts[2] -eq "Ready" -or $parts[2] -eq "Enabled") {
                        Enable-ScheduledTask -TaskName $tn -TaskPath "$tp\" -ErrorAction SilentlyContinue | Out-Null
                    }
                    Write-Tag OK "Restored task state: $full"
                } catch { Write-Tag FAIL "Could not restore task" }
            }
            "APPX" {
                Write-Tag INFO "App reinstall not automatic - see the app's Microsoft Store page for: $($parts[1])"
            }
        }
    }
    Write-Host ""
    Write-Tag INFO "Restore pass complete. Verify affected settings and restart if needed."
    Read-Host "Press Enter to continue"
}

# ---------------------------------------------------------------
# CHANGE LOG
# ---------------------------------------------------------------

function Show-ChangeLog {
    Clear-Host
    Show-Header "CHANGE LOG"
    Write-Menu "1" "View latest session log"
    Write-Menu "2" "View all session logs"
    Write-Menu "3" "Restore latest backup"
    Write-Menu "B" "Back"
    $c = Read-Host "Choice"
    switch ($c) {
        "1" {
            $latest = Get-ChildItem $Script:LogsDir -Filter "*.log" -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
            if ($latest) { Get-Content $latest.FullName | Out-Host } else { Write-Tag SKIP "No logs found." }
            Read-Host "Press Enter to continue"
        }
        "2" {
            Get-ChildItem $Script:LogsDir -Filter "*.log" -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object {
                Write-Host "----- $($_.Name) -----"
                Get-Content $_.FullName | Out-Host
            }
            Read-Host "Press Enter to continue"
        }
        "3" { Restore-FromBackup -BackupDir (Get-LatestBackupDir) }
    }
}

# ---------------------------------------------------------------
# SETTINGS (config.ini) + ADVANCED MODE
# ---------------------------------------------------------------

function Read-ConfigIni {
    $config = @{}
    if (-not $Script:ConfigPath -or -not (Test-Path $Script:ConfigPath)) { return $config }
    $section = ""
    foreach ($line in Get-Content $Script:ConfigPath) {
        $line = $line.Trim()
        if ($line -match '^\[(.+)\]$') { $section = $Matches[1]; $config[$section] = @{} }
        elseif ($line -match '^([^=]+)=(.*)$' -and $section) { $config[$section][$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    return $config
}

function Invoke-Settings {
    Clear-Host
    Show-Header "SETTINGS"
    if ($Script:ConfigPath -and (Test-Path $Script:ConfigPath)) {
        Write-Host "config.ini found at: $Script:ConfigPath"
        Write-Host ""
        Get-Content $Script:ConfigPath | Out-Host
    } else {
        Write-Tag INFO "No config.ini found - using safe built-in defaults for every prompt."
        Write-Host "You can place a config.ini next to this script to pre-fill some prompts."
        Write-Host "Destructive options (Recycle Bin, service disabling) still ask before applying."
    }
    Write-Host ""
    Write-Host "Toolkit version: $Script:Version"
    Read-Host "Press Enter to return"
}

function Invoke-AdvancedMode {
    Clear-Host
    Show-Header "ADVANCED MODE"
    Write-Tag WARN "Advanced settings can affect Windows functionality and stability."
    Write-Tag WARN "Create a backup before continuing."
    Write-Host ""
    Write-Menu "1" "Disable Superfetch/SysMain  [RISK: LOW-MEDIUM] [REVERSIBLE: YES] [RESTART: NO]"
    Write-Host "     Mainly helps HDDs; on SSDs often has little effect either way."
    Write-Menu "2" "Disable Windows Error Reporting service  [RISK: LOW] [REVERSIBLE: YES] [RESTART: NO]"
    Write-Host "     You lose automatic crash diagnostic collection."
    Write-Menu "3" "Disable Delivery Optimization (P2P Windows Update)  [RISK: LOW] [REVERSIBLE: YES] [RESTART: NO]"
    Write-Host "     Windows Update won't share/fetch update bytes with other PCs on your network/internet."
    Write-Menu "B" "Back"
    $c = Read-Host "Choice"
    switch ($c) {
        "1" {
            if (Confirm-Changes -Changes @("SysMain -> Disabled")) {
                New-BackupSession | Out-Null
                Set-ServiceTracked -Name "SysMain" -StartupType Disabled -FriendlyName "SysMain (Superfetch)"
            }
        }
        "2" {
            if (Confirm-Changes -Changes @("WerSvc -> Disabled")) {
                New-BackupSession | Out-Null
                Set-ServiceTracked -Name "WerSvc" -StartupType Disabled -FriendlyName "Windows Error Reporting"
            }
        }
        "3" {
            if (Confirm-Changes -Changes @("Delivery Optimization -> HTTP only, no peer sharing (DODownloadMode=0)")) {
                New-BackupSession | Out-Null
                Set-RegTracked -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Value 0 -Type DWord -Description "Delivery Optimization: HTTP only, no peer sharing"
            }
        }
    }
    Read-Host "Press Enter to continue"
}


# ---------------------------------------------------------------
# RESOURCE MONITOR (RAM / CPU) - read-only view + opt-in memory trim
# ---------------------------------------------------------------

# Processes we never touch when trimming memory - critical to a running Windows session
$Script:CriticalProcesses = @(
    "System","Registry","Idle","smss","csrss","wininit","services","lsass",
    "winlogon","fontdrvhost","dwm","svchost","MemCompression","Secure System"
)

function Get-ResourceSnapshot {
    $procs = Get-Process -ErrorAction SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem
    $usedPct = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)
    [pscustomobject]@{
        TopRam      = $procs | Sort-Object WS -Descending | Select-Object -First 10 Name, Id,
                        @{N='RAM(MB)'; E={[math]::Round($_.WS/1MB,1)}}
        TopCpu      = $procs | Where-Object { $_.CPU } | Sort-Object CPU -Descending | Select-Object -First 10 Name, Id,
                        @{N='CPU(s)'; E={[math]::Round($_.CPU,1)}}
        ProcessCount = $procs.Count
        MemUsedPct   = $usedPct
        TotalRamGB   = [math]::Round($os.TotalVisibleMemorySize/1MB,1)
        FreeRamGB    = [math]::Round($os.FreePhysicalMemory/1MB,1)
    }
}

function Show-ResourceMonitor {
    while ($true) {
        Clear-Host
        Show-Header "Resource Monitor (RAM / CPU)"
        $snap = Get-ResourceSnapshot
        Write-KV 'Memory used' ("{0}%  ({1} GB free of {2} GB)" -f $snap.MemUsedPct, $snap.FreeRamGB, $snap.TotalRamGB)
        Write-KV 'Processes'   $snap.ProcessCount

        Write-Section 'Top 10 by RAM'
        $snap.TopRam | Format-Table -AutoSize | Out-String | Write-Host

        Write-Section 'Top 10 by CPU time (seconds, since each process started)'
        $snap.TopCpu | Format-Table -AutoSize | Out-String | Write-Host

        Write-Host 'This is a live snapshot - refresh to see current numbers.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Menu 'R' 'Refresh'
        Write-Menu 'T' 'Trim idle memory from background processes' '(temporary, safe, explained before running)'
        Write-Menu 'B' 'Back'
        $c = Read-Host 'Choice'
        if ($c -match '^[Rr]$') { continue }
        if ($c -match '^[Tt]$') { Invoke-MemoryTrim; continue }
        if ($c -match '^[Bb]$') { return }
    }
}

function Invoke-MemoryTrimAction {
    # Does the actual trim, no prompts - safe to call from a Quick Mode plan
    # or from the interactive screen below. Returns nothing; updates counters.
    $targets = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $Script:CriticalProcesses -notcontains $_.ProcessName -and $_.Id -ne $PID
    }
    try {
        Add-Type -Namespace DIVoptimizer -Name MemTrim -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("psapi.dll")]
public static extern bool EmptyWorkingSet(System.IntPtr hProcess);
'@ -ErrorAction Stop
    } catch { }

    $ok = 0; $skipped = 0
    foreach ($p in $targets) {
        try {
            if ([DIVoptimizer.MemTrim]::EmptyWorkingSet($p.Handle)) { $ok++ } else { $skipped++ }
        } catch { $skipped++ }
    }
    Write-Tag OK ("Trimmed {0} processes" -f $ok)
    if ($skipped -gt 0) { Write-Tag SKIP ("{0} processes could not be trimmed (protected or access denied)" -f $skipped) }
    $Script:Counters.Success += $ok
    $Script:Counters.Skipped += $skipped
}

function Invoke-MemoryTrim {
    Clear-Host
    Show-Header "Trim Idle Memory"
    Write-Host "This asks Windows to release RAM that background processes"
    Write-Host "have claimed but are not actively using right now (their"
    Write-Host "'working set'). It does not close or restart anything."
    Write-Host ""
    Write-Tag INFO "Effect is temporary - Windows will let busy processes reclaim"
    Write-Tag INFO "memory as soon as they need it again. This is not a permanent fix"
    Write-Tag INFO "for high RAM usage, just a one-time trim."
    Write-Host ""
    if (-not (Require-Admin "Memory trim")) { Read-Host "Press Enter to continue"; return }

    $targets = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $Script:CriticalProcesses -notcontains $_.ProcessName -and $_.Id -ne $PID
    })
    Write-Host ("This will attempt to trim {0} processes (system-critical processes are skipped)." -f $targets.Count)
    $go = Read-Host "Continue? [y/N]"
    if ($go -notmatch '^(y|yes)$') { Write-Tag INFO "Cancelled - no changes made."; Read-Host "Press Enter to continue"; return }

    Invoke-MemoryTrimAction
    Read-Host "Press Enter to continue"
}

# ---------------------------------------------------------------
# QUICK MODES (choose preset -> see full list -> confirm -> apply)
# ---------------------------------------------------------------

function Set-TaskTracked {
    param([string]$TaskPath, [string]$TaskName)
    if (-not (Backup-TaskState -TaskPath $TaskPath -TaskName $TaskName)) {
        Write-Tag SKIP "Task $TaskName not present"
        $Script:Counters.Skipped++
        return
    }
    try {
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        Write-Tag OK "Task disabled: $TaskName"
        $Script:Counters.Success++
    } catch {
        Write-Tag FAIL "Task $TaskName ($($_.Exception.Message))"
        $Script:Counters.Failed++
    }
}

function Get-QuickPlan {
    param([string]$Mode)
    $plan = New-Object System.Collections.Generic.List[object]
    $installed = Get-AppxPackage -ErrorAction SilentlyContinue

    # --- Apps (only ones actually installed) ---
    $appIds = @()
    if ($Mode -in @('Safe','Aggressive')) { $appIds += $Script:SafeApps }
    if ($Mode -eq 'Aggressive') { $appIds += $Script:AskApps }
    foreach ($id in $appIds) {
        $p = $installed | Where-Object { $_.Name -like "*$id*" } | Select-Object -First 1
        if ($p) { $plan.Add([pscustomobject]@{ Type = 'App'; Label = $p.Name; Id = $id }) }
    }

    # --- Services (only ones that exist and aren't already disabled) ---
    if ($Mode -eq 'Aggressive') {
        foreach ($entry in $Script:ServiceCatalog) {
            $svc = Get-Service -Name $entry.Name -ErrorAction SilentlyContinue
            if (-not $svc) { continue }
            $wmi = Get-CimInstance Win32_Service -Filter "Name='$($entry.Name)'" -ErrorAction SilentlyContinue
            if ($wmi -and $wmi.StartMode -eq 'Disabled') { continue }
            $plan.Add([pscustomobject]@{ Type = 'Service'; Label = "$($entry.Name) - $($entry.Desc)  ($($wmi.StartMode) -> Disabled)"; Id = $entry.Name })
        }
    }
    if ($Mode -eq 'LowResource') {
        $ramCpuServices = @(
            @{ Name = "SysMain";     Desc = "Superfetch/Prefetch memory caching" },
            @{ Name = "DiagTrack";   Desc = "Telemetry collection (background CPU)" },
            @{ Name = "dmwappushservice"; Desc = "WAP push message routing" },
            @{ Name = "MapsBroker";  Desc = "Downloaded Maps Manager" },
            @{ Name = "RetailDemo";  Desc = "Retail demo mode" },
            @{ Name = "WerSvc";      Desc = "Windows Error Reporting" },
            @{ Name = "WalletService"; Desc = "Wallet service" },
            @{ Name = "PhoneSvc";    Desc = "Phone service" },
            @{ Name = "TabletInputService"; Desc = "Touch keyboard and handwriting" }
        )
        foreach ($entry in $ramCpuServices) {
            $svc = Get-Service -Name $entry.Name -ErrorAction SilentlyContinue
            if (-not $svc) { continue }
            $wmi = Get-CimInstance Win32_Service -Filter "Name='$($entry.Name)'" -ErrorAction SilentlyContinue
            if ($wmi -and $wmi.StartMode -eq 'Disabled') { continue }
            $plan.Add([pscustomobject]@{ Type = 'Service'; Label = "$($entry.Name) - $($entry.Desc)  ($($wmi.StartMode) -> Disabled)"; Id = $entry.Name })
        }
    }

    # --- Registry settings ---
    $reg = @()
    if ($Mode -in @('Safe','Aggressive')) {
        $reg += @{ Label = "Advertising ID off"; Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"; Name = "Enabled"; Value = 0; Restart = $false }
        $reg += @{ Label = "Tailored experiences off"; Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"; Name = "TailoredExperiencesWithDiagnosticDataEnabled"; Value = 0; Restart = $false }
    }
    if ($Mode -eq 'Aggressive') {
        $reg += @{ Label = "Reduce diagnostic data collection (where supported)"; Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowTelemetry"; Value = 0; Restart = $false }
        if ((Get-WinGeneration) -eq 11) {
            $reg += @{ Label = "Web results in Start search off"; Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "DisableSearchBoxSuggestions"; Value = 1; Restart = $false }
        } else {
            $reg += @{ Label = "Cortana off"; Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCortana"; Value = 0; Restart = $false }
            $reg += @{ Label = "Web results in Start search off"; Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "BingSearchEnabled"; Value = 0; Restart = $false }
        }
    }
    if ($Mode -eq 'LowResource') {
        $reg += @{ Label = "Turn off background running for Store apps (older Windows setting - may not apply on newest Windows 11 builds)"; Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications"; Name = "GlobalUserDisabled"; Value = 1; Restart = $false }
        $reg += @{ Label = "Visual effects -> best performance (less GPU/CPU on animations)"; Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"; Name = "VisualFXSetting"; Value = 2; Restart = $false }
    }
    if ($Mode -eq 'Gaming') {
        $reg += @{ Label = "Game Mode on"; Path = "HKCU:\Software\Microsoft\GameBar"; Name = "AutoGameModeEnabled"; Value = 1; Restart = $false }
        $reg += @{ Label = "Game DVR background capture off"; Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AppCaptureEnabled"; Value = 0; Restart = $false }
        $reg += @{ Label = "Game DVR (GameConfigStore) off"; Path = "HKCU:\System\GameConfigStore"; Name = "GameDVR_Enabled"; Value = 0; Restart = $false }
        if ([int](Get-CimInstance Win32_OperatingSystem).BuildNumber -ge 19041) {
            $reg += @{ Label = "Hardware-accelerated GPU scheduling on (restart required)"; Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "HwSchMode"; Value = 2; Restart = $true }
        }
    }
    foreach ($r in $reg) {
        $plan.Add([pscustomobject]@{ Type = 'Registry'; Label = $r.Label; Path = $r.Path; Name = $r.Name; Value = $r.Value; Restart = $r.Restart })
    }

    # --- One-time memory trim (Low RAM & CPU only - not a persistent setting) ---
    if ($Mode -eq 'LowResource') {
        $liveCount = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $Script:CriticalProcesses -notcontains $_.ProcessName }).Count
        $plan.Add([pscustomobject]@{ Type = 'Trim'; Label = "Trim idle memory from ~$liveCount running processes right now (one-time, temporary)" })
    }

    # --- Scheduled tasks (telemetry-related, only if present) ---
    if ($Mode -eq 'Aggressive') {
        $tasks = @(
            @{ P = "\Microsoft\Windows\Application Experience\"; N = "Microsoft Compatibility Appraiser" },
            @{ P = "\Microsoft\Windows\Application Experience\"; N = "ProgramDataUpdater" },
            @{ P = "\Microsoft\Windows\Customer Experience Improvement Program\"; N = "Consolidator" },
            @{ P = "\Microsoft\Windows\Customer Experience Improvement Program\"; N = "UsbCeip" },
            @{ P = "\Microsoft\Windows\Feedback\Siuf\"; N = "DmClient" },
            @{ P = "\Microsoft\Windows\Feedback\Siuf\"; N = "DmClientOnScenarioDownload" }
        )
        foreach ($t in $tasks) {
            if (Get-ScheduledTask -TaskPath $t.P -TaskName $t.N -ErrorAction SilentlyContinue) {
                $plan.Add([pscustomobject]@{ Type = 'Task'; Label = $t.N; TaskPath = $t.P; TaskName = $t.N })
            }
        }
    }
    return $plan
}

function Show-QuickPlan {
    param($Plan, [string]$Title)
    Clear-Host
    Show-Header "$Title - WHAT WILL CHANGE"
    $groups = @(
        @{ T = 'App';      H = 'APPS THAT WILL BE REMOVED' },
        @{ T = 'Service';  H = 'SERVICES THAT WILL BE DISABLED' },
        @{ T = 'Task';     H = 'SCHEDULED TASKS THAT WILL BE DISABLED' },
        @{ T = 'Registry'; H = 'SETTINGS THAT WILL BE CHANGED' },
        @{ T = 'Trim';     H = 'ONE-TIME ACTIONS' }
    )
    foreach ($g in $groups) {
        $items = @($Plan | Where-Object { $_.Type -eq $g.T })
        if ($items.Count -eq 0) { continue }
        Write-Host ""
        Write-Host "$($g.H) ($($items.Count))" -ForegroundColor Cyan
        foreach ($i in $items) { Write-Host "  - $($i.Label)" }
    }
    Write-Host ""
    Write-Host "Only items actually found on this PC are listed." -ForegroundColor DarkGray
    Write-Host "Settings, services, and tasks can be undone from Backup / Restore." -ForegroundColor DarkGray
    Write-Host "Removed apps must be reinstalled from the Microsoft Store." -ForegroundColor DarkGray
    Write-Host ""
}

function Invoke-QuickPlan {
    param($Plan)
    New-BackupSession | Out-Null
    foreach ($item in $Plan) {
        switch ($item.Type) {
            'App' {
                try {
                    Get-AppxPackage -Name "*$($item.Id)*" -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction Stop
                    Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*$($item.Id)*" } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
                    Record-AppxRemoval -Name $item.Id
                    Write-Tag OK "Removed $($item.Label)"
                    $Script:Counters.Success++
                } catch {
                    Write-Tag FAIL "$($item.Label) ($($_.Exception.Message))"
                    $Script:Counters.Failed++
                }
            }
            'Service'  { Set-ServiceTracked -Name $item.Id -StartupType Disabled -FriendlyName $item.Id }
            'Task'     { Set-TaskTracked -TaskPath $item.TaskPath -TaskName $item.TaskName }
            'Registry' {
                Set-RegTracked -Path $item.Path -Name $item.Name -Value $item.Value -Type DWord -Description $item.Label
                if ($item.Restart) { $Script:RestartNeeded = $true; $Script:RestartReasons.Add($item.Label) }
            }
            'Trim' { Invoke-MemoryTrimAction }
        }
    }
}

function Invoke-QuickModes {
    while ($true) {
        Clear-Host
        Show-Header "QUICK MODES"
        Write-Host "  Pick a mode, review the full list, then choose to continue."
        Write-Host ""
        Write-Menu "1" "Safe Debloat" "(unused apps + basic privacy)"
        Write-Menu "2" "Aggressive Debloat" "(more apps, services, tasks, privacy)"
        Write-Menu "3" "Gaming" "(Game Mode, Game DVR, GPU scheduling)"
        Write-Menu "4" "Low RAM & CPU" "(background services, background apps, visual effects)"
        Write-Menu "B" "Back"
        $c = Read-Host "Choice"
        $mode = switch ($c) { "1" { "Safe" } "2" { "Aggressive" } "3" { "Gaming" } "4" { "LowResource" } default { $null } }
        if ($c -match '^[Bb]$') { return }
        if (-not $mode) { Write-Tag WARN "Invalid choice"; Start-Sleep -Seconds 1; continue }

        $plan = Get-QuickPlan -Mode $mode
        if ($plan.Count -eq 0) {
            Write-Tag INFO "Nothing to change - everything in this mode is already applied or not present."
            Read-Host "Press Enter to continue"
            continue
        }
        Show-QuickPlan -Plan $plan -Title $mode.ToUpper()
        if (-not (Test-IsAdmin)) {
            Write-Tag WARN "Administrator privileges are required to apply changes. Restart DIVoptimizer as Administrator."
            Read-Host "Press Enter to continue"
            continue
        }
        $go = Read-Host "Do you want to continue? [Y] Yes  [N] No"
        if ($go -match '^(y|yes)$') {
            Invoke-QuickPlan -Plan $plan
            Write-Host ""
            Write-Tag INFO "Done. Check Backup / Restore to undo, or Change Log for details."
        } else {
            Write-Tag INFO "Cancelled - no changes made."
        }
        Read-Host "Press Enter to continue"
    }
}

# ---------------------------------------------------------------
# STARTUP SCREEN
# ---------------------------------------------------------------

function Show-StartupScreen {
    Clear-Host
    Show-Banner
    Write-Host ''
    Write-Host '   Detecting your system...' -ForegroundColor DarkGray
    if (-not (Test-Compatibility)) {
        Read-Host '   Press Enter to exit'
        exit 1
    }
    $Script:SysCache = Get-SysInfo
    $info = $Script:SysCache

    Clear-Host
    Show-Banner
    Write-Section 'System'
    $rel = if ($info['Windows Release']) { " $($info['Windows Release'])" } else { '' }
    Write-KV 'Windows'   ("{0}{1}  (build {2}, {3})" -f $info['Windows Edition'], $rel, $info['Windows Build'], $info['Architecture'])
    Write-KV 'CPU'       $info['CPU']
    Write-KV 'Memory'    $info['RAM']
    Write-KV 'Graphics'  $info['GPU']
    Write-KV 'Storage'   ("{0}  |  {1}  |  {2} free" -f $info['System Drive'], $info['Storage Type'], $info['Free Disk Space'])
    Write-KV 'Power plan' $info['Power Plan']
    Write-KV 'Device'    $info['Device Type']
    if ($info['Administrator'] -eq 'YES') { Write-KV 'Administrator' 'YES' 'Green' } else { Write-KV 'Administrator' 'NO' 'Red' }
    Write-Host ''

    if ($info['Administrator'] -eq 'NO') {
        if (Request-Elevation) { exit 0 }
    } else {
        try {
            $signedIn = (Get-CimInstance Win32_ComputerSystem).UserName
            $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            if ($signedIn -and ($signedIn -ne $me)) {
                Write-Tag WARN "Running as $me but signed in as $signedIn. Per-user (HKCU) settings will apply to $me."
            }
        } catch { }
    }

    Write-Section 'Safety'
    $rp = 'n'
    if (Test-IsAdmin) { $rp = Read-Host '   Create a system restore point before making changes this session? [Y/n]' }
    else { Write-Host '   Read-only mode: restore point and changes are disabled.' -ForegroundColor DarkGray }
    if ((Test-IsAdmin) -and $rp -notmatch '^(n|no)$') {
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            Checkpoint-Computer -Description "DIVoptimizer-PreChange" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
            Write-Tag OK 'System restore point created'
        } catch {
            Write-Tag WARN 'Could not create a restore point (Windows may limit these to one per day).'
        }
    }
    Start-Sleep -Seconds 1
}

# ---------------------------------------------------------------
# SESSION SUMMARY
# ---------------------------------------------------------------

function Show-CompletionSummary {
    Clear-Host
    Show-Header 'Session Summary'
    Write-KV 'Successful' $Script:Counters.Success 'Green'
    Write-KV 'Skipped'    $Script:Counters.Skipped 'Yellow'
    $failColor = if ($Script:Counters.Failed -gt 0) { 'Red' } else { 'Gray' }
    Write-KV 'Failed'     $Script:Counters.Failed $failColor
    Write-Host ''
    $bk = if ($Script:CurrentBackupDir) { $Script:CurrentBackupDir } else { 'None created this session' }
    Write-KV 'Backup' $bk
    Write-KV 'Log'    $Script:SessionLogPath
    if ($Script:RestartNeeded) {
        Write-Section 'Restart required'
        foreach ($r in $Script:RestartReasons) { Write-Host "   - $r" }
        Write-Host ''
        Write-Menu '1' 'Restart now'
        Write-Menu '2' 'Restart later'
        $c = Read-Host '   Choice'
        if ($c -eq '1') { Restart-Computer -Confirm:$false }
    }
    Write-Host ''
    Write-Host "   Thanks for using DIVoptimizer.  - Kaz" -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '   Press Enter to close'
}

# ---------------------------------------------------------------
# MAIN MENU (two columns)
# ---------------------------------------------------------------

function Show-MainMenu {
    $left = @(
        @{ Kind='H'; Text='Quick start' },
        @{ Kind='I'; Key='1';  Text='Quick Modes' },
        @{ Kind='B' },
        @{ Kind='H'; Text='System' },
        @{ Kind='I'; Key='2';  Text='System Information' },
        @{ Kind='I'; Key='3';  Text='Analyze System' },
        @{ Kind='I'; Key='17'; Text='Resource Monitor' },
        @{ Kind='B' },
        @{ Kind='H'; Text='Optimize' },
        @{ Kind='I'; Key='4';  Text='Safe Debloat' },
        @{ Kind='I'; Key='5';  Text='Privacy' },
        @{ Kind='I'; Key='6';  Text='Performance' },
        @{ Kind='I'; Key='7';  Text='Gaming Optimization' },
        @{ Kind='I'; Key='8';  Text='Services' },
        @{ Kind='I'; Key='9';  Text='Startup Apps' }
    )
    $right = @(
        @{ Kind='H'; Text='Maintain' },
        @{ Kind='I'; Key='10'; Text='Cleanup' },
        @{ Kind='I'; Key='11'; Text='Network' },
        @{ Kind='I'; Key='12'; Text='Windows Maintenance' },
        @{ Kind='B' },
        @{ Kind='H'; Text='Recover' },
        @{ Kind='I'; Key='13'; Text='Backup / Restore' },
        @{ Kind='I'; Key='14'; Text='Change Log' },
        @{ Kind='B' },
        @{ Kind='H'; Text='Configure' },
        @{ Kind='I'; Key='15'; Text='Settings' },
        @{ Kind='I'; Key='16'; Text='Advanced Mode' },
        @{ Kind='B' },
        @{ Kind='I'; Key='0';  Text='Exit' }
    )
    $colW = [int](($Script:Width - 2) / 2)

    while ($true) {
        Clear-Host
        Show-Banner
        $info = $Script:SysCache
        $backups = @(Get-ChildItem $Script:BackupsDir -Directory -ErrorAction SilentlyContinue).Count
        $admin = if ($info['Administrator'] -eq 'YES') { 'Admin' } else { 'Not admin' }
        $adminColor = if ($info['Administrator'] -eq 'YES') { 'Green' } else { 'Red' }
        Write-Host ('  {0} (build {1})  |  ' -f $info['Windows Edition'], $info['Windows Build']) -ForegroundColor DarkGray -NoNewline
        Write-Host $admin -ForegroundColor $adminColor -NoNewline
        Write-Host ('  |  {0}  |  {1}  |  Backups: {2}' -f $info['Device Type'], $info['Storage Type'], $backups) -ForegroundColor DarkGray
        Write-Host ''

        $rows = [Math]::Max($left.Count, $right.Count)
        for ($i = 0; $i -lt $rows; $i++) {
            $l = if ($i -lt $left.Count)  { $left[$i] }  else { $null }
            $r = if ($i -lt $right.Count) { $right[$i] } else { $null }
            Write-Cell -Cell $l -Width $colW
            Write-Cell -Cell $r -Width $colW
            Write-Host ''
        }
        Write-Host ''
        Write-Host ('  ' + ('-' * ($Script:Width - 4))) -ForegroundColor DarkGray
        Write-Host '  Every change is previewed, backed up, and can be restored.' -ForegroundColor DarkGray
        Write-Host '  > ' -ForegroundColor Cyan -NoNewline
        $c = Read-Host 'Select an option'
        switch ($c) {
            "1"  { Invoke-QuickModes }
            "2"  { Show-SystemInfo }
            "3"  { Show-AnalyzeSystem }
            "4"  { Invoke-SafeDebloat }
            "5"  { Invoke-Privacy }
            "6"  { Invoke-Performance }
            "7"  { Invoke-Gaming }
            "8"  { Invoke-Services }
            "9"  { Invoke-StartupApps }
            "10" { Invoke-Cleanup }
            "11" { Invoke-Network }
            "12" { Invoke-Maintenance }
            "13" { Invoke-BackupRestoreMenu }
            "14" { Show-ChangeLog }
            "15" { Invoke-Settings }
            "16" { Invoke-AdvancedMode }
            "17" { Show-ResourceMonitor }
            "0"  { Show-CompletionSummary; return }
            default { Write-Tag WARN "Invalid choice"; Start-Sleep -Seconds 1 }
        }
    }
}

$Script:SourceUrl = "https://raw.githubusercontent.com/Bulbug/DIVoptimizer/refs/heads/main/DIVoptimizer.ps1"

function Start-Elevated {
    # Two cases:
    #  1. Running from a local .ps1 file ($PSCommandPath is set) -> relaunch that same file elevated.
    #  2. Running via `irm <url> | iex` ($PSCommandPath is empty, this whole script is
    #     just text piped into the current session) -> there is no file to relaunch, so
    #     the elevated copy re-fetches itself from $Script:SourceUrl and pipes it into iex again.
    Write-Host ""
    Write-Host "DIVoptimizer needs Administrator privileges to detect and change system settings." -ForegroundColor Yellow
    $ans = Read-Host "Restart as Administrator? [Y/n]"
    if ($ans -match '^(n|no)$') { Write-Host "Exiting - nothing was changed."; return }

    if ($PSCommandPath) {
        $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"{0}"' -f $PSCommandPath))
        if ($Console) { $psArgs += '-Console' }
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $psArgs
    } else {
        if (-not $Script:SourceUrl -or $Script:SourceUrl -like '*REPLACE-ME*') {
            Write-Host "This copy was run via a pasted command, and no hosting URL is set in" -ForegroundColor Red
            Write-Host "`$Script:SourceUrl, so it cannot re-fetch itself elevated." -ForegroundColor Red
            Write-Host "Save this script locally and set `$Script:SourceUrl, or run PowerShell" -ForegroundColor Red
            Write-Host "as Administrator yourself first, then paste the command again." -ForegroundColor Red
            return
        }
        $remoteCmd = "irm '$Script:SourceUrl' | iex"
        if ($Console) { $remoteCmd = '$Console = $true; ' + $remoteCmd }
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command', $remoteCmd)
    }
}

function Invoke-DIVoptimizerGui {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    # ---------------------------------------------------------------
    # XAML - dark, tabbed, WinUtil-style layout
    # ---------------------------------------------------------------

    $xaml = @'
    <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
            Title="DIVoptimizer" Height="760" Width="1080" MinHeight="560" MinWidth="820"
            WindowStartupLocation="CenterScreen" Background="#0F1117">
      <Window.Resources>
        <SolidColorBrush x:Key="Bg" Color="#0F1117"/>
        <SolidColorBrush x:Key="Panel" Color="#161B22"/>
        <SolidColorBrush x:Key="Border" Color="#30363D"/>
        <SolidColorBrush x:Key="Text" Color="#E6EDF3"/>
        <SolidColorBrush x:Key="Muted" Color="#8B949E"/>
        <SolidColorBrush x:Key="Accent" Color="#58C4DC"/>

        <Style TargetType="TabItem">
          <Setter Property="Foreground" Value="{StaticResource Muted}"/>
          <Setter Property="Background" Value="Transparent"/>
          <Setter Property="Padding" Value="14,8"/>
          <Setter Property="FontSize" Value="13"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="TabItem">
                <Border Name="Bd" Background="{TemplateBinding Background}" BorderThickness="0,0,0,2" BorderBrush="Transparent" Padding="{TemplateBinding Padding}">
                  <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsSelected" Value="True">
                    <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
                    <Setter Property="Foreground" Value="White"/>
                  </Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Style>
        <Style TargetType="TabControl">
          <Setter Property="Background" Value="Transparent"/>
          <Setter Property="BorderThickness" Value="0"/>
        </Style>
        <Style TargetType="CheckBox">
          <Setter Property="Foreground" Value="{StaticResource Text}"/>
          <Setter Property="Margin" Value="2,5"/>
          <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="Expander">
          <Setter Property="Foreground" Value="{StaticResource Text}"/>
          <Setter Property="Background" Value="{StaticResource Panel}"/>
          <Setter Property="BorderBrush" Value="{StaticResource Border}"/>
          <Setter Property="BorderThickness" Value="1"/>
          <Setter Property="Margin" Value="0,0,0,10"/>
          <Setter Property="Padding" Value="10"/>
          <Setter Property="FontWeight" Value="SemiBold"/>
          <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="Button">
          <Setter Property="Background" Value="#21262D"/>
          <Setter Property="Foreground" Value="{StaticResource Text}"/>
          <Setter Property="BorderBrush" Value="{StaticResource Border}"/>
          <Setter Property="BorderThickness" Value="1"/>
          <Setter Property="Padding" Value="10,6"/>
          <Setter Property="Cursor" Value="Hand"/>
        </Style>
        <Style TargetType="TextBlock">
          <Setter Property="Foreground" Value="{StaticResource Text}"/>
        </Style>
        <Style TargetType="ListBox">
          <Setter Property="Background" Value="{StaticResource Panel}"/>
          <Setter Property="Foreground" Value="{StaticResource Text}"/>
          <Setter Property="BorderBrush" Value="{StaticResource Border}"/>
        </Style>
      </Window.Resources>

      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Border}" BorderThickness="0,0,0,1" Padding="18,12">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock Text="DIV" FontSize="22" FontWeight="Bold" Foreground="{StaticResource Accent}"/>
              <TextBlock Text="optimizer" FontSize="22" FontWeight="Bold" Foreground="White"/>
              <TextBlock x:Name="VersionText" FontSize="12" Foreground="{StaticResource Muted}" VerticalAlignment="Bottom" Margin="10,0,0,3"/>
            </StackPanel>
            <TextBlock x:Name="SysLine" Grid.Column="1" Foreground="{StaticResource Muted}" VerticalAlignment="Center" FontSize="12"/>
          </Grid>
        </Border>

        <TabControl x:Name="MainTabs" Grid.Row="1" Margin="16,12,16,0">
          <TabItem Header="TWEAKS">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="TweaksPanel" Margin="4,10,4,10"/>
            </ScrollViewer>
          </TabItem>
          <TabItem Header="DEBLOAT APPS">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="DebloatPanel" Margin="4,10,4,10"/>
            </ScrollViewer>
          </TabItem>
          <TabItem Header="SYSTEM INFO">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="InfoPanel" Margin="4,10,4,10"/>
            </ScrollViewer>
          </TabItem>
          <TabItem Header="BACKUP / RESTORE">
            <Grid Margin="4,10,4,10">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <TextBlock Grid.Row="0" Text="Backups (newest first). Restoring puts back the exact original values recorded before each change." Foreground="{StaticResource Muted}" Margin="0,0,0,10" TextWrapping="Wrap"/>
              <ListBox x:Name="BackupList" Grid.Row="1"/>
              <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,10,0,0">
                <Button x:Name="RefreshBackupsBtn" Content="Refresh" Width="100" Margin="0,0,8,0"/>
                <Button x:Name="RestoreBtn" Content="Restore Selected Backup" Width="200"/>
              </StackPanel>
            </Grid>
          </TabItem>
        </TabControl>

        <Border Grid.Row="2" Background="{StaticResource Panel}" BorderBrush="{StaticResource Border}" BorderThickness="0,1,0,0" Padding="16,10">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="StatusText" Text="Ready." Foreground="{StaticResource Muted}" VerticalAlignment="Center" TextWrapping="Wrap"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal">
              <Button x:Name="RecommendedBtn" Content="Select Recommended" Width="160" Margin="4,0"/>
              <Button x:Name="ClearBtn" Content="Clear All" Width="90" Margin="4,0"/>
              <Button x:Name="ApplyBtn" Content="Apply Selected" Width="150" Margin="4,0" Background="#238636" Foreground="White" FontWeight="Bold"/>
            </StackPanel>
          </Grid>
        </Border>
      </Grid>
    </Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $VersionText   = $window.FindName("VersionText")
    $SysLine       = $window.FindName("SysLine")
    $TweaksPanel   = $window.FindName("TweaksPanel")
    $DebloatPanel  = $window.FindName("DebloatPanel")
    $InfoPanel     = $window.FindName("InfoPanel")
    $BackupList    = $window.FindName("BackupList")
    $StatusText    = $window.FindName("StatusText")
    $RecommendedBtn = $window.FindName("RecommendedBtn")
    $ClearBtn      = $window.FindName("ClearBtn")
    $ApplyBtn      = $window.FindName("ApplyBtn")
    $RefreshBackupsBtn = $window.FindName("RefreshBackupsBtn")
    $RestoreBtn    = $window.FindName("RestoreBtn")

    $VersionText.Text = "v$Script:Version  |  by $Script:Author"

    # ---------------------------------------------------------------
    # TWEAK CATALOG - built from the same data the console uses
    # (privacy/gaming registry values, the classified service list),
    # so both interfaces stay in sync with one source of truth.
    # ---------------------------------------------------------------

    function Get-TweakCatalog {
        $items = New-Object System.Collections.Generic.List[object]

        # --- Privacy ---
        $items.Add(@{ Category='Privacy'; Label='Disable Advertising ID'; Recommended=$true; Type='Registry'
            Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name='Enabled'; Value=0 })
        $items.Add(@{ Category='Privacy'; Label='Reduce diagnostic data collection'; Recommended=$true; Type='Registry'
            Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name='AllowTelemetry'; Value=0 })
        $items.Add(@{ Category='Privacy'; Label='Disable tailored experiences'; Recommended=$true; Type='Registry'
            Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name='TailoredExperiencesWithDiagnosticDataEnabled'; Value=0 })
        if ((Get-WinGeneration) -eq 11) {
            $items.Add(@{ Category='Privacy'; Label='Disable web results in Start Menu search'; Recommended=$false; Type='Registry'
                Path='HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name='DisableSearchBoxSuggestions'; Value=1 })
        } else {
            $items.Add(@{ Category='Privacy'; Label='Disable Cortana'; Recommended=$false; Type='Registry'
                Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name='AllowCortana'; Value=0 })
            $items.Add(@{ Category='Privacy'; Label='Disable web results in Start Menu search'; Recommended=$false; Type='Registry'
                Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name='BingSearchEnabled'; Value=0 })
        }

        # --- Performance ---
        $items.Add(@{ Category='Performance'; Label='Set power plan to High Performance'; Recommended=$false; Type='PowerPlan'; PlanNameLike='High performance' })
        $items.Add(@{ Category='Performance'; Label='Visual effects: best performance'; Recommended=$false; Type='Registry'
            Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name='VisualFXSetting'; Value=2 })
        $items.Add(@{ Category='Performance'; Label='Disable hibernation (frees disk space)'; Recommended=$false; Type='Hibernate'; Value=0 })
        $items.Add(@{ Category='Performance'; Label='Trim idle memory from running processes now (one-time)'; Recommended=$false; Type='Trim' })

        # --- Gaming ---
        $items.Add(@{ Category='Gaming'; Label='Enable Game Mode'; Recommended=$false; Type='Registry'
            Path='HKCU:\Software\Microsoft\GameBar'; Name='AutoGameModeEnabled'; Value=1 })
        $items.Add(@{ Category='Gaming'; Label='Disable Game DVR / background recording'; Recommended=$false; Type='Registry'
            Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name='AppCaptureEnabled'; Value=0 })
        if ((Get-WinGeneration) -ge 10 -and [int](Get-CimInstance Win32_OperatingSystem).BuildNumber -ge 19041) {
            $items.Add(@{ Category='Gaming'; Label='Enable Hardware-Accelerated GPU Scheduling (restart required)'; Recommended=$false; Type='Registry'
                Path='HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name='HwSchMode'; Value=2; Restart=$true })
        }

        # --- Low RAM & CPU ---
        $items.Add(@{ Category='Low RAM & CPU'; Label='Turn off background running for Store apps'; Recommended=$false; Type='Registry'
            Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'; Name='GlobalUserDisabled'; Value=1 })

        # --- Services (existence-checked, matches the console's classified catalog) ---
        foreach ($svc in $Script:ServiceCatalog) {
            $s = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
            if (-not $s) { continue }
            $wmi = Get-CimInstance Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue
            if ($wmi -and $wmi.StartMode -eq 'Disabled') { continue }
            $items.Add(@{ Category='Services'; Label="Disable $($svc.Name) - $($svc.Desc)"; Recommended=($svc.Class -eq 'SAFE'); Type='Service'; ServiceName=$svc.Name; Note=$svc.Impact })
        }

        return $items
    }

    function Get-AppCatalog {
        $items = New-Object System.Collections.Generic.List[object]
        $installed = Get-AppxPackage -ErrorAction SilentlyContinue
        foreach ($id in $Script:SafeApps) {
            $p = $installed | Where-Object { $_.Name -like "*$id*" } | Select-Object -First 1
            if ($p) { $items.Add(@{ Id=$id; Label=$p.Name; Recommended=$true }) }
        }
        foreach ($id in $Script:AskApps) {
            $p = $installed | Where-Object { $_.Name -like "*$id*" } | Select-Object -First 1
            if ($p) { $items.Add(@{ Id=$id; Label=$p.Name; Recommended=$false }) }
        }
        return $items
    }

    # ---------------------------------------------------------------
    # BUILD UI FROM CATALOG
    # ---------------------------------------------------------------

    $Script:TweakCheckboxes = New-Object System.Collections.Generic.List[object]
    $Script:AppCheckboxes   = New-Object System.Collections.Generic.List[object]

    function Build-TweaksTab {
        $TweaksPanel.Children.Clear()
        $Script:TweakCheckboxes.Clear()
        $catalog = Get-TweakCatalog
        $groups = $catalog | Group-Object Category
        foreach ($g in $groups) {
            $exp = New-Object System.Windows.Controls.Expander
            $exp.Header = "$($g.Name)  ($($g.Group.Count))"
            $exp.IsExpanded = $true
            $stack = New-Object System.Windows.Controls.StackPanel
            foreach ($item in $g.Group) {
                $cb = New-Object System.Windows.Controls.CheckBox
                $cb.Content = $item.Label
                $cb.IsChecked = $item.Recommended
                $cb.Tag = $item
                if ($item.Note) { $cb.ToolTip = $item.Note }
                $stack.Children.Add($cb) | Out-Null
                $Script:TweakCheckboxes.Add($cb)
            }
            $exp.Content = $stack
            $TweaksPanel.Children.Add($exp) | Out-Null
        }
        if ($catalog.Count -eq 0) {
            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = "Nothing to show - every optional service/setting is already at its recommended state."
            $t.Foreground = "#8B949E"
            $TweaksPanel.Children.Add($t) | Out-Null
        }
    }

    function Build-DebloatTab {
        $DebloatPanel.Children.Clear()
        $Script:AppCheckboxes.Clear()
        $catalog = Get-AppCatalog
        if ($catalog.Count -eq 0) {
            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = "No removable consumer apps from the catalog were detected on this PC."
            $t.Foreground = "#8B949E"
            $DebloatPanel.Children.Add($t) | Out-Null
            return
        }
        $safeExp = New-Object System.Windows.Controls.Expander
        $safeExp.Header = "Safe / optional"
        $safeExp.IsExpanded = $true
        $safeStack = New-Object System.Windows.Controls.StackPanel
        $askExp = New-Object System.Windows.Controls.Expander
        $askExp.Header = "Ask before removing"
        $askExp.IsExpanded = $true
        $askStack = New-Object System.Windows.Controls.StackPanel
        foreach ($item in $catalog) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $item.Label
            $cb.IsChecked = $item.Recommended
            $cb.Tag = $item
            $Script:AppCheckboxes.Add($cb)
            if ($item.Recommended) { $safeStack.Children.Add($cb) | Out-Null } else { $askStack.Children.Add($cb) | Out-Null }
        }
        $safeExp.Content = $safeStack
        $askExp.Content = $askStack
        if ($safeStack.Children.Count -gt 0) { $DebloatPanel.Children.Add($safeExp) | Out-Null }
        if ($askStack.Children.Count -gt 0) { $DebloatPanel.Children.Add($askExp) | Out-Null }
    }

    function Build-InfoTab {
        $InfoPanel.Children.Clear()
        $info = Get-SysInfo
        foreach ($k in $info.Keys) {
            $row = New-Object System.Windows.Controls.StackPanel
            $row.Orientation = "Horizontal"
            $row.Margin = "0,3"
            $kt = New-Object System.Windows.Controls.TextBlock
            $kt.Text = $k; $kt.Width = 160; $kt.Foreground = "#8B949E"
            $vt = New-Object System.Windows.Controls.TextBlock
            $vt.Text = [string]$info[$k]
            $row.Children.Add($kt) | Out-Null
            $row.Children.Add($vt) | Out-Null
            $InfoPanel.Children.Add($row) | Out-Null
        }
    }

    function Build-BackupList {
        $BackupList.Items.Clear()
        $dirs = Get-ChildItem $Script:BackupsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
        foreach ($d in $dirs) { $BackupList.Items.Add($d.Name) | Out-Null }
    }

    function Update-SysLine {
        $info = Get-SysInfo
        $backups = @(Get-ChildItem $Script:BackupsDir -Directory -ErrorAction SilentlyContinue).Count
        $SysLine.Text = "{0} (build {1})   |   Administrator   |   {2}   |   {3}   |   Backups: {4}" -f `
            $info['Windows Edition'], $info['Windows Build'], $info['Device Type'], $info['Storage Type'], $backups
    }

    Build-TweaksTab
    Build-DebloatTab
    Build-InfoTab
    Build-BackupList
    Update-SysLine

    # ---------------------------------------------------------------
    # EVENTS
    # ---------------------------------------------------------------

    $RecommendedBtn.Add_Click({
        foreach ($cb in $Script:TweakCheckboxes) { $cb.IsChecked = $cb.Tag.Recommended }
        foreach ($cb in $Script:AppCheckboxes)   { $cb.IsChecked = $cb.Tag.Recommended }
        $StatusText.Text = "Recommended items selected."
    })

    $ClearBtn.Add_Click({
        foreach ($cb in $Script:TweakCheckboxes) { $cb.IsChecked = $false }
        foreach ($cb in $Script:AppCheckboxes)   { $cb.IsChecked = $false }
        $StatusText.Text = "Selection cleared."
    })

    $RefreshBackupsBtn.Add_Click({ Build-BackupList; Update-SysLine; $StatusText.Text = "Backup list refreshed." })

    $RestoreBtn.Add_Click({
        if ($BackupList.SelectedItem -eq $null) {
            [System.Windows.MessageBox]::Show("Select a backup from the list first.", "DIVoptimizer", "OK", "Information") | Out-Null
            return
        }
        $name = $BackupList.SelectedItem.ToString()
        $dir = Join-Path $Script:BackupsDir $name
        $r = [System.Windows.MessageBox]::Show("Restore settings from backup `"$name`"?`n`nThis puts back the exact original values recorded at the time. Restoration may require a restart.", "Confirm restore", "YesNo", "Question")
        if ($r -ne "Yes") { return }
        $StatusText.Text = "Restoring from $name ..."
        $window.Dispatcher.Invoke([action]{}, "Render")
        $manifest = Join-Path $dir "manifest.txt"
        if (-not (Test-Path $manifest)) {
            [System.Windows.MessageBox]::Show("manifest.txt missing in this backup.", "DIVoptimizer", "OK", "Error") | Out-Null
            return
        }
        $applied = 0
        Get-Content $manifest | ForEach-Object {
            $parts = $_ -split '\|'
            switch ($parts[0]) {
                "SERVICE" {
                    $svcName = $parts[1]
                    $mode = switch -Regex ($parts[2]) {
                        '^(auto|automatic)$' { 'auto' }; '^delayed-auto$' { 'delayed-auto' }
                        '^(demand|manual)$'  { 'demand' }; '^disabled$' { 'disabled' }; default { 'keep' }
                    }
                    if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
                        if (Set-ServiceMode -Name $svcName -Mode $mode) {
                            if ($parts[3] -eq 'Running') { Start-Service -Name $svcName -ErrorAction SilentlyContinue }
                            $applied++
                        }
                    }
                }
                "REGISTRY" {
                    $path = $parts[1]; $rName = $parts[2]; $val = $parts[3]; $type = $parts[4]; $existed = $parts[5]
                    if ($existed -eq "True" -and $type -in @('DWord','QWord','String','ExpandString')) {
                        try {
                            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
                            New-ItemProperty -Path $path -Name $rName -Value $val -PropertyType $type -Force | Out-Null
                            $applied++
                        } catch { }
                    } elseif ($existed -eq "False") {
                        if (Test-Path $path) { Remove-ItemProperty -Path $path -Name $rName -ErrorAction SilentlyContinue }
                        $applied++
                    }
                }
                "POWERPLAN" { try { powercfg -setactive $parts[1]; $applied++ } catch { } }
                "TASK" {
                    try {
                        $tp = Split-Path $parts[1] -Parent; $tn = Split-Path $parts[1] -Leaf
                        if ($parts[2] -in @('Ready','Enabled')) { Enable-ScheduledTask -TaskName $tn -TaskPath "$tp\" -ErrorAction SilentlyContinue | Out-Null }
                        $applied++
                    } catch { }
                }
            }
        }
        $StatusText.Text = "Restore complete - $applied item(s) reverted. Removed apps must be reinstalled from the Microsoft Store."
        Update-SysLine
        Build-TweaksTab
    })

    $ApplyBtn.Add_Click({
        $selectedTweaks = @($Script:TweakCheckboxes | Where-Object { $_.IsChecked })
        $selectedApps   = @($Script:AppCheckboxes   | Where-Object { $_.IsChecked })
        if ($selectedTweaks.Count -eq 0 -and $selectedApps.Count -eq 0) {
            [System.Windows.MessageBox]::Show("Nothing is selected.", "DIVoptimizer", "OK", "Information") | Out-Null
            return
        }

        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($cb in $selectedApps)   { $lines.Add("Remove app: $($cb.Tag.Label)") }
        foreach ($cb in $selectedTweaks) { $lines.Add($cb.Content) }
        $preview = ($lines -join "`n")
        $r = [System.Windows.MessageBox]::Show("The following changes will be made:`n`n$preview`n`nContinue?", "Confirm changes", "YesNo", "Question")
        if ($r -ne "Yes") { $StatusText.Text = "Cancelled - no changes made."; return }

        $StatusText.Text = "Applying changes..."
        $window.Dispatcher.Invoke([action]{}, "Render")
        New-BackupSession | Out-Null
        $ok = 0; $fail = 0; $restartNeeded = $false

        foreach ($cb in $selectedApps) {
            $id = $cb.Tag.Id
            try {
                Get-AppxPackage -Name "*$id*" -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction Stop
                Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*$id*" } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
                Record-AppxRemoval -Name $id
                $ok++
            } catch { $fail++ }
        }

        foreach ($cb in $selectedTweaks) {
            $t = $cb.Tag
            try {
                switch ($t.Type) {
                    'Registry' {
                        Backup-RegistryValue -Path $t.Path -Name $t.Name
                        if (-not (Test-Path $t.Path)) { New-Item -Path $t.Path -Force | Out-Null }
                        New-ItemProperty -Path $t.Path -Name $t.Name -Value $t.Value -PropertyType DWord -Force | Out-Null
                        if ($t.Restart) { $restartNeeded = $true }
                        $ok++
                    }
                    'Service' {
                        Backup-ServiceState -Name $t.ServiceName | Out-Null
                        if (Set-ServiceMode -Name $t.ServiceName -Mode 'disabled') {
                            Stop-Service -Name $t.ServiceName -Force -ErrorAction SilentlyContinue
                            $ok++
                        } else { $fail++ }
                    }
                    'PowerPlan' {
                        Backup-PowerPlanState
                        $plan = Get-PowerPlans | Where-Object { $_.Name -like "*$($t.PlanNameLike)*" } | Select-Object -First 1
                        if ($plan) { powercfg -setactive $plan.Guid; $ok++ } else { $fail++ }
                    }
                    'Hibernate' { powercfg -h off; $ok++ }
                    'Trim'      { Invoke-MemoryTrimAction; $ok++ }
                }
            } catch { $fail++ }
        }

        $Script:Counters.Success += $ok
        $Script:Counters.Failed  += $fail
        $summary = "Done - $ok applied"
        if ($fail -gt 0) { $summary += ", $fail failed" }
        if ($restartNeeded) { $summary += ". Restart recommended for GPU scheduling to take effect." }
        $StatusText.Text = $summary
        Update-SysLine
        Build-TweaksTab
        Build-DebloatTab
        Build-BackupList
    })

    $window.Add_Closing({
        if ($Script:Counters.Success -gt 0) {
            Write-Log "INFO" "GUI session ended. Success=$($Script:Counters.Success) Failed=$($Script:Counters.Failed)"
        }
    })

    [void]$window.ShowDialog()
}

# ---------------------------------------------------------------
# ENTRY POINT
# ---------------------------------------------------------------
# Console vs GUI: set $Console = $true before the iex/irm line to
# get the text menu instead of the GUI, e.g.:
#   $Console = $true; irm <url> | iex
# (When double-clicking a locally saved copy, add -Console instead:
#  powershell -File DIVoptimizer.ps1 -Console)

if (-not (Test-Compatibility)) {
    Write-Host "DIVoptimizer supports Windows 10 and Windows 11 (client editions) only." -ForegroundColor Red
    exit 1
}

if (-not (Test-IsAdmin)) {
    Start-Elevated
    exit 0
}

Ensure-Directories
Start-Session

if ($Console) {
    Initialize-Console
    Show-StartupScreen
    Show-MainMenu
} else {
    Invoke-DIVoptimizerGui
}
