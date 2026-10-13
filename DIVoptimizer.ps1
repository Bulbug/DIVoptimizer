#Requires -Version 5.1
# ================================================================
# DIVoptimizer v0.16.0
# Author  : Kaz
#
# A transparent, hardware-aware, reversible Windows optimization and
# maintenance utility. It scans your PC, explains every change, backs
# up what it touches, applies only what you approve, verifies the
# result and lets you restore.
#
#   .\DIVoptimizer.ps1               GUI (default)
#   .\DIVoptimizer.ps1 -Console      text menu
#   .\DIVoptimizer.ps1 -Scan         read-only system scan
#   .\DIVoptimizer.ps1 -WhatIf       dry run: lists potential changes, makes NONE
#   .\DIVoptimizer.ps1 -Quick        console Quick Optimize (LOW RISK only)
#   .\DIVoptimizer.ps1 -CheckUpdate  look for a newer release (never auto-installs)
#   .\DIVoptimizer.ps1 -Report <file> [-Format txt|json]   export a system report
#
# Works both ways:
#   irm "https://raw.githubusercontent.com/Bulbug/DIVoptimizer/refs/heads/main/DIVoptimizer.ps1" | iex
#   .\DIVoptimizer.ps1                      (saved file)
# To pass switches when running remotely:
#   & ([scriptblock]::Create((irm "<url>"))) -Scan
# When run remotely, elevation re-runs the same one-liner from the fixed HTTPS
# URL below (GitHub hosts only), and the PowerShell session is left clean.
#
# Needs Windows PowerShell 5.1 (built into Windows 10/11).
# ================================================================
param(
    [switch]$Console,
    [switch]$Scan,
    [switch]$WhatIf,
    [switch]$Quick,
    [string]$ProfileName = '',
    [string]$Report = '',
    [string]$Format = 'txt',
    [switch]$CheckUpdate,
    [switch]$ShowVersion,
    [switch]$Undo,
    [switch]$Health,
    [string]$Preselect = ''
)

# A remote run (irm | iex) executes in the caller's global scope. Remember what exists now so the
# session can be left clean when we finish.
$Script:RemoteRun = [string]::IsNullOrEmpty($PSCommandPath)
if ($Script:RemoteRun) {
    $Script:PreFunctions = @(Get-ChildItem -Path Function: | ForEach-Object { $_.Name })
    $Script:PreVariables = @(Get-ChildItem -Path Variable: | ForEach-Object { $_.Name })
}

$Script:AppName       = 'DIVoptimizer'
$Script:Version       = '0.16.0'
$Script:Author        = 'Kaz'
$Script:SchemaVersion = 2
$Script:Width         = 78
$Script:DryRun        = [bool]$WhatIf
$Script:ReadOnlyRun   = ([bool]$WhatIf -or [bool]$Scan -or [bool]$ShowVersion -or [bool]$CheckUpdate -or [bool]$Health)
$Script:IsGui         = $false

# Per-user data folder. HKCU backups belong to the user, and an elevated session of the SAME user
# resolves to the same folder, so one backup location works for both elevated and normal runs.
$Script:LocalBase = $env:LOCALAPPDATA
if (-not $Script:LocalBase) { $Script:LocalBase = [System.IO.Path]::GetTempPath() }
$Script:DataRoot         = Join-Path $Script:LocalBase 'DIVoptimizer'
$Script:BackupsDir       = Join-Path $Script:DataRoot 'Backups'
$Script:LogsDir          = Join-Path $Script:DataRoot 'Logs'
$Script:BenchDir         = Join-Path $Script:DataRoot 'Benchmarks'
$Script:UpdatesDir       = Join-Path $Script:DataRoot 'Updates'
$Script:SettingsPath     = Join-Path $Script:DataRoot 'settings.json'
$Script:ProgramDataBase  = $env:ProgramData
if (-not $Script:ProgramDataBase) { $Script:ProgramDataBase = $Script:LocalBase }
$Script:LegacyBackupsDir = Join-Path $Script:ProgramDataBase 'DIVoptimizer\Backups'

# Where this script lives. Used to re-run itself elevated when it was started with irm | iex.
# Override for a pinned release:  $env:DIVOPTIMIZER_URL = '<https raw.githubusercontent.com url>'
$Script:SelfUrl  = 'https://raw.githubusercontent.com/Bulbug/DIVoptimizer/refs/heads/main/DIVoptimizer.ps1'
$Script:ResetUrl = 'https://raw.githubusercontent.com/Bulbug/DIVoptimizer/refs/heads/main/DIVoptimizer-Reset.ps1'

$Script:UpdateManifestUrl = 'https://raw.githubusercontent.com/Bulbug/DIVoptimizer/main/update.json'

$Script:SessionLogPath = $null
$Script:WinLabel       = ''
$Script:LastScan           = $null
$Script:BackupSession  = $null
$Script:Counters       = @{ Success = 0; Skipped = 0; Failed = 0 }
$Script:RestartNeeded  = $false
$Script:RestartReasons = New-Object System.Collections.Generic.List[string]

$Script:LegacyMessage = @"
This backup was created by DIVoptimizer v0.6.0.

Automatic migration is not available.

Do not attempt restoration because the backup format cannot be verified.
"@

# ---------------------------------------------------------------
# GENERIC HELPERS
# ---------------------------------------------------------------

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Write-Busy {
    # Shows progress for the current task: Write-Progress in the console, the loading overlay in the GUI.
    param([string]$Activity, [string]$Status = '', [int]$Percent = -1)
    if ($Script:IsGui -and $Script:GuiBusyOverlay) {
        if ($Script:GuiBusyOverlay.Visibility -eq 'Visible') { Set-GuiBusy -Text ($Activity + ': ' + $Status) -Percent $Percent }
        return
    }
    if ($Percent -ge 0) { Write-Progress -Id 1 -Activity $Activity -Status $Status -PercentComplete ([Math]::Min(100, $Percent)) }
    else { Write-Progress -Id 1 -Activity $Activity -Status $Status }
}

function Clear-Busy {
    if ($Script:IsGui -and $Script:GuiBusyOverlay) { return }
    Write-Progress -Id 1 -Activity 'DIVoptimizer' -Completed
}

function Get-CimSafe {
    param([string]$Class, [string]$Filter = '', [string]$Namespace = '')
    try {
        $p = @{ ClassName = $Class; ErrorAction = 'Stop' }
        if ($Filter) { $p['Filter'] = $Filter }
        if ($Namespace) { $p['Namespace'] = $Namespace }
        return (Get-CimInstance @p)
    } catch {
        Write-Log -Level WARN -Action 'CIM_QUERY' -Target $Class -ErrorText $_.Exception.Message
        return $null
    }
}

function Get-RegValue {
    # Returns the value, or $null when the key/value does not exist.
    param([string]$Path, [string]$Name)
    $s = Get-RegistryValueState -Path $Path -Name $Name
    if ($s.Exists) { return $s.Value }
    return $null
}

function Get-DivSettings {
    $defaults = [pscustomobject]@{ BackupRetention = 'All' }
    if (-not (Test-Path -LiteralPath $Script:SettingsPath)) { return $defaults }
    try {
        $s = Read-JsonFile -Path $Script:SettingsPath
        if ($null -eq $s.BackupRetention) { $s | Add-Member -NotePropertyName BackupRetention -NotePropertyValue 'All' -Force }
        return $s
    } catch {
        Write-Log -Level WARN -Action 'SETTINGS_READ' -ErrorText $_.Exception.Message
        return $defaults
    }
}

function Save-DivSettings {
    param($Settings)
    if ($Script:ReadOnlyRun) { return }
    Write-JsonFile -Path $Script:SettingsPath -Object $Settings
}

# ---------------------------------------------------------------
# CONSOLE UI HELPERS
# ---------------------------------------------------------------

function Initialize-Console {
    try {
        $ui = $Host.UI.RawUI
        $ui.WindowTitle = "$($Script:AppName) v$($Script:Version)"
        $buf = $ui.BufferSize
        if ($buf.Width -lt 100) {
            $ui.BufferSize = New-Object System.Management.Automation.Host.Size(100, [Math]::Max($buf.Height, 3000))
        }
        $win = $ui.WindowSize
        $wantW = [Math]::Min(96, $ui.MaxWindowSize.Width)
        $wantH = [Math]::Min(42, $ui.MaxWindowSize.Height)
        if ($win.Width -lt $wantW -or $win.Height -lt $wantH) {
            $ui.WindowSize = New-Object System.Management.Automation.Host.Size([Math]::Max($win.Width, $wantW), [Math]::Max($win.Height, $wantH))
        }
    } catch {
        Write-Log -Level WARN -Action 'CONSOLE_INIT' -ErrorText $_.Exception.Message
    }
}

function Show-Banner {
    $logo = @'
    ____  _____    __
   / __ \/  _/ |  / /
  / / / // / | | / / 
 / /_/ // /  | |/ /  
/_____/___/  |___/   
'@
    $colors = @('Cyan', 'Cyan', 'Cyan', 'DarkCyan', 'DarkCyan')
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
    $left = " DIVoptimizer  >  $Title"
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
    Write-Host ('   {0,-18}' -f $Key) -ForegroundColor DarkGray -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Write-Cell {
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

function Write-Risk {
    param([string]$Risk)
    $color = switch ($Risk) { 'LOW RISK' { 'Green' } 'OPTIONAL' { 'Yellow' } 'ADVANCED' { 'Red' } default { 'Gray' } }
    Write-Host ('[{0}]' -f $Risk) -ForegroundColor $color -NoNewline
}

function Read-YesNo {
    # Default is always NO unless -DefaultYes is given.
    param([string]$Prompt, [switch]$DefaultYes)
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host ("   $Prompt $suffix")
    if (-not $a) { return [bool]$DefaultYes }
    return ($a -match '^(y|yes)$')
}

function Wait-Enter {
    param([string]$Text = 'Press Enter to continue')
    [void](Read-Host "   $Text")
}

# ---------------------------------------------------------------
# SYSTEM SCANNER  (read-only: nothing here changes the system)
# ---------------------------------------------------------------

function Get-WindowsInfo {
    $os = Get-CimSafe -Class Win32_OperatingSystem
    $build = 0
    if ($os) { $build = [int]$os.BuildNumber }
    $gen = 0
    if ($build -ge 22000) { $gen = 11 } elseif ($build -ge 10240) { $gen = 10 }
    $cv = $null
    try { $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop } catch { $cv = $null }
    $release = ''
    $edition = ''
    $ubr = ''
    if ($cv) {
        if ($cv.DisplayVersion) { $release = [string]$cv.DisplayVersion } elseif ($cv.ReleaseId) { $release = [string]$cv.ReleaseId }
        $edition = [string]$cv.EditionID
        $ubr = [string]$cv.UBR
    }
    $client = $false
    if ($os) { $client = ([int]$os.ProductType -eq 1) }
    $supported = ($client -and $gen -ne 0)
    $status = 'Supported'
    if (-not $supported) { $status = 'Unsupported (Windows 10/11 client editions only)' }
    elseif ($build -lt 17763) { $status = 'Untested (older than Windows 10 1809)' }
    $caption = ''
    $ver = ''
    $arch = ''
    if ($os) { $caption = [string]$os.Caption; $ver = [string]$os.Version; $arch = [string]$os.OSArchitecture }
    return [pscustomobject]@{
        Caption = $caption.Trim(); Edition = $edition; Release = $release; Version = $ver; Build = $build; Ubr = $ubr
        Architecture = $arch; Generation = $gen; Supported = $supported; Status = $status
    }
}

function Test-TouchHardware {
    try {
        if (-not ('DivNative.Metrics' -as [type])) {
            Add-Type -Namespace DivNative -Name Metrics -ErrorAction Stop -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);'
        }
        $v = [DivNative.Metrics]::GetSystemMetrics(94)
        return (($v -band 3) -ne 0)
    } catch {
        Write-Log -Level WARN -Action 'TOUCH_DETECT' -ErrorText $_.Exception.Message
        return $null
    }
}

function Get-StorageDevices {
    $out = @()
    try {
        foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $class = 'Unknown'
            if ([string]$d.BusType -eq 'NVMe') { $class = 'NVMe SSD' }
            elseif ([string]$d.MediaType -eq 'SSD') { $class = 'SSD' }
            elseif ([string]$d.MediaType -eq 'HDD') { $class = 'HDD' }
            $out += [pscustomobject]@{
                Name = [string]$d.FriendlyName; Type = $class; Bus = [string]$d.BusType
                SizeGB = [math]::Round($d.Size / 1GB, 0); Health = [string]$d.HealthStatus; DeviceId = [string]$d.DeviceId
            }
        }
    } catch {
        Write-Log -Level WARN -Action 'STORAGE_DETECT' -ErrorText $_.Exception.Message
    }
    return @($out)
}

function Get-SystemDriveType {
    param($Devices)
    try {
        $letter = ($env:SystemDrive).TrimEnd(':')
        $disk = Get-Partition -DriveLetter $letter -ErrorAction Stop | Get-Disk -ErrorAction Stop
        $match = @($Devices | Where-Object { $_.DeviceId -eq [string]$disk.Number })
        if ($match.Count -gt 0) { return [string]$match[0].Type }
    } catch {
        Write-Log -Level WARN -Action 'SYSTEM_DRIVE_TYPE' -ErrorText $_.Exception.Message
    }
    return 'Unknown'
}

function Get-HardwareInfo {
    $cpus = @(Get-CimSafe -Class Win32_Processor)
    $cs = Get-CimSafe -Class Win32_ComputerSystem
    $enc = Get-CimSafe -Class Win32_SystemEnclosure
    $gpus = @(Get-CimSafe -Class Win32_VideoController)
    $bat = @(Get-CimSafe -Class Win32_Battery)

    $cpuName = ''
    $cores = 0
    $logical = 0
    foreach ($c in $cpus) {
        if (-not $cpuName) { $cpuName = ([string]$c.Name).Trim() }
        $cores += [int]$c.NumberOfCores
        $logical += [int]$c.NumberOfLogicalProcessors
    }
    $ramBytes = 0
    $mfr = ''
    $model = ''
    if ($cs) { $ramBytes = [double]$cs.TotalPhysicalMemory; $mfr = [string]$cs.Manufacturer; $model = [string]$cs.Model }

    $chassis = @()
    if ($enc -and $enc.ChassisTypes) { $chassis = @($enc.ChassisTypes | ForEach-Object { [int]$_ }) }
    $laptopTypes = @(8, 9, 10, 11, 12, 14, 18, 21, 31, 32)
    $isLaptopChassis = (@($chassis | Where-Object { $laptopTypes -contains $_ }).Count -gt 0)
    $isTabletChassis = ($chassis -contains 30)

    $vmText = ("$mfr $model")
    $isVm = ($vmText -match 'VMware|VirtualBox|innotek|QEMU|KVM|Xen|Parallels|Virtual Machine|Bochs|Hyper-V')

    $batteryPresent = ($bat.Count -gt 0 -and $null -ne $bat[0])
    $deviceType = 'Desktop'
    if ($isVm) { $deviceType = 'Virtual machine' }
    elseif ($isTabletChassis) { $deviceType = 'Tablet' }
    elseif ($isLaptopChassis) { $deviceType = 'Laptop' }
    elseif ($batteryPresent -and $chassis.Count -eq 0) { $deviceType = 'Laptop' }

    $gpuList = @()
    foreach ($g in $gpus) {
        if (-not $g) { continue }
        $n = [string]$g.Name
        $virtual = ($n -match 'Microsoft Basic|Hyper-V|VMware|VirtualBox|Remote Display|Parsec|Virtual')
        $discrete = ($n -match 'NVIDIA|GeForce|RTX|GTX|Quadro|Radeon RX|Radeon Pro|Intel\(R\) Arc|Arc A\d')
        $gpuList += [pscustomobject]@{ Name = $n; Driver = [string]$g.DriverVersion; Discrete = $discrete; Virtual = $virtual }
    }

    $devices = Get-StorageDevices
    $virt = $null
    if ($cpus.Count -gt 0 -and $cpus[0]) { try { $virt = [bool]$cpus[0].VirtualizationFirmwareEnabled } catch { $virt = $null } }

    return [pscustomobject]@{
        Cpu = $cpuName; Cores = $cores; LogicalProcessors = $logical
        RamGB = [math]::Round($ramBytes / 1GB, 1)
        Manufacturer = $mfr; Model = $model
        DeviceType = $deviceType; IsVirtualMachine = $isVm
        BatteryPresent = $batteryPresent; Touch = (Test-TouchHardware)
        Gpus = @($gpuList)
        HasDiscreteGpu = (@($gpuList | Where-Object { $_.Discrete }).Count -gt 0)
        Storage = @($devices); SystemDriveType = (Get-SystemDriveType -Devices $devices)
        VirtualizationEnabled = $virt
    }
}

function Get-AcState {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $s = [System.Windows.Forms.SystemInformation]::PowerStatus
        $pct = $null
        if ($s.BatteryLifePercent -le 1) { $pct = [int]([math]::Round($s.BatteryLifePercent * 100)) }
        return [pscustomobject]@{ Line = [string]$s.PowerLineStatus; BatteryPercent = $pct }
    } catch {
        Write-Log -Level WARN -Action 'AC_STATE' -ErrorText $_.Exception.Message
        return [pscustomobject]@{ Line = 'Unknown'; BatteryPercent = $null }
    }
}

function Get-ThermalInfo {
    # Often needs Administrator and many PCs do not expose it. Returns $null when unavailable.
    try {
        $z = @(Get-CimInstance -Namespace 'root/wmi' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)
        if ($z.Count -eq 0) { return $null }
        $temps = @($z | ForEach-Object { [math]::Round(($_.CurrentTemperature / 10) - 273.15, 1) })
        return ($temps | Measure-Object -Maximum).Maximum
    } catch { return $null }
}

function Get-PowerInfo {
    param($Hardware)
    $plan = Get-ActivePowerPlan
    $ac = $null
    $pct = $null
    if ($Hardware.BatteryPresent) { $a = Get-AcState; $ac = $a.Line; $pct = $a.BatteryPercent }
    return [pscustomobject]@{
        DeviceType = $Hardware.DeviceType; BatteryPresent = $Hardware.BatteryPresent
        AcConnected = $(if ($ac) { ($ac -eq 'Online') } else { $null }); AcLine = $ac; BatteryPercent = $pct
        PlanGuid = $(if ($plan) { $plan.Guid } else { '' }); PlanName = $(if ($plan) { $plan.Name } else { 'Unknown' })
        ThermalC = (Get-ThermalInfo)
    }
}

function Get-MemoryInfo {
    $os = Get-CimSafe -Class Win32_OperatingSystem
    if (-not $os) { return [pscustomobject]@{ TotalGB = 0; UsedGB = 0; FreeGB = 0; UsedPct = 0 } }
    $total = [double]$os.TotalVisibleMemorySize
    $free = [double]$os.FreePhysicalMemory
    return [pscustomobject]@{
        TotalGB = [math]::Round($total / 1MB, 1); FreeGB = [math]::Round($free / 1MB, 1)
        UsedGB = [math]::Round(($total - $free) / 1MB, 1); UsedPct = [math]::Round((($total - $free) / $total) * 100, 0)
    }
}

function Get-CpuLoad {
    $c = @(Get-CimSafe -Class Win32_Processor)
    $vals = @($c | Where-Object { $null -ne $_.LoadPercentage } | ForEach-Object { [double]$_.LoadPercentage })
    if ($vals.Count -eq 0) { return $null }
    return [math]::Round((($vals | Measure-Object -Average).Average), 0)
}

function Get-StorageInfo {
    $drive = $env:SystemDrive
    if (-not $drive) { $drive = 'C:' }
    $v = Get-CimSafe -Class Win32_LogicalDisk -Filter "DeviceID='$drive'"
    if (-not $v) { return [pscustomobject]@{ Drive = $drive; TotalGB = 0; FreeGB = 0; FreePct = 0 } }
    $total = [double]$v.Size
    $free = [double]$v.FreeSpace
    $pct = 0
    if ($total -gt 0) { $pct = [math]::Round(($free / $total) * 100, 0) }
    return [pscustomobject]@{ Drive = $drive; TotalGB = [math]::Round($total / 1GB, 1); FreeGB = [math]::Round($free / 1GB, 1); FreePct = $pct }
}

function Get-PendingRestart {
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
    $s = Get-RegistryValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations'
    return [bool]$s.Exists
}

function ConvertTo-StateLabel {
    param($Value, [hashtable]$Labels, [string]$Missing = 'Default (not set)')
    if ($null -eq $Value) { return $Missing }
    $k = [string]$Value
    if ($Labels.ContainsKey($k)) { return $Labels[$k] }
    return $k
}

function Get-FeatureState {
    $gm = Get-RegValue -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled'
    $dvrA = Get-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled'
    $dvrB = Get-RegValue -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled'
    $dvr = 'Partially disabled'
    if ($dvrA -eq 0 -and $dvrB -eq 0) { $dvr = 'Disabled' }
    elseif ($dvrA -eq 1 -or $dvrB -eq 1) { $dvr = 'Enabled' }
    elseif ($null -eq $dvrA -and $null -eq $dvrB) { $dvr = 'Default (not set)' }
    $hags = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode'

    $defRt = 'Unknown'
    try {
        if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            $defRt = if ($mp.RealTimeProtectionEnabled) { 'On' } else { 'Off' }
        }
    } catch { $defRt = 'Unknown' }

    $sr = 'Unknown'
    $pol = Get-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name 'DisableSR'
    if ($pol -eq 1) { $sr = 'Disabled by policy' }
    elseif (Test-Administrator) {
        try { $rp = @(Get-ComputerRestorePoint -ErrorAction Stop); $sr = ('Available ({0} restore point(s))' -f $rp.Count) } catch { $sr = 'Not available / may be turned off' }
    } else { $sr = 'Requires Administrator to check' }

    $hib = Get-HibernationState
    return [pscustomobject]@{
        GameMode = (ConvertTo-StateLabel -Value $gm -Labels @{ '1' = 'Enabled'; '0' = 'Disabled' } -Missing 'Default (on in current Windows)')
        GameModeRaw = $gm
        GameDvr = $dvr
        Hags = (ConvertTo-StateLabel -Value $hags -Labels @{ '2' = 'Enabled'; '1' = 'Disabled' })
        HagsRaw = $hags
        WindowsSearch = (Get-ServiceInfo -Name 'WSearch')
        SysMain = (Get-ServiceInfo -Name 'SysMain')
        DefenderService = (Get-ServiceInfo -Name 'WinDefend')
        DefenderRealTime = $defRt
        WindowsUpdateService = (Get-ServiceInfo -Name 'wuauserv')
        RestartPending = (Get-PendingRestart)
        SystemRestore = $sr
        Hibernation = $(if ($null -eq $hib) { 'Unknown' } elseif ($hib) { 'Enabled' } else { 'Disabled' })
    }
}

function Get-ProcessMemoryForCommand {
    param([string]$Command)
    if (-not $Command) { return $null }
    $exe = $null
    if ($Command -match '^\s*"([^"]+)"') { $exe = $Matches[1] }
    elseif ($Command -match '^\s*(\S+?\.exe)') { $exe = $Matches[1] }
    if (-not $exe) { return $null }
    try {
        $n = [System.IO.Path]::GetFileNameWithoutExtension($exe)
        $p = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
        if ($p.Count -eq 0) { return $null }
        return [math]::Round((($p | Measure-Object -Property WorkingSet64 -Sum).Sum) / 1MB, 0)
    } catch { return $null }
}

function Get-StartupItems {
    param([switch]$IncludeTasks)
    $items = New-Object System.Collections.Generic.List[object]
    $runDefs = @(
        @{ Hive = 'HKCU'; Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Sub = 'Run'; Source = 'HKCU Run' },
        @{ Hive = 'HKLM'; Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Sub = 'Run'; Source = 'HKLM Run' },
        @{ Hive = 'HKLM'; Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Sub = 'Run32'; Source = 'HKLM Run (32-bit)' }
    )
    foreach ($d in $runDefs) {
        $k = $null
        try { $k = Get-Item -LiteralPath $d.Key -ErrorAction Stop } catch { continue }
        $appr = Get-StartupApprovedPath -Hive $d.Hive -Sub $d.Sub
        foreach ($n in @($k.GetValueNames())) {
            if (-not $n) { continue }
            $cmd = [string]$k.GetValue($n)
            $st = Get-RegistryValueState -Path $appr -Name $n
            $en = $true
            if ($st.Exists -and $st.Type -eq 'Binary') { $en = Test-StartupApprovedEnabled -Bytes $st.Value }
            $items.Add([pscustomobject]@{
                Id = ('run|' + $d.Source + '|' + $n); Name = $n; Command = $cmd; Source = $d.Source; Kind = 'Run'
                Location = $d.Key; Enabled = $en; ApprovedPath = $appr; ApprovedName = $n
                RequiresAdmin = ($d.Hive -eq 'HKLM'); RunningMB = (Get-ProcessMemoryForCommand -Command $cmd)
                TaskPath = ''; TaskName = ''
            })
        }
    }
    $folderDefs = @(
        @{ Hive = 'HKCU'; Path = [Environment]::GetFolderPath('Startup'); Source = 'Startup folder (this user)' },
        @{ Hive = 'HKLM'; Path = [Environment]::GetFolderPath('CommonStartup'); Source = 'Startup folder (all users)' }
    )
    foreach ($f in $folderDefs) {
        if (-not $f.Path) { continue }
        if (-not (Test-Path -LiteralPath $f.Path)) { continue }
        $appr = Get-StartupApprovedPath -Hive $f.Hive -Sub 'StartupFolder'
        foreach ($file in @(Get-ChildItem -LiteralPath $f.Path -File -Force -ErrorAction SilentlyContinue)) {
            if ($file.Name -eq 'desktop.ini') { continue }
            $st = Get-RegistryValueState -Path $appr -Name $file.Name
            $en = $true
            if ($st.Exists -and $st.Type -eq 'Binary') { $en = Test-StartupApprovedEnabled -Bytes $st.Value }
            $items.Add([pscustomobject]@{
                Id = ('folder|' + $f.Source + '|' + $file.Name); Name = $file.BaseName; Command = $file.FullName; Source = $f.Source; Kind = 'Folder'
                Location = $f.Path; Enabled = $en; ApprovedPath = $appr; ApprovedName = $file.Name
                RequiresAdmin = ($f.Hive -eq 'HKLM'); RunningMB = $null; TaskPath = ''; TaskName = ''
            })
        }
    }
    if ($IncludeTasks) {
        try {
            foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) {
                if ($t.TaskPath -like '\Microsoft\*') { continue }
                $trig = @($t.Triggers | Where-Object { $_.CimClass.CimClassName -in @('MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger') })
                if ($trig.Count -eq 0) { continue }
                $cmd = ''
                if ($t.Actions -and @($t.Actions).Count -gt 0) { $cmd = (([string]$t.Actions[0].Execute) + ' ' + ([string]$t.Actions[0].Arguments)).Trim() }
                $en = $true
                if ($null -ne $t.Settings -and $null -ne $t.Settings.Enabled) { $en = [bool]$t.Settings.Enabled }
                $items.Add([pscustomobject]@{
                    Id = ('task|' + $t.TaskPath + $t.TaskName); Name = [string]$t.TaskName; Command = $cmd; Source = 'Scheduled task (logon/boot)'; Kind = 'Task'
                    Location = [string]$t.TaskPath; Enabled = $en; ApprovedPath = ''; ApprovedName = ''
                    RequiresAdmin = $true; RunningMB = $null; TaskPath = [string]$t.TaskPath; TaskName = [string]$t.TaskName
                })
            }
        } catch {
            Write-Log -Level WARN -Action 'STARTUP_TASKS' -ErrorText $_.Exception.Message
        }
    }
    return $items.ToArray()
}

function Get-InstalledProgramNames {
    $names = New-Object System.Collections.Generic.List[string]
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($sub in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $dn = $null
            try { $dn = $sub.GetValue('DisplayName') } catch { $dn = $null }
            if ($dn) { $names.Add([string]$dn) }
        }
    }
    return $names.ToArray()
}

function Get-SteamLibraries {
    $libs = @()
    $steam = Get-RegValue -Path 'HKCU:\Software\Valve\Steam' -Name 'SteamPath'
    if (-not $steam) { return @() }
    $steam = ([string]$steam) -replace '/', '\'
    $libs += $steam
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        try {
            $txt = Get-Content -LiteralPath $vdf -Raw -ErrorAction Stop
            foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') }
        } catch { Write-Log -Level WARN -Action 'STEAM_LIBS' -ErrorText $_.Exception.Message }
    }
    return @($libs | Select-Object -Unique)
}

function Get-DetectedGames {
    # Detection only. Nothing is modified and no game files are read beyond their presence.
    $programs = Get-InstalledProgramNames
    $steamLibs = Get-SteamLibraries
    $epicManifestDir = Join-Path $Script:ProgramDataBase 'Epic\EpicGamesLauncher\Data\Manifests'
    $epicNames = @()
    if (Test-Path -LiteralPath $epicManifestDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $epicManifestDir -Filter '*.item' -ErrorAction SilentlyContinue)) {
            try { $j = Read-JsonFile -Path $f.FullName; if ($j.DisplayName) { $epicNames += [string]$j.DisplayName } } catch { Write-Log -Level WARN -Action 'EPIC_MANIFEST' -ErrorText $_.Exception.Message }
        }
    }
    $pf86 = ${env:ProgramFiles(x86)}
    if (-not $pf86) { $pf86 = $env:ProgramFiles }
    $sd = $env:SystemDrive
    $defs = @(
        @{ Name = 'Steam'; Pattern = '^Steam$'; Paths = @((Join-Path $pf86 'Steam\steam.exe')) },
        @{ Name = 'Epic Games Launcher'; Pattern = 'Epic Games Launcher'; Paths = @((Join-Path $pf86 'Epic Games\Launcher')) },
        @{ Name = 'Riot Client'; Pattern = 'Riot Client|Riot Vanguard'; Paths = @((Join-Path $sd 'Riot Games\Riot Client'), (Join-Path $Script:ProgramDataBase 'Riot Games\RiotClientInstalls.json')) },
        @{ Name = 'VALORANT'; Pattern = '^VALORANT'; Paths = @((Join-Path $sd 'Riot Games\VALORANT')) },
        @{ Name = 'League of Legends'; Pattern = 'League of Legends'; Paths = @((Join-Path $sd 'Riot Games\League of Legends')) },
        @{ Name = 'Minecraft'; Pattern = 'Minecraft'; Paths = @((Join-Path $env:APPDATA '.minecraft')); Appx = @('Microsoft.MinecraftUWP', 'Microsoft.4297127D64EC6') },
        @{ Name = 'Fortnite'; Pattern = '^Fortnite'; Epic = 'Fortnite' },
        @{ Name = 'Counter-Strike 2'; Pattern = 'Counter-Strike'; SteamApp = '730' },
        @{ Name = 'Roblox'; Pattern = 'Roblox'; Paths = @((Join-Path $env:LOCALAPPDATA 'Roblox')); Appx = @('ROBLOXCORPORATION.ROBLOX') }
    )
    $found = @()
    foreach ($d in $defs) {
        $src = $null
        if (@($programs | Where-Object { $_ -match $d.Pattern }).Count -gt 0) { $src = 'installed program entry' }
        if (-not $src -and $d.Paths) {
            foreach ($p in $d.Paths) { if ($p -and (Test-Path -LiteralPath $p)) { $src = 'folder found'; break } }
        }
        if (-not $src -and $d.Appx) {
            foreach ($a in $d.Appx) {
                if (Get-AppxPackage -Name $a -ErrorAction SilentlyContinue) { $src = 'Microsoft Store package'; break }
            }
        }
        if (-not $src -and $d.Epic -and (@($epicNames | Where-Object { $_ -eq $d.Epic }).Count -gt 0)) { $src = 'Epic Games manifest' }
        if (-not $src -and $d.SteamApp) {
            foreach ($lib in $steamLibs) {
                if (Test-Path -LiteralPath (Join-Path $lib ("steamapps\appmanifest_{0}.acf" -f $d.SteamApp))) { $src = 'Steam library'; break }
            }
        }
        if ($src) { $found += [pscustomobject]@{ Name = $d.Name; Source = $src } }
    }
    return @($found)
}

function Get-FolderStats {
    # Size and file count. -DetectLocked samples up to $LockCap files by trying to open them exclusively.
    param([string]$Path, [string]$Filter = '*', [switch]$DetectLocked, [int]$LockCap = 4000)
    $stats = [pscustomobject]@{ Exists = $false; Bytes = [long]0; Files = 0; Locked = 0; LockedSampled = $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $stats }
    $stats.Exists = $true
    $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -Filter $Filter -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        $stats.Files++
        $stats.Bytes += [long]$f.Length
        if ($DetectLocked) {
            $n++
            if ($n -le $LockCap) {
                $fs = $null
                try {
                    $fs = [System.IO.File]::Open($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                } catch { $stats.Locked++ } finally { if ($fs) { $fs.Dispose() } }
            } else { $stats.LockedSampled = $true }
        }
    }
    return $stats
}

function Get-SystemScan {
    param([switch]$Quiet)
    $act = 'Scanning your PC (read-only)'
    Write-Busy -Activity $act -Status 'Windows version...' -Percent 5
    $win = Get-WindowsInfo
    $Script:WinLabel = ("{0} build {1}" -f $win.Caption, $win.Build)
    Write-Busy -Activity $act -Status 'Hardware and storage...' -Percent 15
    $hw = Get-HardwareInfo
    Write-Busy -Activity $act -Status 'Power and memory...' -Percent 35
    $pw = Get-PowerInfo -Hardware $hw
    $mem = Get-MemoryInfo
    $sto = Get-StorageInfo
    $cpu = Get-CpuLoad
    Write-Busy -Activity $act -Status 'Windows features...' -Percent 50
    $feat = Get-FeatureState
    Write-Busy -Activity $act -Status 'Startup items...' -Percent 62
    $startup = @(Get-StartupItems)
    Write-Busy -Activity $act -Status 'Services...' -Percent 74
    $svc = @()
    foreach ($e in @($Script:ServiceCatalog)) { $svc += (Get-ServiceInfo -Name $e.Name) }
    Write-Busy -Activity $act -Status 'Detecting games and launchers...' -Percent 84
    $games = @(Get-DetectedGames)
    Write-Busy -Activity $act -Status 'Temporary files...' -Percent 94
    $tempMB = $null
    $t = Get-FolderStats -Path $env:TEMP
    if ($t.Exists) { $tempMB = [math]::Round($t.Bytes / 1MB, 0) }
    $scan = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        ToolVersion = $Script:Version
        IsAdmin = (Test-Administrator)
        Windows = $win
        Hardware = $hw
        Power = $pw
        Memory = $mem
        Storage = $sto
        CpuLoad = $cpu
        Features = $feat
        Startup = $startup
        Services = @($svc)
        Games = $games
        UserTempMB = $tempMB
    }
    $Script:LastScan = $scan
    Clear-Busy
    Write-Log -Level INFO -Action 'SCAN' -Result 'COMPLETE' -Message ("{0}; {1} GB RAM; {2}; {3}" -f $Script:WinLabel, $hw.RamGB, $hw.SystemDriveType, $hw.DeviceType)
    return $scan
}

function Get-ScanReportLines {
    # Used for the console report AND the exported report. Contains no user name, computer name,
    # serial numbers, file paths or startup command lines.
    param($Scan)
    $w = $Scan.Windows; $h = $Scan.Hardware; $p = $Scan.Power; $m = $Scan.Memory; $s = $Scan.Storage; $f = $Scan.Features
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("DIVoptimizer v$($Script:Version) - System Report")
    $L.Add("Generated: $($Scan.Timestamp)    Administrator: $($Scan.IsAdmin)")
    $L.Add('')
    $L.Add('== WINDOWS ==')
    $L.Add(("Edition        : {0} ({1})" -f $w.Caption, $w.Edition))
    $L.Add(("Version/Build  : {0} {1}  build {2}.{3}  {4}" -f $w.Version, $w.Release, $w.Build, $w.Ubr, $w.Architecture))
    $L.Add(("Generation     : Windows {0}" -f $w.Generation))
    $L.Add(("Support status : {0}" -f $w.Status))
    $L.Add('')
    $L.Add('== HARDWARE ==')
    $L.Add(("Device         : {0} ({1} {2})" -f $h.DeviceType, $h.Manufacturer, $h.Model))
    $L.Add(("CPU            : {0}  [{1} cores / {2} threads]" -f $h.Cpu, $h.Cores, $h.LogicalProcessors))
    $L.Add(("RAM            : {0} GB" -f $h.RamGB))
    foreach ($g in @($h.Gpus)) { $L.Add(("GPU            : {0}  driver {1}  [{2}]" -f $g.Name, $g.Driver, $(if ($g.Discrete) { 'discrete' } elseif ($g.Virtual) { 'virtual' } else { 'integrated/other' }))) }
    foreach ($d in @($h.Storage)) { $L.Add(("Storage        : {0}  {1}  {2} GB  health {3}" -f $d.Name, $d.Type, $d.SizeGB, $d.Health)) }
    $L.Add(("System drive   : {0}  type {1}  {2} GB free of {3} GB ({4}% free)" -f $s.Drive, $h.SystemDriveType, $s.FreeGB, $s.TotalGB, $s.FreePct))
    $L.Add(("Touchscreen    : {0}" -f $(if ($null -eq $h.Touch) { 'Unknown' } elseif ($h.Touch) { 'Detected' } else { 'Not detected' })))
    $L.Add(("Virtualization : {0}" -f $(if ($null -eq $h.VirtualizationEnabled) { 'Unknown' } elseif ($h.VirtualizationEnabled) { 'Enabled in firmware' } else { 'Disabled in firmware' })))
    $L.Add('')
    $L.Add('== POWER ==')
    $L.Add(("Active plan    : {0}" -f $p.PlanName))
    $L.Add(("Battery        : {0}" -f $(if ($p.BatteryPresent) { "present ($($p.AcLine); $($p.BatteryPercent)%)" } else { 'none detected' })))
    $L.Add(("Temperature    : {0}" -f $(if ($null -ne $p.ThermalC) { "$($p.ThermalC) C (ACPI zone, may not reflect CPU/GPU)" } else { 'not available' })))
    $L.Add('')
    $L.Add('== MEMORY ==')
    $L.Add(("Used           : {0}% ({1} GB used, {2} GB available of {3} GB)" -f $m.UsedPct, $m.UsedGB, $m.FreeGB, $m.TotalGB))
    $L.Add('')
    $L.Add('== WINDOWS FEATURES ==')
    $L.Add(("Game Mode      : {0}" -f $f.GameMode))
    $L.Add(("Game DVR       : {0}" -f $f.GameDvr))
    $L.Add(("HAGS           : {0}" -f $f.Hags))
    $L.Add(("Windows Search : {0} / {1}" -f $f.WindowsSearch.Status, $f.WindowsSearch.StartupType))
    $L.Add(("SysMain        : {0} / {1}" -f $f.SysMain.Status, $f.SysMain.StartupType))
    $L.Add(("Defender       : service {0}; real-time protection {1}" -f $f.DefenderService.Status, $f.DefenderRealTime))
    $L.Add(("Windows Update : service {0} / {1}; restart pending: {2}" -f $f.WindowsUpdateService.Status, $f.WindowsUpdateService.StartupType, $f.RestartPending))
    $L.Add(("System Restore : {0}" -f $f.SystemRestore))
    $L.Add(("Hibernation    : {0}" -f $f.Hibernation))
    $L.Add('')
    $L.Add(("== STARTUP ITEMS ({0} enabled of {1}) ==" -f @($Scan.Startup | Where-Object { $_.Enabled }).Count, @($Scan.Startup).Count))
    foreach ($i in @($Scan.Startup)) { $L.Add(("{0,-8} {1}  [{2}]" -f $(if ($i.Enabled) { 'Enabled' } else { 'Disabled' }), $i.Name, $i.Source)) }
    $L.Add('')
    $L.Add('== RELEVANT SERVICES ==')
    foreach ($sv in @($Scan.Services)) { if ($sv.Exists) { $L.Add(("{0,-18} {1,-8} {2}" -f $sv.Name, $sv.Status, $sv.StartupType)) } }
    $L.Add('')
    $L.Add('== DETECTED GAMES / LAUNCHERS (detection only) ==')
    if (@($Scan.Games).Count -eq 0) { $L.Add('None detected') } else { foreach ($g in @($Scan.Games)) { $L.Add(("{0}  ({1})" -f $g.Name, $g.Source)) } }
    return $L.ToArray()
}

function Show-ScanReport {
    param($Scan)
    foreach ($line in (Get-ScanReportLines -Scan $Scan)) {
        if ($line -match '^== ') { Write-Host ''; Write-Host $line -ForegroundColor Cyan }
        elseif ($line -match '^DIVoptimizer v') { Write-Host $line -ForegroundColor White }
        else { Write-Host $line }
    }
    Write-Host ''
}

function Get-HealthMetrics {
    # Factual numbers only - no invented "optimization score".
    param($Scan)
    $f = $Scan.Features
    $en = @($Scan.Startup | Where-Object { $_.Enabled }).Count
    $load = if ($null -ne $Scan.CpuLoad) { "$($Scan.CpuLoad)%" } else { 'n/a' }
    $upd = 'Current'
    if ($f.RestartPending) { $upd = 'Restart pending' }
    $m = [ordered]@{}
    $m['CPU'] = $load
    $m['RAM'] = ("{0}%  ({1} GB used of {2} GB)" -f $Scan.Memory.UsedPct, $Scan.Memory.UsedGB, $Scan.Memory.TotalGB)
    $m['Storage'] = ("{0} GB free of {1} GB ({2}%)" -f $Scan.Storage.FreeGB, $Scan.Storage.TotalGB, $Scan.Storage.FreePct)
    $m['Startup Apps'] = ("{0} enabled" -f $en)
    $m['Windows Update'] = ("{0} (service {1})" -f $upd, $f.WindowsUpdateService.StartupType)
    $m['Game Mode'] = $f.GameMode
    $m['Game DVR'] = $f.GameDvr
    $m['HAGS'] = $f.Hags
    $m['Defender'] = ("{0}; real-time {1}" -f $f.DefenderService.Status, $f.DefenderRealTime)
    return $m
}

function Export-SystemReport {
    param($Scan, [string]$Path, [string]$Format = 'txt')
    if ($Format -eq 'json') {
        $obj = [ordered]@{
            Tool = 'DIVoptimizer'; ToolVersion = $Script:Version; Generated = $Scan.Timestamp; IsAdmin = $Scan.IsAdmin
            Windows = $Scan.Windows; Hardware = $Scan.Hardware; Power = $Scan.Power; Memory = $Scan.Memory; Storage = $Scan.Storage
            Features = $Scan.Features
            Startup = @($Scan.Startup | ForEach-Object { [ordered]@{ Name = $_.Name; Source = $_.Source; Enabled = $_.Enabled } })
            Services = @($Scan.Services | Where-Object { $_.Exists } | ForEach-Object { [ordered]@{ Name = $_.Name; Status = $_.Status; StartupType = $_.StartupType } })
            Games = $Scan.Games
            BackupStatus = [ordered]@{ Backups = @(Get-BackupList).Count; Directory = 'DIVoptimizer\Backups' }
            Notes = 'No user name, computer name, serial numbers, file paths or startup command lines are included.'
        }
        $json = ConvertTo-Json -InputObject $obj -Depth 8
        [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    } else {
        $lines = @(Get-ScanReportLines -Scan $Scan)
        $lines += ''
        $lines += ("Backups on this PC: {0}" -f @(Get-BackupList).Count)
        $lines += 'This report contains no user name, computer name, serial numbers, file paths or startup command lines.'
        [System.IO.File]::WriteAllText($Path, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
}
# <<<CORE-BEGIN (shared restore core; must be identical in DIVoptimizer.ps1 and DIVoptimizer-Reset.ps1)
# ==============================================================================
# SHARED CORE  (identical block in DIVoptimizer.ps1 and DIVoptimizer-Reset.ps1)
#
# Contains everything needed to READ system state, WRITE a single setting,
# validate a backup and RESTORE it. The Emergency Reset script embeds this same
# block so restoring never depends on the main program or its GUI.
#
# Contract with the host script - these $Script: variables must exist:
#   AppName, Version, SchemaVersion, DryRun, ReadOnlyRun, BackupsDir,
#   LegacyBackupsDir, LogsDir, SessionLogPath, WinLabel, LegacyMessage
# ==============================================================================

function Test-Administrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------
# LOGGING  (one JSON object per line; see Format-LogEntry for readable output)
# ---------------------------------------------------------------

function Start-LogSession {
    param([string]$Prefix = 'session')
    if ($Script:ReadOnlyRun) { return }
    try {
        if (-not (Test-Path -LiteralPath $Script:LogsDir)) { New-Item -ItemType Directory -Path $Script:LogsDir -Force | Out-Null }
        $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
        $Script:SessionLogPath = Join-Path $Script:LogsDir ("{0}_{1}.jsonl" -f $Prefix, $stamp)
        $Script:SessionTextLogPath = Join-Path $Script:LogsDir ("{0}_{1}.log" -f $Prefix, $stamp)
        Write-Log -Level INFO -Action 'SESSION_START' -Message ("{0} v{1}" -f $Script:AppName, $Script:Version)
    } catch {
        $Script:SessionLogPath = $null
        Write-Warning ("Logging is unavailable: " + $_.Exception.Message)
    }
}

function Write-Log {
    param(
        [string]$Level = 'INFO',
        [string]$Action = '',
        [string]$Target = '',
        $Before = $null,
        $After = $null,
        [string]$BackupId = '',
        [string]$Result = '',
        [string]$ErrorText = '',
        [string]$Message = ''
    )
    if ($Script:ReadOnlyRun) { return }
    if (-not $Script:SessionLogPath) { return }
    $entry = [ordered]@{
        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Level     = $Level
        User      = $env:USERNAME
        Computer  = $env:COMPUTERNAME
        Windows   = $Script:WinLabel
        Action    = $Action
        Target    = $Target
        Before    = $Before
        After     = $After
        BackupId  = $BackupId
        Result    = $Result
        Error     = $ErrorText
        Message   = $Message
    }
    try {
        $line = ConvertTo-Json -InputObject $entry -Compress -Depth 5
        Add-Content -LiteralPath $Script:SessionLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
        if ($Script:SessionTextLogPath) {
            $text = ('{0} [{1}] {2} {3} {4} {5}' -f $entry.Timestamp, $Level, $Action, $Target, $Result, $Message).TrimEnd()
            if ($ErrorText) { $text += ' ERROR: ' + $ErrorText }
            Add-Content -LiteralPath $Script:SessionTextLogPath -Value $text -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    } catch {
        if (-not $Script:LogWarned) {
            $Script:LogWarned = $true
            Write-Warning ("Could not write to the log file: " + $_.Exception.Message)
        }
    }
}

function Write-Tag {
    param([string]$Tag, [string]$Message)
    $color = switch ($Tag) {
        'OK'    { 'Green' }
        'FAIL'  { 'Red' }
        'SKIP'  { 'DarkYellow' }
        'WARN'  { 'Yellow' }
        'INFO'  { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host ('[{0}] ' -f $Tag) -ForegroundColor $color -NoNewline
    Write-Host $Message
    Write-Log -Level $Tag -Message $Message
}

function Format-LogEntry {
    param($Entry)
    $lines = @()
    $lines += [string]$Entry.Timestamp
    if ($Entry.Action) { $lines += ('  ACTION  : ' + $Entry.Action) }
    if ($Entry.Target) { $lines += ('  TARGET  : ' + $Entry.Target) }
    if ($null -ne $Entry.Before -and "$($Entry.Before)" -ne '') { $lines += ('  BEFORE  : ' + (ConvertTo-Json -InputObject $Entry.Before -Compress -Depth 4)) }
    if ($null -ne $Entry.After -and "$($Entry.After)" -ne '') { $lines += ('  AFTER   : ' + (ConvertTo-Json -InputObject $Entry.After -Compress -Depth 4)) }
    if ($Entry.BackupId) { $lines += ('  BACKUP  : ' + $Entry.BackupId) }
    if ($Entry.Result) { $lines += ('  RESULT  : ' + $Entry.Result) }
    if ($Entry.Error) { $lines += ('  ERROR   : ' + $Entry.Error) }
    if ($Entry.Message) { $lines += ('  MESSAGE : ' + $Entry.Message) }
    $lines += ('  [{0}@{1}, {2}]' -f $Entry.User, $Entry.Computer, $Entry.Windows)
    return ($lines -join "`r`n")
}

# ---------------------------------------------------------------
# JSON / HASH HELPERS  (UTF-8 without BOM, atomic write)
# ---------------------------------------------------------------

function Write-JsonFile {
    param([string]$Path, $Object)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject $Object -Depth 8
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-JsonFile {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return (ConvertFrom-Json -InputObject $text)
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

# ---------------------------------------------------------------
# REGISTRY PRIMITIVES
# Every value is captured as: Path, Name, Type, Exists, Value (+KeyExisted).
# Supported: String, ExpandString, DWord, QWord, MultiString, Binary.
# ExpandString is read WITHOUT expanding %variables% so the original survives.
# ---------------------------------------------------------------

function Get-RegistryValueState {
    param([string]$Path, [string]$Name)
    $state = [pscustomobject]@{ KeyExists = $false; Exists = $false; Type = $null; Value = $null }
    $key = $null
    try { $key = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { return $state }
    $state.KeyExists = $true
    if (@($key.GetValueNames()) -contains $Name) {
        $state.Exists = $true
        $state.Type = [string]$key.GetValueKind($Name)
        $state.Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    return $state
}

function ConvertTo-RegistryRecordValue {
    param([string]$Type, $Value)
    switch ($Type) {
        'Binary'      { if ($null -eq $Value) { return '' }; return [System.Convert]::ToBase64String([byte[]]$Value) }
        'MultiString' { return ,@([string[]]@($Value)) }
        'DWord'       { return [int]$Value }
        'QWord'       { return [long]$Value }
        default       { return [string]$Value }
    }
}

function ConvertFrom-RegistryRecordValue {
    param([string]$Type, $Value)
    switch ($Type) {
        'Binary'      { return ,([System.Convert]::FromBase64String([string]$Value)) }
        'MultiString' { return ,([string[]]@($Value)) }
        'DWord'       { return [int]$Value }
        'QWord'       { return [long]$Value }
        default       { return [string]$Value }
    }
}

function Test-RegistryValueEquals {
    param([string]$Type, $A, $B)
    switch ($Type) {
        'Binary' {
            $x = if ($null -eq $A) { [byte[]]@() } else { [byte[]]$A }
            $y = if ($null -eq $B) { [byte[]]@() } else { [byte[]]$B }
            if ($x.Length -ne $y.Length) { return $false }
            for ($i = 0; $i -lt $x.Length; $i++) { if ($x[$i] -ne $y[$i]) { return $false } }
            return $true
        }
        'MultiString'  { return ((@($A) -join "`0") -ceq (@($B) -join "`0")) }
        'String'       { return ([string]$A -ceq [string]$B) }
        'ExpandString' { return ([string]$A -ceq [string]$B) }
        default        { return ([int64]$A -eq [int64]$B) }
    }
}

function Write-Command {
    # Shows the exact command about to run, in the PowerShell window, so nothing happens out of sight.
    param([string]$Text)
    if ($Script:DryRun) { return }
    if (-not $Script:CommandLegendShown) {
        $Script:CommandLegendShown = $true
        Write-Host '  PS> lines are the exact commands DIVoptimizer runs on your PC.' -ForegroundColor DarkGray
    }
    Write-Host ('  PS> ' + $Text) -ForegroundColor DarkCyan
    Write-Log -Level INFO -Action 'COMMAND' -Message $Text
}

function Format-RegCommandValue {
    param([string]$Type, $Value)
    switch ($Type) {
        'Binary'      { return ('[binary, {0} bytes]' -f @($Value).Count) }
        'MultiString' { return ("'" + ((@($Value) -join "','")) + "'") }
        'DWord'       { return [string][int]$Value }
        'QWord'       { return [string][long]$Value }
        default       { return ("'" + ([string]$Value -replace "'", "''") + "'") }
    }
}

function Set-RegistryValueSafe {
    # The ONLY function that writes a registry value. Honors dry-run.
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would set $Path\$Name"; return $true }
    Write-Command ("Set-ItemProperty -Path '{0}' -Name '{1}' -Value {2}   # {3}" -f $Path, $Name, (Format-RegCommandValue -Type $Type -Value $Value), $Type)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Type -Value $Value -Force -ErrorAction Stop | Out-Null
    return $true
}

function Remove-RegistryValueSafe {
    param([string]$Path, [string]$Name)
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would remove $Path\$Name"; return $true }
    Write-Command ("Remove-ItemProperty -Path '{0}' -Name '{1}'" -f $Path, $Name)
    Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
    return $true
}

function Remove-EmptyRegistryKey {
    # Only used for a key DIVoptimizer itself created; never removes a key that has content.
    param([string]$Path)
    if ($Script:DryRun) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $k = Get-Item -LiteralPath $Path
    if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
}

function Restore-RegistryValue {
    # Returns 'ok' | 'failed' | 'skipped'
    param($Record)
    $path = [string]$Record.Path
    $name = [string]$Record.Name
    $target = "$path\$name"
    try {
        if ($Record.PSObject.Properties.Name -contains 'Supported' -and -not [bool]$Record.Supported) {
            Write-Tag SKIP "Not restorable automatically (unsupported value type): $target"
            return 'skipped'
        }
        $before = Get-RegistryValueState -Path $path -Name $name
        if (-not [bool]$Record.Exists) {
            if ($before.Exists) { Remove-RegistryValueSafe -Path $path -Name $name | Out-Null }
            if (($Record.PSObject.Properties.Name -contains 'KeyExisted') -and (-not [bool]$Record.KeyExisted)) {
                Remove-EmptyRegistryKey -Path $path
            }
            if (-not $Script:DryRun) {
                $after = Get-RegistryValueState -Path $path -Name $name
                if ($after.Exists) { throw 'the value is still present after removal' }
            }
            Write-Log -Level INFO -Action 'RESTORE_REGISTRY' -Target $target -Before $before.Value -After '(removed)' -Result 'SUCCESS'
            Write-Tag OK "Removed $target (it did not exist originally)"
            return 'ok'
        }
        $type = [string]$Record.Type
        $val = ConvertFrom-RegistryRecordValue -Type $type -Value $Record.Value
        Set-RegistryValueSafe -Path $path -Name $name -Type $type -Value $val | Out-Null
        if (-not $Script:DryRun) {
            $after = Get-RegistryValueState -Path $path -Name $name
            if (-not ($after.Exists -and $after.Type -eq $type -and (Test-RegistryValueEquals -Type $type -A $after.Value -B $val))) {
                throw 'read-back verification failed'
            }
        }
        Write-Log -Level INFO -Action 'RESTORE_REGISTRY' -Target $target -Before $before.Value -After $Record.Value -Result 'SUCCESS'
        Write-Tag OK "Restored $target"
        return 'ok'
    } catch {
        Write-Log -Level FAIL -Action 'RESTORE_REGISTRY' -Target $target -Result 'FAILED' -ErrorText $_.Exception.Message
        Write-Tag FAIL "Could not restore $target ($($_.Exception.Message))"
        return 'failed'
    }
}

# ---------------------------------------------------------------
# SERVICE PRIMITIVES
# ---------------------------------------------------------------

function Get-ServiceInfo {
    param([string]$Name)
    $none = [pscustomobject]@{ Exists = $false; Name = $Name; DisplayName = ''; Status = ''; StartMode = ''; Delayed = $false; StartupType = 'Not present' }
    $safe = $Name -replace "'", "''"
    $w = $null
    try { $w = Get-CimInstance -ClassName Win32_Service -Filter "Name='$safe'" -ErrorAction Stop } catch { return $none }
    if (-not $w) { return $none }
    $delayed = $false
    try {
        $d = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name DelayedAutostart -ErrorAction Stop
        $delayed = ($d.DelayedAutostart -eq 1)
    } catch { $delayed = $false }
    $mode = [string]$w.StartMode
    $type = $mode
    if ($mode -eq 'Auto') { if ($delayed) { $type = 'Automatic (Delayed)' } else { $type = 'Automatic' } }
    elseif ($mode -eq 'Manual') { $type = 'Manual' }
    elseif ($mode -eq 'Disabled') { $type = 'Disabled' }
    return [pscustomobject]@{
        Exists = $true; Name = $Name; DisplayName = [string]$w.DisplayName; Status = [string]$w.State
        StartMode = $mode; Delayed = $delayed; StartupType = $type
    }
}

function Set-ServiceStartMode {
    # The ONLY function that changes a service start type. Mode: auto | delayed-auto | demand | disabled
    param([string]$Name, [string]$Mode)
    if ($Mode -notin @('auto', 'delayed-auto', 'demand', 'disabled')) { throw "Unsupported start mode '$Mode'" }
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would set service $Name start= $Mode"; return $true }
    Write-Command ('sc.exe config {0} start= {1}' -f $Name, $Mode)
    $out = & sc.exe config $Name start= $Mode 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("sc.exe failed (exit {0}): {1}" -f $LASTEXITCODE, (($out | Out-String).Trim())) }
    return $true
}

function Stop-ServiceSafe {
    param([string]$Name)
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would stop service $Name"; return }
    Write-Command ('Stop-Service -Name {0} -Force' -f $Name)
    Stop-Service -Name $Name -Force -ErrorAction Stop
}

function Start-ServiceSafe {
    param([string]$Name)
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would start service $Name"; return }
    Write-Command ('Start-Service -Name {0}' -f $Name)
    Start-Service -Name $Name -ErrorAction Stop
}

function Restore-ServiceRecord {
    param($Record)
    $name = [string]$Record.ServiceName
    try {
        $cur = Get-ServiceInfo -Name $name
        if (-not $cur.Exists) { Write-Tag SKIP "Service $name is not present on this system"; return 'skipped' }
        $mode = switch ([string]$Record.StartMode) {
            'Auto'     { if ([bool]$Record.DelayedAutoStart) { 'delayed-auto' } else { 'auto' } }
            'Manual'   { 'demand' }
            'Disabled' { 'disabled' }
            default    { $null }
        }
        if (-not $mode) { Write-Tag SKIP "Service $name had start mode '$($Record.StartMode)' which is not restored automatically"; return 'skipped' }
        Set-ServiceStartMode -Name $name -Mode $mode | Out-Null
        # Only start a service that was originally running. A service that was stopped stays stopped.
        if ([string]$Record.Status -eq 'Running' -and $mode -ne 'disabled' -and $cur.Status -ne 'Running') {
            try { Start-ServiceSafe -Name $name } catch { Write-Tag WARN "Service $name was restored but could not be started now: $($_.Exception.Message)" }
        }
        if (-not $Script:DryRun) {
            $after = Get-ServiceInfo -Name $name
            if ($after.StartupType -ne [string]$Record.StartupType) { throw "start type is '$($after.StartupType)', expected '$($Record.StartupType)'" }
        }
        Write-Log -Level INFO -Action 'RESTORE_SERVICE' -Target $name -Before $cur.StartupType -After $Record.StartupType -Result 'SUCCESS'
        Write-Tag OK "Restored service $name -> $($Record.StartupType)"
        return 'ok'
    } catch {
        Write-Log -Level FAIL -Action 'RESTORE_SERVICE' -Target $name -Result 'FAILED' -ErrorText $_.Exception.Message
        Write-Tag FAIL "Could not restore service $name ($($_.Exception.Message))"
        return 'failed'
    }
}

# ---------------------------------------------------------------
# SCHEDULED TASK PRIMITIVES  (Enabled is NOT the same thing as State)
# ---------------------------------------------------------------

function ConvertTo-TaskPath {
    param([string]$Path)
    $p = $Path
    if (-not $p.StartsWith('\')) { $p = '\' + $p }
    if (-not $p.EndsWith('\')) { $p = $p + '\' }
    return $p
}

function Get-TaskInfo {
    param([string]$TaskPath, [string]$TaskName)
    $tp = ConvertTo-TaskPath -Path $TaskPath
    try {
        $t = Get-ScheduledTask -TaskPath $tp -TaskName $TaskName -ErrorAction Stop
        $en = $true
        if ($null -ne $t.Settings -and $null -ne $t.Settings.Enabled) { $en = [bool]$t.Settings.Enabled }
        elseif ([string]$t.State -eq 'Disabled') { $en = $false }
        return [pscustomobject]@{ Exists = $true; TaskPath = $tp; TaskName = $TaskName; State = [string]$t.State; Enabled = $en }
    } catch {
        return [pscustomobject]@{ Exists = $false; TaskPath = $tp; TaskName = $TaskName; State = ''; Enabled = $false }
    }
}

function Set-TaskEnabledSafe {
    param([string]$TaskPath, [string]$TaskName, [bool]$Enabled)
    $tp = ConvertTo-TaskPath -Path $TaskPath
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would set task $tp$TaskName enabled=$Enabled"; return $true }
    Write-Command ('{0}-ScheduledTask -TaskPath ''{1}'' -TaskName ''{2}''' -f $(if ($Enabled) { 'Enable' } else { 'Disable' }), $tp, $TaskName)
    if ($Enabled) { Enable-ScheduledTask -TaskPath $tp -TaskName $TaskName -ErrorAction Stop | Out-Null }
    else { Disable-ScheduledTask -TaskPath $tp -TaskName $TaskName -ErrorAction Stop | Out-Null }
    return $true
}

function Restore-TaskRecord {
    param($Record)
    $full = ([string]$Record.TaskPath) + ([string]$Record.TaskName)
    try {
        $cur = Get-TaskInfo -TaskPath $Record.TaskPath -TaskName $Record.TaskName
        if (-not $cur.Exists) { Write-Tag SKIP "Scheduled task $full is not present on this system"; return 'skipped' }
        $want = [bool]$Record.Enabled
        if ($cur.Enabled -ne $want) { Set-TaskEnabledSafe -TaskPath $Record.TaskPath -TaskName $Record.TaskName -Enabled $want | Out-Null }
        if (-not $Script:DryRun) {
            $after = Get-TaskInfo -TaskPath $Record.TaskPath -TaskName $Record.TaskName
            if ($after.Enabled -ne $want) { throw "task enabled state is $($after.Enabled), expected $want" }
        }
        Write-Log -Level INFO -Action 'RESTORE_TASK' -Target $full -Before $cur.Enabled -After $want -Result 'SUCCESS'
        Write-Tag OK ("Restored scheduled task {0} -> {1}" -f $full, $(if ($want) { 'Enabled' } else { 'Disabled' }))
        return 'ok'
    } catch {
        Write-Log -Level FAIL -Action 'RESTORE_TASK' -Target $full -Result 'FAILED' -ErrorText $_.Exception.Message
        Write-Tag FAIL "Could not restore scheduled task $full ($($_.Exception.Message))"
        return 'failed'
    }
}

# ---------------------------------------------------------------
# POWER PLAN + HIBERNATION PRIMITIVES
# ---------------------------------------------------------------

function Get-ActivePowerPlan {
    $out = & powercfg.exe /getactivescheme 2>&1
    $text = ($out | Out-String)
    if ($text -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $guid = $Matches[1].ToLower()
        $name = ''
        if ($text -match '\(([^)]*)\)') { $name = $Matches[1] }
        return [pscustomobject]@{ Guid = $guid; Name = $name }
    }
    return $null
}

function Get-PowerPlans {
    $out = & powercfg.exe /list 2>&1
    $plans = @()
    foreach ($line in @($out)) {
        $s = [string]$line
        if ($s -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+\(([^)]*)\)(\s*\*)?') {
            $plans += [pscustomobject]@{ Guid = $Matches[1].ToLower(); Name = $Matches[2]; Active = [bool]$Matches[3] }
        }
    }
    return @($plans)
}

function Set-ActivePowerPlan {
    param([string]$Guid)
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would activate power plan $Guid"; return $true }
    Write-Command ('powercfg.exe /setactive {0}' -f $Guid)
    $out = & powercfg.exe /setactive $Guid 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("powercfg /setactive failed: " + (($out | Out-String).Trim())) }
    $now = Get-ActivePowerPlan
    if (-not $now -or $now.Guid -ne $Guid.ToLower()) { throw 'the power plan did not become active' }
    return $true
}

function Remove-PowerPlanSafe {
    param([string]$Guid)
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would delete power plan $Guid"; return }
    Write-Command ('powercfg.exe /delete {0}' -f $Guid)
    $out = & powercfg.exe /delete $Guid 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("powercfg /delete failed: " + (($out | Out-String).Trim())) }
}

function Restore-PowerPlanRecord {
    param($Record)
    $guid = ([string]$Record.Guid).ToLower()
    try {
        $cur = Get-ActivePowerPlan
        $exists = @(Get-PowerPlans | Where-Object { $_.Guid -eq $guid }).Count -gt 0
        if (-not $exists) { throw "the original power plan ($($Record.Name)) no longer exists" }
        if (-not $cur -or $cur.Guid -ne $guid) { Set-ActivePowerPlan -Guid $guid | Out-Null }
        if (($Record.PSObject.Properties.Name -contains 'CreatedPlanGuid') -and $Record.CreatedPlanGuid) {
            $created = ([string]$Record.CreatedPlanGuid).ToLower()
            if ($created -ne $guid) {
                try { Remove-PowerPlanSafe -Guid $created } catch { Write-Tag WARN "The extra power plan DIVoptimizer created could not be deleted: $($_.Exception.Message)" }
            }
        }
        Write-Log -Level INFO -Action 'RESTORE_POWERPLAN' -Target $guid -Before $(if ($cur) { $cur.Name } else { '' }) -After $Record.Name -Result 'SUCCESS'
        Write-Tag OK "Restored power plan -> $($Record.Name)"
        return 'ok'
    } catch {
        Write-Log -Level FAIL -Action 'RESTORE_POWERPLAN' -Target $guid -Result 'FAILED' -ErrorText $_.Exception.Message
        Write-Tag FAIL "Could not restore the power plan ($($_.Exception.Message))"
        return 'failed'
    }
}

function Get-HibernationState {
    # $true / $false, or $null when it cannot be determined
    try {
        $v = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled
        return ($v -eq 1)
    } catch { return $null }
}

function Set-HibernationState {
    param([bool]$Enabled)
    $arg = if ($Enabled) { 'on' } else { 'off' }
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would run powercfg /hibernate $arg"; return $true }
    Write-Command ('powercfg.exe /hibernate {0}' -f $arg)
    $out = & powercfg.exe /hibernate $arg 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("powercfg /hibernate $arg failed: " + (($out | Out-String).Trim())) }
    return $true
}

function Restore-HibernationRecord {
    param($Record)
    try {
        $want = [bool]$Record.Enabled
        $cur = Get-HibernationState
        if ($cur -ne $want) { Set-HibernationState -Enabled $want | Out-Null }
        if (-not $Script:DryRun) {
            $after = Get-HibernationState
            if ($after -ne $want) { throw "hibernation is $after, expected $want" }
        }
        Write-Log -Level INFO -Action 'RESTORE_HIBERNATION' -Target 'Hibernation' -Before $cur -After $want -Result 'SUCCESS'
        Write-Tag OK ("Restored hibernation -> {0}" -f $(if ($want) { 'Enabled' } else { 'Disabled' }))
        return 'ok'
    } catch {
        Write-Log -Level FAIL -Action 'RESTORE_HIBERNATION' -Target 'Hibernation' -Result 'FAILED' -ErrorText $_.Exception.Message
        Write-Tag FAIL "Could not restore hibernation ($($_.Exception.Message))"
        return 'failed'
    }
}

# ---------------------------------------------------------------
# STARTUP-ITEM PRIMITIVES
# Windows (Task Manager) keeps an item's enabled flag in StartupApproved\<Run|Run32|StartupFolder>
# as a 12-byte binary: first byte even = enabled, odd = disabled. The Run value or the shortcut
# itself is never touched, so nothing is deleted. Missing value = enabled.
# ---------------------------------------------------------------

function Get-StartupApprovedPath {
    param([string]$Hive, [string]$Sub)
    return "${Hive}:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$Sub"
}

function Test-StartupApprovedEnabled {
    param($Bytes)
    if ($null -eq $Bytes) { return $true }
    $b = [byte[]]$Bytes
    if ($b.Length -lt 1) { return $true }
    return ((([int]$b[0]) -band 1) -eq 0)
}

function New-StartupApprovedBytes {
    param([bool]$Enabled)
    $bytes = New-Object byte[] 12
    if ($Enabled) {
        $bytes[0] = 2
    } else {
        $bytes[0] = 3
        $ft = [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc())
        [Array]::Copy($ft, 0, $bytes, 4, 8)
    }
    return ,$bytes
}

function Restore-StartupRecord {
    param($Record)
    $reg = [pscustomobject]@{
        Path = $Record.ApprovedPath; Name = $Record.ApprovedName; Type = 'Binary'
        Exists = [bool]$Record.ApprovedExists; Value = $Record.ApprovedValue; KeyExisted = [bool]$Record.ApprovedKeyExisted
    }
    $r = Restore-RegistryValue -Record $reg
    Write-Log -Level INFO -Action 'RESTORE_STARTUP' -Target ([string]$Record.Name) -Result $r
    return $r
}

# ---------------------------------------------------------------
# BACKUP VALIDATION + RESTORE
# ---------------------------------------------------------------

function Test-BackupDir {
    param([string]$Dir)
    $res = [pscustomobject]@{ Ok = $false; Format = 'unknown'; Problems = @(); Meta = $null }
    $bj = Join-Path $Dir 'backup.json'
    $mf = Join-Path $Dir 'manifest.txt'
    if (Test-Path -LiteralPath $bj) {
        $res.Format = 'v2'
        $meta = $null
        try { $meta = Read-JsonFile -Path $bj } catch {
            $res.Problems += ('backup.json cannot be parsed: ' + $_.Exception.Message)
            return $res
        }
        $res.Meta = $meta
        $schema = 0
        try { $schema = [int]$meta.SchemaVersion } catch { $schema = 0 }
        if ($schema -gt $Script:SchemaVersion) { $res.Problems += "This backup uses a newer format (schema $schema) than this program understands." }
        if ($schema -lt 2) { $res.Problems += 'backup.json has no valid schema version.' }
        if ($null -eq $meta.Files) { $res.Problems += 'backup.json lists no data files.' }
        else {
            foreach ($prop in $meta.Files.PSObject.Properties) {
                $f = Join-Path $Dir $prop.Name
                if (-not (Test-Path -LiteralPath $f)) { $res.Problems += "Missing file: $($prop.Name)"; continue }
                $h = $null
                try { $h = Get-Sha256 -Path $f } catch { $res.Problems += "Cannot hash $($prop.Name): $($_.Exception.Message)"; continue }
                if ($h -ne [string]$prop.Value) { $res.Problems += "Checksum mismatch (file changed or corrupted): $($prop.Name)"; continue }
                try { Read-JsonFile -Path $f | Out-Null } catch { $res.Problems += "Invalid JSON in $($prop.Name)" }
            }
        }
        $res.Ok = (@($res.Problems).Count -eq 0)
        return $res
    }
    if (Test-Path -LiteralPath $mf) {
        $res.Format = 'legacy'
        $res.Problems += $Script:LegacyMessage
        return $res
    }
    $res.Problems += 'No backup.json or manifest.txt was found in this folder.'
    return $res
}

function Get-BackupList {
    $list = @()
    foreach ($root in @($Script:BackupsDir, $Script:LegacyBackupsDir)) {
        if (-not $root) { continue }
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $fmt = 'unknown'
            $meta = $null
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'backup.json')) {
                $fmt = 'v2'
                try { $meta = Read-JsonFile -Path (Join-Path $d.FullName 'backup.json') } catch { $fmt = 'corrupt' }
            } elseif (Test-Path -LiteralPath (Join-Path $d.FullName 'manifest.txt')) {
                $fmt = 'legacy'
            }
            $size = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if (-not $size) { $size = 0 }
            $desc = ''
            $prof = ''
            $created = $d.CreationTime.ToString('yyyy-MM-dd HH:mm:ss')
            $nchg = 0
            if ($meta) {
                if ($meta.Description) { $desc = [string]$meta.Description }
                if ($meta.Profile) { $prof = [string]$meta.Profile }
                if ($meta.Created) { $created = [string]$meta.Created }
                if ($meta.Changes) { $nchg = @($meta.Changes).Count }
            }
            $list += [pscustomobject]@{
                Id = $d.Name; Path = $d.FullName; Format = $fmt; Created = $created; Description = $desc
                Profile = $prof; SizeBytes = [long]$size; ChangeCount = $nchg; Meta = $meta
            }
        }
    }
    return @($list | Sort-Object Id -Descending)
}

function Restore-LegacyBackup {
    # v0.6.0 backups: a pipe-delimited manifest.txt with no integrity data.
    # We restore ONLY records that parse unambiguously and refuse everything else - never guess.
    param([string]$Dir, [string[]]$Types)
    $result = [pscustomobject]@{ Success = 0; Failed = 0; Skipped = 0; Refused = $false; Message = '' }
    $mf = Join-Path $Dir 'manifest.txt'
    $lines = @()
    try { $lines = @(Get-Content -LiteralPath $mf -ErrorAction Stop) } catch {
        $result.Refused = $true; $result.Message = $Script:LegacyMessage
        return $result
    }
    $hdr = ''
    if ($lines.Count -gt 0) { $hdr = [string]$lines[0] }
    if ($hdr -notmatch '^TOOLKIT_VERSION\|0\.\d+(\.\d+)?$') {
        $result.Refused = $true; $result.Message = $Script:LegacyMessage
        return $result
    }
    Write-Tag WARN 'This backup was created by DIVoptimizer v0.6.x. Only unambiguous records are restored; the rest are skipped.'
    $seen = @{}
    foreach ($line in $lines) {
        $parts = ([string]$line) -split '\|'
        switch ($parts[0]) {
            'SERVICE' {
                if ($Types -notcontains 'Services') { break }
                if ($parts.Count -ne 4 -or $parts[1] -notmatch '^[A-Za-z0-9_.\-]+$' -or $parts[2] -notin @('auto', 'delayed-auto', 'demand', 'disabled')) {
                    Write-Tag SKIP "Unparseable legacy service record: $line"; $result.Skipped++; break
                }
                $key = 'S|' + $parts[1].ToLower()
                if ($seen.ContainsKey($key)) { break }
                $seen[$key] = $true
                try {
                    $cur = Get-ServiceInfo -Name $parts[1]
                    if (-not $cur.Exists) { Write-Tag SKIP "Service $($parts[1]) not present"; $result.Skipped++; break }
                    Set-ServiceStartMode -Name $parts[1] -Mode $parts[2] | Out-Null
                    if ($parts[3] -eq 'Running' -and $parts[2] -ne 'disabled' -and $cur.Status -ne 'Running') { try { Start-ServiceSafe -Name $parts[1] } catch { Write-Tag WARN "Could not start $($parts[1]): $($_.Exception.Message)" } }
                    Write-Tag OK "Restored service $($parts[1]) -> $($parts[2]) (legacy record)"
                    Write-Log -Level INFO -Action 'RESTORE_LEGACY_SERVICE' -Target $parts[1] -After $parts[2] -Result 'SUCCESS'
                    $result.Success++
                } catch {
                    Write-Tag FAIL "Could not restore service $($parts[1]) ($($_.Exception.Message))"; $result.Failed++
                }
            }
            'REGISTRY' {
                if ($Types -notcontains 'Registry') { break }
                if ($parts.Count -ne 6 -or $parts[5] -notin @('True', 'False') -or $parts[4] -notin @('DWord', 'QWord', 'String', 'ExpandString')) {
                    Write-Tag SKIP "Legacy registry record is not restorable safely: $line"; $result.Skipped++; break
                }
                $key = 'R|' + $parts[1].ToLower() + '|' + $parts[2].ToLower()
                if ($seen.ContainsKey($key)) { break }   # first record = the original value
                $seen[$key] = $true
                try {
                    $existed = ($parts[5] -eq 'True')
                    if ($existed -and $parts[4] -in @('DWord', 'QWord') -and $parts[3] -notmatch '^-?\d+$') {
                        Write-Tag SKIP "Legacy registry record has a non-numeric value: $line"; $result.Skipped++; break
                    }
                    $rec = [pscustomobject]@{ Path = $parts[1]; Name = $parts[2]; Type = $parts[4]; Exists = $existed; Value = $parts[3]; KeyExisted = $true }
                    if (-not $existed) { $rec.KeyExisted = $true }
                    $r = Restore-RegistryValue -Record $rec
                    if ($r -eq 'ok') { $result.Success++ } elseif ($r -eq 'failed') { $result.Failed++ } else { $result.Skipped++ }
                } catch {
                    Write-Tag FAIL "Could not restore $($parts[1])\$($parts[2]) ($($_.Exception.Message))"; $result.Failed++
                }
            }
            'POWERPLAN' {
                if ($Types -notcontains 'PowerPlan') { break }
                if ($parts.Count -ne 2 -or $parts[1] -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                    Write-Tag SKIP "Unparseable legacy power plan record: $line"; $result.Skipped++; break
                }
                if ($seen.ContainsKey('P')) { break }
                $seen['P'] = $true
                $r = Restore-PowerPlanRecord -Record ([pscustomobject]@{ Guid = $parts[1]; Name = $parts[1] })
                if ($r -eq 'ok') { $result.Success++ } elseif ($r -eq 'failed') { $result.Failed++ } else { $result.Skipped++ }
            }
            'TASK' {
                Write-Tag SKIP "Legacy scheduled-task record not restored (v0.6.x stored the task State, which does not reliably say whether it was enabled): $($parts[1])"
                $result.Skipped++
            }
            'APPX' {
                Write-Tag INFO "Removed apps cannot be restored automatically. Reinstall from the Microsoft Store if needed: $($parts[1])"
                $result.Skipped++
            }
            default { }
        }
    }
    return $result
}

function Restore-Backup {
    param(
        [string]$Dir,
        [string[]]$Types = @('Registry', 'Services', 'Tasks', 'Startup', 'PowerPlan', 'Hibernation')
    )
    $result = [pscustomobject]@{ Success = 0; Failed = 0; Skipped = 0; Refused = $false; Message = '' }
    $chk = Test-BackupDir -Dir $Dir
    if ($chk.Format -eq 'legacy') { return (Restore-LegacyBackup -Dir $Dir -Types $Types) }
    if (-not $chk.Ok) {
        $result.Refused = $true
        $result.Message = (@($chk.Problems) -join ' | ')
        Write-Log -Level FAIL -Action 'RESTORE_BACKUP' -Target $Dir -Result 'REFUSED' -ErrorText $result.Message
        return $result
    }
    $id = [string]$chk.Meta.BackupId
    Write-Log -Level INFO -Action 'RESTORE_BACKUP' -Target $Dir -BackupId $id -Result 'STARTED'
    $tally = {
        param($r)
        if ($r -eq 'ok') { $result.Success++ } elseif ($r -eq 'failed') { $result.Failed++ } else { $result.Skipped++ }
    }
    if ($Types -contains 'Registry') {
        $f = Join-Path $Dir 'registry/registry.json'
        foreach ($rec in @((Read-JsonFile -Path $f).Records)) { & $tally (Restore-RegistryValue -Record $rec) }
    }
    if ($Types -contains 'Services') {
        $f = Join-Path $Dir 'services/services.json'
        foreach ($rec in @((Read-JsonFile -Path $f).Records)) { & $tally (Restore-ServiceRecord -Record $rec) }
    }
    if ($Types -contains 'Tasks') {
        $f = Join-Path $Dir 'tasks/tasks.json'
        foreach ($rec in @((Read-JsonFile -Path $f).Records)) { & $tally (Restore-TaskRecord -Record $rec) }
    }
    if ($Types -contains 'Startup') {
        $f = Join-Path $Dir 'startup/startup.json'
        foreach ($rec in @((Read-JsonFile -Path $f).Records)) { & $tally (Restore-StartupRecord -Record $rec) }
    }
    if ($Types -contains 'PowerPlan') {
        $f = Join-Path $Dir 'power/powerplan.json'
        foreach ($rec in @((Read-JsonFile -Path $f).Records)) { & $tally (Restore-PowerPlanRecord -Record $rec) }
    }
    if ($Types -contains 'Hibernation') {
        $f = Join-Path $Dir 'settings/hibernation.json'
        foreach ($rec in @((Read-JsonFile -Path $f).Records)) { & $tally (Restore-HibernationRecord -Record $rec) }
    }
    if ($Types.Count -ge 6) {
        $f = Join-Path $Dir 'settings/apps.json'
        foreach ($rec in @((Read-JsonFile -Path $f).Records)) {
            Write-Tag INFO "Removed app (not reversible automatically; reinstall from Microsoft Store or another official source): $($rec.Name)"
            $result.Skipped++
        }
    }
    Write-Log -Level INFO -Action 'RESTORE_BACKUP' -Target $Dir -BackupId $id -Result ("ok={0} failed={1} skipped={2}" -f $result.Success, $result.Failed, $result.Skipped)
    return $result
}
# <<<CORE-END
# ---------------------------------------------------------------
# CONSTANTS: power plans, protected lists, catalogs
# ---------------------------------------------------------------

$Script:PlanGuids = @{
    Balanced    = '381b4222-f694-41f0-9685-ff5bb260df2e'
    Performance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    Maximum     = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    Saver       = 'a1841308-3541-4fab-bc81-f71556f20b4a'
}
$Script:PlanLabels = @{ Balanced = 'Balanced'; Performance = 'Performance (High performance)'; Maximum = 'Maximum Performance (Ultimate)' }

# Services DIVoptimizer will refuse to modify, whatever the caller asks. ENFORCED in Test-ServiceProtected.
$Script:DoNotTouchServices = @(
    'wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'BITS', 'TrustedInstaller', 'msiserver', 'CryptSvc',
    'WinDefend', 'WdNisSvc', 'WdNisDrv', 'WdFilter', 'Sense', 'SecurityHealthService', 'wscsvc', 'mpssvc', 'BFE',
    'RpcSs', 'RpcEptMapper', 'DcomLaunch', 'PlugPlay', 'EventLog', 'Winmgmt', 'LanmanWorkstation', 'LanmanServer',
    'Dhcp', 'Dnscache', 'NlaSvc', 'nsi', 'netprofm', 'Netman', 'Wcmsvc', 'WlanSvc', 'Audiosrv', 'AudioEndpointBuilder',
    'ProfSvc', 'UserManager', 'StateRepository', 'Schedule', 'gpsvc', 'LSM', 'SamSs', 'lsass', 'AppXSvc',
    'ClipSVC', 'InstallService', 'DoSvc', 'CoreMessagingRegistrar', 'SystemEventsBroker', 'TimeBrokerSvc', 'themes', 'Power'
)

# Appx packages DIVoptimizer will never remove. ENFORCED in Test-PackageProtected (patterns allowed).
$Script:NeverTouchPackages = @(
    'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI',
    'Microsoft.VCLibs*', 'Microsoft.NET.Native*', 'Microsoft.UI.Xaml*', 'Microsoft.WindowsAppRuntime*', 'Microsoft.Services.Store*',
    'Microsoft.Windows.ShellExperienceHost', 'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.Windows.Search*',
    'Microsoft.Windows.CloudExperienceHost', 'Microsoft.Windows.OOBENetworkCaptivePortal', 'Microsoft.Windows.OOBENetworkConnectionFlow',
    'Microsoft.AAD.BrokerPlugin', 'Microsoft.AccountsControl', 'Microsoft.LockApp', 'Microsoft.Win32WebViewHost', 'Microsoft.WebpImageExtension',
    'Microsoft.HEIFImageExtension', 'Microsoft.VP9VideoExtensions', 'Microsoft.WebMediaExtensions', 'Microsoft.MicrosoftEdge*', 'Microsoft.Edge*',
    'MicrosoftWindows.Client.*', 'Windows.*', 'NcsiUwpApp', 'c5e2524a-ea46-4f67-841f-6a9465d9d515', 'Microsoft.CredDialogHost'
)

# Services that may be offered in Advanced Tools. None is recommended automatically.
$Script:ServiceCatalog = @(
    @{ Name = 'SysMain'; Display = 'SysMain (Superfetch)'; Risk = 'ADVANCED'
       Why = 'Preloads frequently used applications into memory.'
       Impact = 'Mostly helps HDDs. On SSDs the effect is usually small. Disabling can make first launches of some apps slightly slower.'
       Guidance = 'Keep enabled unless you have measured a problem.' },
    @{ Name = 'DiagTrack'; Display = 'Connected User Experiences and Telemetry'; Risk = 'OPTIONAL'
       Why = 'Collects and sends diagnostic data to Microsoft.'
       Impact = 'Less diagnostic data is sent. Some Microsoft feedback/diagnostic features stop working.'
       Guidance = 'Optional privacy preference; has no direct performance benefit you should count on.' }
)

# Optional apps. EXACT package identifiers only; no wildcard matching is ever used for removal.
$Script:AppCatalog = @(
    @{ Package = 'Microsoft.BingNews'; Label = 'Microsoft News'; Category = 'OPTIONAL' },
    @{ Package = 'Microsoft.BingWeather'; Label = 'Weather'; Category = 'USER-DEPENDENT' },
    @{ Package = 'Microsoft.GetHelp'; Label = 'Get Help'; Category = 'OPTIONAL' },
    @{ Package = 'Microsoft.Getstarted'; Label = 'Tips'; Category = 'OPTIONAL' },
    @{ Package = 'Microsoft.MicrosoftOfficeHub'; Label = 'Microsoft 365 (Office) hub'; Category = 'OPTIONAL' },
    @{ Package = 'Microsoft.MicrosoftSolitaireCollection'; Label = 'Solitaire Collection'; Category = 'OPTIONAL' },
    @{ Package = 'Microsoft.MixedReality.Portal'; Label = 'Mixed Reality Portal'; Category = 'OPTIONAL' },
    @{ Package = 'Microsoft.People'; Label = 'People'; Category = 'OPTIONAL' },
    @{ Package = 'Microsoft.SkypeApp'; Label = 'Skype (Store app)'; Category = 'OPTIONAL' },
    @{ Package = 'Microsoft.WindowsFeedbackHub'; Label = 'Feedback Hub'; Category = 'OPTIONAL' },
    @{ Package = 'Microsoft.3DBuilder'; Label = '3D Builder'; Category = 'OPTIONAL' },
    @{ Package = 'Microsoft.Print3D'; Label = 'Print 3D'; Category = 'OPTIONAL' },
    @{ Package = 'Microsoft.PowerAutomateDesktop'; Label = 'Power Automate'; Category = 'USER-DEPENDENT' },
    @{ Package = 'Clipchamp.Clipchamp'; Label = 'Clipchamp video editor'; Category = 'USER-DEPENDENT' },
    @{ Package = 'Microsoft.Todos'; Label = 'Microsoft To Do'; Category = 'USER-DEPENDENT' },
    @{ Package = 'Microsoft.MicrosoftStickyNotes'; Label = 'Sticky Notes'; Category = 'USER-DEPENDENT' },
    @{ Package = 'Microsoft.WindowsMaps'; Label = 'Maps'; Category = 'USER-DEPENDENT' },
    @{ Package = 'Microsoft.YourPhone'; Label = 'Phone Link'; Category = 'USER-DEPENDENT' },
    @{ Package = 'Microsoft.ZuneMusic'; Label = 'Media Player / Groove Music'; Category = 'USER-DEPENDENT' },
    @{ Package = 'Microsoft.ZuneVideo'; Label = 'Movies & TV'; Category = 'USER-DEPENDENT' },
    @{ Package = 'Microsoft.WindowsSoundRecorder'; Label = 'Sound Recorder'; Category = 'USER-DEPENDENT' },
    @{ Package = 'Microsoft.WindowsAlarms'; Label = 'Alarms & Clock'; Category = 'USER-DEPENDENT' },
    @{ Package = 'Microsoft.GamingApp'; Label = 'Xbox app'; Category = 'ADVANCED'; Note = 'Needed for Game Pass and Xbox features.' },
    @{ Package = 'Microsoft.XboxGamingOverlay'; Label = 'Xbox Game Bar'; Category = 'ADVANCED'; Note = 'Needed for the Game Bar overlay.' },
    @{ Package = 'Microsoft.XboxIdentityProvider'; Label = 'Xbox Identity Provider'; Category = 'ADVANCED'; Note = 'Needed for Xbox/Microsoft Store game sign-in (for example Minecraft).' },
    @{ Package = 'Microsoft.Xbox.TCUI'; Label = 'Xbox Live in-game UI'; Category = 'ADVANCED'; Note = 'Needed for Xbox sign-in dialogs inside games.' }
)

$Script:Profiles = [ordered]@{
    'Gaming'      = 'Game Mode, Game DVR/background recording, startup review, optional background activity.'
    'Laptop'      = 'Battery life, thermals, background activity, startup apps, Balanced power.'
    'Desktop'     = 'Performance, background activity, startup, gaming, storage. Security and Windows Update stay on.'
    'LowResource' = 'Startup apps, background activity and visual effects for PCs with limited RAM.'
}

# ---------------------------------------------------------------
# BACKUP ENGINE
# ---------------------------------------------------------------

function New-Backup {
    param([string]$Description = '', [string]$ProfileName = '')
    $stamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
    $id = ('backup-{0}-{1:X4}' -f $stamp, (Get-Random -Minimum 0 -Maximum 65536))
    while (Test-Path -LiteralPath (Join-Path $Script:BackupsDir $id)) { $id = ('backup-{0}-{1:X4}' -f $stamp, (Get-Random -Minimum 0 -Maximum 65536)) }
    $dir = Join-Path $Script:BackupsDir $id
    foreach ($sub in @('registry', 'services', 'tasks', 'startup', 'power', 'settings')) {
        New-Item -ItemType Directory -Path (Join-Path $dir $sub) -Force -ErrorAction Stop | Out-Null
    }
    $s = [pscustomobject]@{
        Id = $id; Dir = $dir; Description = $Description; Profile = $ProfileName
        Created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Records = @{
            Registry = (New-Object System.Collections.Generic.List[object]); Services = (New-Object System.Collections.Generic.List[object])
            Tasks = (New-Object System.Collections.Generic.List[object]); Startup = (New-Object System.Collections.Generic.List[object])
            PowerPlan = (New-Object System.Collections.Generic.List[object]); Hibernation = (New-Object System.Collections.Generic.List[object])
            Apps = (New-Object System.Collections.Generic.List[object])
        }
        NotReversible = (New-Object System.Collections.Generic.List[string])
        Changes = (New-Object System.Collections.Generic.List[object])
        SystemRestore = [pscustomobject]@{ Status = 'Not attempted'; Message = '' }
        Applied = $null
    }
    $Script:BackupSession = $s
    Write-Log -Level INFO -Action 'BACKUP_CREATE' -Target $dir -BackupId $id -Message $Description
    return $s
}

function Backup-RegistryValue {
    param([string]$Path, [string]$Name, [string]$TweakId = '')
    $s = $Script:BackupSession
    if (-not $s) { throw 'No backup session is open.' }
    foreach ($r in $s.Records.Registry) {
        if ($r.Path -eq $Path -and $r.Name -eq $Name) { return $r }   # first capture = original state wins
    }
    $st = Get-RegistryValueState -Path $Path -Name $Name
    $supported = $true
    $val = $null
    if ($st.Exists) {
        if (@('String', 'ExpandString', 'DWord', 'QWord', 'MultiString', 'Binary') -contains $st.Type) {
            $val = ConvertTo-RegistryRecordValue -Type $st.Type -Value $st.Value
        } else { $supported = $false }
    }
    $rec = [pscustomobject]@{
        TweakId = $TweakId; Path = $Path; Name = $Name; Type = $st.Type; Exists = $st.Exists
        Value = $val; KeyExisted = $st.KeyExists; Supported = $supported
    }
    $s.Records.Registry.Add($rec)
    return $rec
}

function Backup-Service {
    param([string]$Name, [string]$TweakId = '')
    $s = $Script:BackupSession
    if (-not $s) { throw 'No backup session is open.' }
    foreach ($r in $s.Records.Services) { if ($r.ServiceName -eq $Name) { return $r } }
    $i = Get-ServiceInfo -Name $Name
    if (-not $i.Exists) { return $null }
    $rec = [pscustomobject]@{
        TweakId = $TweakId; ServiceName = $Name; DisplayName = $i.DisplayName; StartMode = $i.StartMode
        StartupType = $i.StartupType; DelayedAutoStart = $i.Delayed; Status = $i.Status
    }
    $s.Records.Services.Add($rec)
    return $rec
}

function Backup-ScheduledTask {
    param([string]$TaskPath, [string]$TaskName, [string]$TweakId = '')
    $s = $Script:BackupSession
    if (-not $s) { throw 'No backup session is open.' }
    $i = Get-TaskInfo -TaskPath $TaskPath -TaskName $TaskName
    if (-not $i.Exists) { return $null }
    foreach ($r in $s.Records.Tasks) { if ($r.TaskPath -eq $i.TaskPath -and $r.TaskName -eq $TaskName) { return $r } }
    $rec = [pscustomobject]@{ TweakId = $TweakId; TaskPath = $i.TaskPath; TaskName = $TaskName; State = $i.State; Enabled = $i.Enabled }
    $s.Records.Tasks.Add($rec)
    return $rec
}

function Backup-PowerPlan {
    param([string]$TweakId = '')
    $s = $Script:BackupSession
    if (-not $s) { throw 'No backup session is open.' }
    if ($s.Records.PowerPlan.Count -gt 0) { return $s.Records.PowerPlan[0] }
    $p = Get-ActivePowerPlan
    if (-not $p) { return $null }
    $rec = [pscustomobject]@{ TweakId = $TweakId; Guid = $p.Guid; Name = $p.Name; CreatedPlanGuid = '' }
    $s.Records.PowerPlan.Add($rec)
    return $rec
}

function Backup-Hibernation {
    param([string]$TweakId = '')
    $s = $Script:BackupSession
    if (-not $s) { throw 'No backup session is open.' }
    if ($s.Records.Hibernation.Count -gt 0) { return $s.Records.Hibernation[0] }
    $h = Get-HibernationState
    if ($null -eq $h) { return $null }
    $rec = [pscustomobject]@{ TweakId = $TweakId; Enabled = $h }
    $s.Records.Hibernation.Add($rec)
    return $rec
}

function Backup-StartupItem {
    param($Item, [string]$TweakId = '')
    $s = $Script:BackupSession
    if (-not $s) { throw 'No backup session is open.' }
    $st = Get-RegistryValueState -Path $Item.ApprovedPath -Name $Item.ApprovedName
    $b64 = $null
    if ($st.Exists -and $st.Type -eq 'Binary') { $b64 = [System.Convert]::ToBase64String([byte[]]$st.Value) }
    $rec = [pscustomobject]@{
        TweakId = $TweakId; Name = $Item.Name; Location = $Item.Location; Command = $Item.Command; OriginalEnabled = $Item.Enabled
        ApprovedPath = $Item.ApprovedPath; ApprovedName = $Item.ApprovedName
        ApprovedExists = ($st.Exists -and $st.Type -eq 'Binary'); ApprovedValue = $b64; ApprovedKeyExisted = $st.KeyExists
    }
    $s.Records.Startup.Add($rec)
    return $rec
}

function Backup-AppRemoval {
    # Informational only: removal is NOT reversible automatically.
    param([string]$Package, [string]$TweakId = '')
    $s = $Script:BackupSession
    if (-not $s) { throw 'No backup session is open.' }
    $found = @(Get-AppxPackage -Name $Package -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $Package })
    foreach ($p in $found) {
        $s.Records.Apps.Add([pscustomobject]@{
            TweakId = $TweakId; Name = [string]$p.Name; PackageFullName = [string]$p.PackageFullName; Version = [string]$p.Version
            PackageFamilyName = [string]$p.PackageFamilyName; Publisher = [string]$p.Publisher; Reversible = $false
        })
    }
    return @($found)
}

function Save-BackupSession {
    $s = $Script:BackupSession
    if (-not $s) { throw 'No backup session is open.' }
    $map = @(
        @{ Rel = 'registry/registry.json'; Key = 'Registry' }, @{ Rel = 'services/services.json'; Key = 'Services' },
        @{ Rel = 'tasks/tasks.json'; Key = 'Tasks' }, @{ Rel = 'startup/startup.json'; Key = 'Startup' },
        @{ Rel = 'power/powerplan.json'; Key = 'PowerPlan' }, @{ Rel = 'settings/hibernation.json'; Key = 'Hibernation' },
        @{ Rel = 'settings/apps.json'; Key = 'Apps' }
    )
    $files = [ordered]@{}
    $counts = [ordered]@{}
    foreach ($m in $map) {
        $path = Join-Path $s.Dir $m.Rel
        Write-JsonFile -Path $path -Object ([ordered]@{ Records = $s.Records[$m.Key].ToArray() })
        $files[$m.Rel] = Get-Sha256 -Path $path
        $counts[$m.Key] = $s.Records[$m.Key].Count
    }
    $win = $Script:LastScan
    $meta = [ordered]@{
        SchemaVersion = $Script:SchemaVersion; BackupId = $s.Id; ToolVersion = $Script:Version; Created = $s.Created
        User = $env:USERNAME; Computer = $env:COMPUTERNAME
        WindowsVersion = $(if ($win) { $win.Windows.Version } else { '' }); WindowsBuild = $(if ($win) { $win.Windows.Build } else { '' })
        IsAdmin = (Test-Administrator); Description = $s.Description; Profile = $s.Profile
        SystemRestore = $s.SystemRestore; Counts = $counts; NotReversible = $s.NotReversible.ToArray()
        Changes = $s.Changes.ToArray(); Applied = $s.Applied
        LogFile = $(if ($Script:SessionLogPath) { Split-Path -Leaf $Script:SessionLogPath } else { '' })
        Files = $files
    }
    Write-JsonFile -Path (Join-Path $s.Dir 'backup.json') -Object $meta
}

function Test-Backup {
    # Re-reads what was written and compares it with what is in memory.
    param([string]$Dir)
    $chk = Test-BackupDir -Dir $Dir
    $s = $Script:BackupSession
    if ($chk.Ok -and $s -and $s.Dir -eq $Dir) {
        $counts = $chk.Meta.Counts
        foreach ($k in @('Registry', 'Services', 'Tasks', 'Startup', 'PowerPlan', 'Hibernation', 'Apps')) {
            if ([int]$counts.$k -ne $s.Records[$k].Count) { $chk.Problems += "Record count mismatch for $k"; $chk.Ok = $false }
        }
    }
    return $chk
}

function Get-BackupsOverRetention {
    $set = Get-DivSettings
    if ([string]$set.BackupRetention -eq 'All') { return @() }
    $keep = [int]$set.BackupRetention
    $all = @(Get-BackupList | Where-Object { $_.Format -eq 'v2' })
    if ($all.Count -le $keep) { return @() }
    return @($all | Select-Object -Skip $keep)
}

function Remove-BackupFolder {
    # The caller MUST have shown the user the backup details and obtained confirmation.
    param([string]$Dir)
    $full = [System.IO.Path]::GetFullPath($Dir)
    $ok = $false
    foreach ($root in @($Script:BackupsDir, $Script:LegacyBackupsDir)) {
        if (-not $root) { continue }
        $r = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
        if ((Split-Path -Parent $full).TrimEnd('\') -ieq $r) { $ok = $true }
    }
    if (-not $ok) { throw "Refusing to delete '$Dir': it is not a direct child of a DIVoptimizer backup folder." }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    Write-Log -Level INFO -Action 'BACKUP_DELETE' -Target $full -Result 'SUCCESS'
}

# ---------------------------------------------------------------
# TWEAK MODEL
# ---------------------------------------------------------------

function New-Tweak {
    param([hashtable]$P)
    $t = [ordered]@{
        Id = ''; Name = ''; Category = ''; Risk = 'OPTIONAL'; Kind = 'Registry'
        Entries = @(); Labels = @{}
        Service = ''; ServiceTarget = 'Disabled'; Tasks = @(); PlanKey = ''; CleanupTarget = ''; Package = ''
        StartupItem = $null; StartupEnable = $false
        Reason = ''; Downside = ''; Restart = 'No'; Rollback = 'Full'; RollbackNote = ''; NeedsAdmin = $false
        MinBuild = 0; MaxBuild = 0; Generations = @(); Recommend = $null; Guard = $null
        Profiles = @(); Selectable = $true; OfferAlways = $false; Detail = ''
    }
    foreach ($k in $P.Keys) { $t[$k] = $P[$k] }
    return [pscustomobject]$t
}

# Only these services may ever be changed. Everything else is protected by default (deny by default).
$Script:ServiceAllowList = @('DiagTrack', 'SysMain')

function Test-ServiceProtected {
    param([string]$Name)
    if (@($Script:DoNotTouchServices | Where-Object { $_ -ieq $Name }).Count -gt 0) { return $true }
    return (@($Script:ServiceAllowList | Where-Object { $_ -ieq $Name }).Count -eq 0)
}

function Test-PackageProtected {
    param([string]$Name)
    foreach ($pat in $Script:NeverTouchPackages) { if ($Name -like $pat) { return $true } }
    return $false
}

function New-ServiceTweak {
    param($Entry, [string]$Target = 'Disabled')
    $name = [string]$Entry.Name
    $verb = switch ($Target) { 'Disabled' { 'Disable' } 'Manual' { 'Set to Manual' } default { 'Set to Automatic' } }
    return (New-Tweak @{
        Id = ("svc-{0}-{1}" -f $name.ToLower(), $Target.ToLower()); Name = ("{0}: {1}" -f $verb, $Entry.Display); Category = 'Services'
        Risk = $Entry.Risk; Kind = 'Service'; Service = $name; ServiceTarget = $Target; NeedsAdmin = $true
        Reason = $Entry.Why; Downside = $Entry.Impact; Restart = 'No'; Rollback = 'Full'
        Detail = $Entry.Guidance; Guard = $(if ($Entry.Guard) { $Entry.Guard } else { $null })
        Profiles = @()
    })
}

function New-AppTweak {
    param($Entry)
    return (New-Tweak @{
        Id = ('app-' + ([string]$Entry.Package).ToLower()); Name = ('Remove app: ' + $Entry.Label); Category = 'Optional Apps'
        Risk = $Entry.Category; Kind = 'App'; Package = [string]$Entry.Package; NeedsAdmin = $false
        Reason = 'You chose to remove this application.'
        Downside = $(if ($Entry.Note) { $Entry.Note } else { 'The app is no longer available until reinstalled.' })
        Restart = 'No'; Rollback = 'None'
        RollbackNote = 'This removes the selected Windows application. The application may need to be reinstalled from Microsoft Store or another official source.'
    })
}

function New-StartupTweak {
    param($Item, [bool]$Enable)
    $verb = if ($Enable) { 'Enable' } else { 'Disable' }
    $kind = if ($Item.Kind -eq 'Task') { 'Task' } else { 'Startup' }
    $t = New-Tweak @{
        Id = ('startup-{0}-{1}' -f $verb.ToLower(), (($Item.Id -replace '[^A-Za-z0-9]', '_')))
        Name = ("{0} startup item: {1}" -f $verb, $Item.Name); Category = 'Startup'; Risk = 'OPTIONAL'; Kind = $kind
        StartupItem = $Item; StartupEnable = $Enable; NeedsAdmin = [bool]$Item.RequiresAdmin
        Reason = 'You chose to change this startup item.'
        Downside = $(if ($Enable) { 'The program will start with Windows again.' } else { 'The program will not start automatically; it can still be opened manually. Some programs (sync, security, drivers) rely on starting with Windows.' })
        Restart = 'No'; Rollback = 'Full'; RollbackNote = 'The entry is never deleted; only its enabled flag changes.'
    }
    if ($Item.Kind -eq 'Task') { $t.Tasks = @(@{ Path = $Item.TaskPath; Name = $Item.TaskName }) }
    return $t
}

function Get-TweakCatalog {
    param($Scan)
    $edu = ([string]$Scan.Windows.Edition -match 'Enterprise|Education|Server')
    $teleVal = if ($edu) { 0 } else { 1 }
    $teleLabel = if ($edu) { 'Security (0)' } else { 'Required only (1)' }
    $list = New-Object System.Collections.Generic.List[object]

    $list.Add((New-Tweak @{
        Id = 'gamemode-on'; Name = 'Enable Game Mode'; Category = 'Gaming'; Risk = 'LOW RISK'; Kind = 'Registry'
        Entries = @(
            @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Type = 'DWord'; Value = 1 },
            @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AllowAutoGameMode'; Type = 'DWord'; Value = 1 })
        Labels = @{ '0' = 'Disabled'; '1' = 'Enabled' }
        Reason = 'Game Mode asks Windows to prioritise a running game and limit some background activity.'
        Downside = 'Effect varies by game and system; it can occasionally cause issues with specific software.'
        Profiles = @('Gaming', 'Desktop'); MinBuild = 17134
        Recommend = { param($s, $t) if ((Get-RegValue -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled') -eq 0) { 'Game Mode is currently turned off.' } }
    }))
    $list.Add((New-Tweak @{
        Id = 'gamedvr-off'; Name = 'Disable Game DVR / background recording'; Category = 'Gaming'; Risk = 'LOW RISK'; Kind = 'Registry'
        Entries = @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Type = 'DWord'; Value = 0 },
            @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Type = 'DWord'; Value = 0 })
        Labels = @{ '0' = 'Disabled'; '1' = 'Enabled' }
        Reason = 'Stops Windows from recording gameplay in the background, which uses some CPU/GPU/disk.'
        Downside = 'Game Bar clip capture of past gameplay ("record what happened") will not be available.'
        Profiles = @('Gaming', 'Laptop', 'Desktop', 'LowResource'); MinBuild = 10240
        Recommend = { param($s, $t) if (-not $s.Hardware.IsVirtualMachine -and $s.Features.GameDvr -ne 'Disabled') { "Background game recording is not turned off (currently: $($s.Features.GameDvr))." } }
    }))
    $list.Add((New-Tweak @{
        Id = 'clean-usertemp'; Name = 'Clean user temporary files'; Category = 'Cleanup'; Risk = 'LOW RISK'; Kind = 'Cleanup'; CleanupTarget = 'UserTemp'
        Reason = 'Recovers disk space by removing temporary files. Files in use are skipped.'
        Downside = 'Deleted files cannot be restored. An app that left work files in Temp may lose them.'
        Rollback = 'None'; RollbackNote = 'Deleted temporary files cannot be restored.'
        Profiles = @('Gaming', 'Laptop', 'Desktop', 'LowResource')
        Recommend = { param($s, $t) if ($null -ne $s.UserTempMB -and $s.UserTempMB -ge 200) { "About $($s.UserTempMB) MB of temporary files can be removed." } }
    }))
    $list.Add((New-Tweak @{
        Id = 'startup-review'; Name = 'Review startup apps'; Category = 'Startup'; Risk = 'LOW RISK'; Kind = 'Info'; Selectable = $false
        Reason = 'Startup programs run every time you sign in.'
        Downside = 'None - this only opens the Startup Manager; you decide what to disable.'
        Rollback = 'Full'; Profiles = @('Gaming', 'Laptop', 'Desktop', 'LowResource')
        Recommend = {
            param($s, $t)
            $en = @($s.Startup | Where-Object { $_.Enabled }).Count
            $limit = 8
            if ($s.Hardware.RamGB -le 8) { $limit = 5 }
            if ($en -ge $limit) { "$en startup apps are enabled." }
        }
    }))

    $list.Add((New-Tweak @{
        Id = 'visual-reduce'; Name = 'Reduce animations and transparency'; Category = 'Performance'; Risk = 'OPTIONAL'; Kind = 'Registry'
        Entries = @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency'; Type = 'DWord'; Value = 0 },
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAnimations'; Type = 'DWord'; Value = 0 },
            @{ Path = 'HKCU:\Control Panel\Desktop\WindowMetrics'; Name = 'MinAnimate'; Type = 'String'; Value = '0' })
        Labels = @{ '0' = 'Disabled'; '1' = 'Enabled' }
        Reason = 'Fewer visual effects means slightly less GPU/CPU work for the desktop.'
        Downside = 'The desktop looks plainer. The difference is mainly noticeable on low-end graphics.'
        Restart = 'Sign-out'; Profiles = @('Laptop', 'LowResource'); MinBuild = 10240
        Recommend = {
            param($s, $t)
            if ($s.Hardware.RamGB -le 8) { "This PC has $($s.Hardware.RamGB) GB of RAM; lighter visuals reduce desktop overhead." }
            elseif (-not $s.Hardware.HasDiscreteGpu -and $s.Hardware.RamGB -le 12) { 'This PC uses integrated graphics and modest RAM.' }
        }
    }))
    $list.Add((New-Tweak @{
        Id = 'bgapps-off'; Name = 'Block apps from running in the background'; Category = 'Performance'; Risk = 'OPTIONAL'; Kind = 'Registry'
        Entries = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'; Name = 'GlobalUserDisabled'; Type = 'DWord'; Value = 1 })
        Labels = @{ '0' = 'Allowed'; '1' = 'Blocked' }
        Reason = 'Store apps will not refresh or notify while you are not using them.'
        Downside = 'Mail, messaging and other Store apps may not notify you until opened.'
        Restart = 'Sign-out'; Profiles = @('Gaming', 'Laptop', 'LowResource'); MinBuild = 10240; MaxBuild = 21999; Generations = @(10)
        Recommend = { param($s, $t) if ($s.Hardware.RamGB -le 8 -or $s.Hardware.DeviceType -eq 'Laptop') { 'Reduces background activity of Store apps.' } }
    }))
    $list.Add((New-Tweak @{
        Id = 'power-performance'; Name = 'Use the Performance power plan'; Category = 'Performance'; Risk = 'OPTIONAL'; Kind = 'PowerPlan'; PlanKey = 'Performance'
        Reason = 'Keeps the CPU from dropping into low-power states as aggressively.'
        Downside = 'May increase power consumption. May increase heat and fan noise. May reduce battery life on laptops. Does not automatically improve FPS.'
        Profiles = @('Gaming', 'Desktop')
        Recommend = { param($s, $t) if ($s.Hardware.DeviceType -eq 'Desktop' -and @($Script:PlanGuids.Balanced, $Script:PlanGuids.Saver) -contains $s.Power.PlanGuid) { 'This is a desktop currently on a power-saving plan.' } }
    }))
    $list.Add((New-Tweak @{
        Id = 'power-balanced'; Name = 'Return to the Balanced power plan'; Category = 'Performance'; Risk = 'OPTIONAL'; Kind = 'PowerPlan'; PlanKey = 'Balanced'
        Reason = 'Balanced scales performance with demand and saves battery and heat on laptops.'
        Downside = 'Peak performance may be slightly lower under sustained load.'
        Profiles = @('Laptop')
        Recommend = { param($s, $t) if ($s.Hardware.DeviceType -eq 'Laptop' -and @($Script:PlanGuids.Performance, $Script:PlanGuids.Maximum) -contains $s.Power.PlanGuid) { 'This laptop is on a high-performance plan, which costs battery life and adds heat.' } }
    }))
    $list.Add((New-Tweak @{
        Id = 'hags-on'; Name = 'Hardware-Accelerated GPU Scheduling (HAGS)'; Category = 'Gaming'; Risk = 'OPTIONAL'; Kind = 'Registry'
        Entries = @(@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'HwSchMode'; Type = 'DWord'; Value = 2 })
        Labels = @{ '2' = 'Enabled'; '1' = 'Disabled' }
        Reason = 'Changes how Windows schedules GPU work. Results vary depending on GPU, driver, Windows version and workload.'
        Downside = 'Results vary by GPU, driver and workload; some systems see no change or regressions. If the GPU/driver does not support HAGS the setting has no effect.'
        Restart = 'Restart'; NeedsAdmin = $true; Profiles = @('Gaming', 'Desktop'); MinBuild = 19041
        Recommend = { param($s, $t) if (-not $s.Hardware.IsVirtualMachine -and $s.Hardware.HasDiscreteGpu -and $s.Features.HagsRaw -ne 2) { 'A discrete GPU was detected. You can try HAGS and compare.' } }
    }))

    $list.Add((New-Tweak @{
        Id = 'privacy-adid'; Name = 'Turn off the advertising ID'; Category = 'Privacy'; Risk = 'OPTIONAL'; Kind = 'Registry'; OfferAlways = $true
        Entries = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Type = 'DWord'; Value = 0 })
        Labels = @{ '0' = 'Disabled'; '1' = 'Enabled' }
        Reason = 'Stops apps using an ID tied to you to personalise ads.'
        Downside = 'Ads you see in apps become less relevant (not fewer).'
    }))
    $list.Add((New-Tweak @{
        Id = 'privacy-tailored'; Name = 'Turn off tailored experiences'; Category = 'Privacy'; Risk = 'OPTIONAL'; Kind = 'Registry'; OfferAlways = $true
        Entries = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Type = 'DWord'; Value = 0 })
        Labels = @{ '0' = 'Disabled'; '1' = 'Enabled' }
        Reason = 'Stops Windows using your diagnostic data to suggest tips and offers.'
        Downside = 'Personalised tips and suggestions are replaced by generic ones.'
    }))
    $list.Add((New-Tweak @{
        Id = 'privacy-diag'; Name = 'Limit diagnostic data'; Category = 'Privacy'; Risk = 'OPTIONAL'; Kind = 'Registry'; OfferAlways = $true; NeedsAdmin = $true
        Entries = @(@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Type = 'DWord'; Value = $teleVal })
        Labels = @{ '0' = 'Security (0)'; '1' = 'Required only (1)'; '2' = 'Enhanced (2)'; '3' = 'Optional/Full (3)' }
        Reason = ("Reduces the diagnostic data level to the minimum this edition honours: $teleLabel.")
        Downside = 'Settings shows "managed by your organization". Home/Pro treat level 0 as 1, so this sets 1 there. Does not guarantee no data is sent.'
    }))
    $list.Add((New-Tweak @{
        Id = 'privacy-feedback'; Name = 'Reduce feedback prompts'; Category = 'Privacy'; Risk = 'OPTIONAL'; Kind = 'Registry'; OfferAlways = $true
        Entries = @(@{ Path = 'HKCU:\Software\Microsoft\Siuf\Rules'; Name = 'NumberOfSIUFInPeriod'; Type = 'DWord'; Value = 0 })
        Labels = @{ '0' = 'Never ask' }
        Reason = 'Windows will not ask for feedback as often.'
        Downside = 'None significant.'
    }))
    if ($Scan.Windows.Generation -eq 11) {
        $list.Add((New-Tweak @{
            Id = 'privacy-websearch'; Name = 'Turn off web results in Start search'; Category = 'Privacy'; Risk = 'OPTIONAL'; Kind = 'Registry'; OfferAlways = $true
            Entries = @(@{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Type = 'DWord'; Value = 1 })
            Labels = @{ '1' = 'Web results off' }
            Reason = 'Start search stays local instead of sending queries to Bing.'
            Downside = 'No web suggestions in Start search.'
            Restart = 'Sign-out'; MinBuild = 22000; Generations = @(11)
        }))
    } else {
        $list.Add((New-Tweak @{
            Id = 'privacy-websearch'; Name = 'Turn off web results in Start search'; Category = 'Privacy'; Risk = 'OPTIONAL'; Kind = 'Registry'; OfferAlways = $true
            Entries = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled'; Type = 'DWord'; Value = 0 })
            Labels = @{ '0' = 'Disabled'; '1' = 'Enabled' }
            Reason = 'Start search stays local instead of sending queries to Bing.'
            Downside = 'No web suggestions in Start search.'
            Restart = 'Sign-out'; MinBuild = 10240; MaxBuild = 21999; Generations = @(10)
        }))
    }

    $list.Add((New-Tweak @{
        Id = 'delivery-opt-off'; Name = 'Delivery Optimization: no peer sharing'; Category = 'Windows Update'; Risk = 'ADVANCED'; Kind = 'Registry'; NeedsAdmin = $true
        Entries = @(@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode'; Type = 'DWord'; Value = 0 })
        Labels = @{ '0' = 'HTTP only (no peers)'; '1' = 'LAN peers'; '3' = 'LAN + Internet peers'; '100' = 'Bypass' }
        Reason = 'Windows Update will not share or fetch update data from other PCs.'
        Downside = 'Updates download only from Microsoft servers; this can be slower on some networks. It is a policy setting that also shows as managed.'
    }))
    $list.Add((New-Tweak @{
        Id = 'hibernate-off'; Name = 'Disable hibernation'; Category = 'Power'; Risk = 'ADVANCED'; Kind = 'Hibernation'; NeedsAdmin = $true
        Reason = 'Frees the hibernation file (hiberfil.sys), which is a large portion of RAM size.'
        Downside = 'Also turns off Fast Startup and hibernate. Laptops lose hibernate-on-low-battery behaviour.'
        Restart = 'No'; Rollback = 'Full'; RollbackNote = 'The previous on/off state is recorded and restored; the hibernation file type uses Windows defaults when re-enabled.'
        Recommend = {
            param($s, $t)
            if ($s.Features.Hibernation -eq 'Enabled' -and $s.Hardware.DeviceType -eq 'Desktop' -and ($s.Storage.FreeGB -lt 30 -or $s.Storage.FreePct -lt 15)) {
                "The system drive has only $($s.Storage.FreeGB) GB free ($($s.Storage.FreePct)%) and this desktop does not need hibernate."
            }
        }
    }))
    $list.Add((New-Tweak @{
        Id = 'tasks-telemetry'; Name = 'Disable telemetry-related scheduled tasks'; Category = 'Scheduled Tasks'; Risk = 'ADVANCED'; Kind = 'Task'; NeedsAdmin = $true
        Tasks = @(
            @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser' },
            @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater' },
            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' },
            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' },
            @{ Path = '\Microsoft\Windows\DiskDiagnostic\'; Name = 'Microsoft-Windows-DiskDiagnosticDataCollector' })
        Reason = 'Stops scheduled diagnostic/telemetry collection jobs.'
        Downside = 'The Compatibility Appraiser also feeds upgrade-readiness checks; disabling it can affect feature-update compatibility decisions.'
    }))
    $list.Add((New-Tweak @{
        Id = 'trim-workingset'; Name = 'Temporary Working-Set Trim'; Category = 'Advanced Tools'; Risk = 'ADVANCED'; Kind = 'Trim'; Rollback = 'None'
        Reason = 'Asks Windows to page out idle memory from background processes.'
        Downside = 'Does not create additional physical RAM. Windows reloads memory when applications need it, which can make apps briefly slower.'
        RollbackNote = 'Temporary; nothing is changed permanently.'
    }))
    foreach ($e in @($Script:ServiceCatalog)) { $list.Add((New-ServiceTweak -Entry $e -Target 'Disabled')) }
    return $list.ToArray()
}

# ---------------------------------------------------------------
# COMPATIBILITY, STATE READING, RECOMMENDATIONS
# ---------------------------------------------------------------

function Test-TweakCompat {
    param($Tweak, $Windows)
    $ok = $true
    if ($Tweak.MinBuild -gt 0 -and $Windows.Build -lt $Tweak.MinBuild) { $ok = $false }
    if ($Tweak.MaxBuild -gt 0 -and $Windows.Build -gt $Tweak.MaxBuild) { $ok = $false }
    if (@($Tweak.Generations).Count -gt 0 -and @($Tweak.Generations) -notcontains $Windows.Generation) { $ok = $false }
    $msg = ''
    if (-not $ok) { $msg = 'This tweak is not available on this Windows version.' }
    return [pscustomobject]@{ Ok = $ok; Message = $msg }
}

function Get-TweakCurrent {
    param($Tweak)
    switch ($Tweak.Kind) {
        'Registry' {
            $e = $Tweak.Entries[0]
            $st = Get-RegistryValueState -Path $e.Path -Name $e.Name
            if (-not $st.Exists) { return 'Default (not set)' }
            return (ConvertTo-StateLabel -Value $st.Value -Labels $Tweak.Labels)
        }
        'Service' { $i = Get-ServiceInfo -Name $Tweak.Service; if (-not $i.Exists) { return 'Not present' }; return ('{0} / {1}' -f $i.StartupType, $i.Status) }
        'Task' {
            $parts = @()
            foreach ($t in $Tweak.Tasks) { $i = Get-TaskInfo -TaskPath $t.Path -TaskName $t.Name; if ($i.Exists) { $parts += $(if ($i.Enabled) { 'Enabled' } else { 'Disabled' }) } }
            if ($parts.Count -eq 0) { return 'Not present' }
            return ((@($parts | Group-Object | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Count })) -join ', ')
        }
        'PowerPlan' { $p = Get-ActivePowerPlan; if ($p) { return $p.Name } else { return 'Unknown' } }
        'Hibernation' { $h = Get-HibernationState; if ($null -eq $h) { return 'Unknown' }; if ($h) { return 'Enabled' } else { return 'Disabled' } }
        'Startup' { if ($Tweak.StartupItem.Enabled) { return 'Enabled' } else { return 'Disabled' } }
        'App' { $n = @(Get-AppxPackage -Name $Tweak.Package -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $Tweak.Package }).Count; if ($n -gt 0) { return 'Installed' } else { return 'Not installed' } }
        'Cleanup' { return 'Files present' }
        'Trim' { return 'Current working sets' }
        default { return '-' }
    }
}

function Get-TweakNew {
    param($Tweak)
    switch ($Tweak.Kind) {
        'Registry' { $e = $Tweak.Entries[0]; return (ConvertTo-StateLabel -Value $e.Value -Labels $Tweak.Labels) }
        'Service' { if ($Tweak.ServiceTarget -eq 'Disabled') { return 'Disabled / Stopped' } else { return $Tweak.ServiceTarget } }
        'Task' { if ($Tweak.StartupEnable) { return 'Enabled' } else { return 'Disabled' } }
        'PowerPlan' { return $Script:PlanLabels[$Tweak.PlanKey] }
        'Hibernation' { return 'Disabled' }
        'Startup' { if ($Tweak.StartupEnable) { return 'Enabled' } else { return 'Disabled' } }
        'App' { return 'Removed' }
        'Cleanup' { return 'Removed (files in use are skipped)' }
        'Trim' { return 'Trimmed (temporary)' }
        default { return 'Review' }
    }
}

function Test-TweakApplied {
    param($Tweak)
    switch ($Tweak.Kind) {
        'Registry' {
            foreach ($e in $Tweak.Entries) {
                $st = Get-RegistryValueState -Path $e.Path -Name $e.Name
                if (-not $st.Exists) { return $false }
                if ($st.Type -ne $e.Type) { return $false }
                if (-not (Test-RegistryValueEquals -Type $e.Type -A $st.Value -B (ConvertFrom-RegistryRecordValue -Type $e.Type -Value $e.Value))) { return $false }
            }
            return $true
        }
        'Service' {
            $i = Get-ServiceInfo -Name $Tweak.Service
            if (-not $i.Exists) { return $true }
            switch ($Tweak.ServiceTarget) {
                'Disabled' { return ($i.StartMode -eq 'Disabled') }
                'Manual'   { return ($i.StartMode -eq 'Manual') }
                default    { return ($i.StartMode -eq 'Auto') }
            }
        }
        'Task' {
            $any = $false
            $want = [bool]$Tweak.StartupEnable
            foreach ($t in $Tweak.Tasks) { $i = Get-TaskInfo -TaskPath $t.Path -TaskName $t.Name; if ($i.Exists) { $any = $true; if ($i.Enabled -ne $want) { return $false } } }
            return $any
        }
        'PowerPlan' {
            $p = Get-ActivePowerPlan
            if (-not $p) { return $false }
            if ($p.Guid -eq $Script:PlanGuids[$Tweak.PlanKey]) { return $true }
            if ($Tweak.PlanKey -eq 'Maximum' -and $p.Name -match 'Ultimate') { return $true }
            return $false
        }
        'Hibernation' { return ((Get-HibernationState) -eq $false) }
        'Startup' {
            $st = Get-RegistryValueState -Path $Tweak.StartupItem.ApprovedPath -Name $Tweak.StartupItem.ApprovedName
            $en = $true
            if ($st.Exists -and $st.Type -eq 'Binary') { $en = Test-StartupApprovedEnabled -Bytes $st.Value }
            return ($en -eq [bool]$Tweak.StartupEnable)
        }
        'App' { return (@(Get-AppxPackage -Name $Tweak.Package -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $Tweak.Package }).Count -eq 0) }
        default { return $false }
    }
}

# Tiers: SAFE = low risk and fully reversible; BALANCED = optional, preference-based; ADVANCED = never pre-selected.
function Get-TweakTier {
    param($Tweak)
    switch ([string]$Tweak.Risk) {
        'LOW RISK' { return 'SAFE' }
        'OPTIONAL' { return 'BALANCED' }
        default    { return 'ADVANCED' }
    }
}

# Tweaks that cost battery life or add heat; never pre-selected on a laptop or tablet.
$Script:LaptopSensitiveIds = @('power-performance', 'hibernate-off')

# WinUtil Compatibility Mode: if a setting was already changed by another tool (WinUtil or similar) to a value
# that is neither Windows' default nor ours, say so and do not pre-select it. The user can still choose it.
function Get-TweakConflict {
    param($Tweak)
    try {
        if ($Tweak.Kind -eq 'Registry') {
            $e = $Tweak.Entries[0]
            $st = Get-RegistryValueState -Path $e.Path -Name $e.Name
            if ($st.Exists -and -not (Test-RegistryValueEquals -Type $e.Type -A $st.Value -B (ConvertFrom-RegistryRecordValue -Type $e.Type -Value $e.Value))) {
                return ('Already set to {0} by Windows or another tool.' -f (ConvertTo-StateLabel -Value $st.Value -Labels $Tweak.Labels))
            }
        }
        if ($Tweak.Kind -eq 'PowerPlan') {
            $p = Get-ActivePowerPlan
            if ($p -and $p.Guid -ne $Script:PlanGuids.Balanced -and $p.Guid -ne $Script:PlanGuids[$Tweak.PlanKey]) { return ('Power plan is already set to {0}.' -f $p.Name) }
        }
    } catch { Write-Log -Level WARN -Action 'CONFLICT_CHECK' -Target $Tweak.Id -ErrorText $_.Exception.Message }
    return ''
}

function Get-Recommendations {
    # Returns one row per tweak with the engine's decision. -All includes non-recommended tweaks.
    param($Scan, [string]$ProfileName = '', [switch]$All)
    $rows = @()
    foreach ($t in @(Get-TweakCatalog -Scan $Scan)) {
        if ($ProfileName -and @($t.Profiles) -notcontains $ProfileName) { continue }
        $compat = Test-TweakCompat -Tweak $t -Windows $Scan.Windows
        $why = $null
        if ($t.Recommend) { try { $why = & $t.Recommend $Scan $t } catch { Write-Log -Level WARN -Action 'RECOMMEND_RULE' -Target $t.Id -ErrorText $_.Exception.Message } }
        $applied = $false
        $block = $null
        if ($compat.Ok) {
            if ($t.Kind -notin @('Cleanup', 'Info', 'Trim')) { $applied = Test-TweakApplied -Tweak $t }
            if ($t.Guard -eq 'Touch' -and $Scan.Hardware.Touch) { $block = 'Touchscreen hardware was detected; this service handles touch and pen input.' }
            if ($t.Kind -eq 'Service') { $si = Get-ServiceInfo -Name $t.Service; if (-not $si.Exists) { $block = 'This service is not present on this PC.' } }
            if ($t.Kind -eq 'Service' -and (Test-ServiceProtected -Name $t.Service)) { $block = 'Protected service.' }
        }
        if (-not $why -and $t.OfferAlways -and $compat.Ok -and -not $applied) { $why = $t.Reason }
        $recommended = ([bool]$why -and $compat.Ok -and -not $block)
        if (-not $All -and -not $recommended) { continue }
        if (-not $All -and $applied -and $t.Kind -ne 'Info') { continue }
        $selectable = ($t.Selectable -and $compat.Ok -and (-not $block) -and (-not $applied))
        $cur = ''
        $new = ''
        if ($compat.Ok -and -not $block) { try { $cur = Get-TweakCurrent -Tweak $t; $new = Get-TweakNew -Tweak $t } catch { Write-Log -Level WARN -Action 'TWEAK_STATE' -Target $t.Id -ErrorText $_.Exception.Message } }
        $tier = Get-TweakTier -Tweak $t
        $laptopSafe = -not (($Scan.Hardware.DeviceType -in @('Laptop', 'Tablet')) -and ($Script:LaptopSensitiveIds -contains $t.Id))
        $conflict = ''
        if ($compat.Ok -and -not $block -and -not $applied -and $t.Kind -in @('Registry', 'PowerPlan')) { $conflict = Get-TweakConflict -Tweak $t }
        $rows += [pscustomobject]@{
            Tier = $tier; LaptopSafe = $laptopSafe; Conflict = $conflict
            Tweak = $t; Id = $t.Id; Name = $t.Name; Category = $t.Category; Risk = $t.Risk; Kind = $t.Kind
            Current = $cur; New = $new; Why = $(if ($why) { [string]$why } else { $t.Reason })
            Reason = $t.Reason; Downside = $t.Downside; Restart = $t.Restart; Rollback = $t.Rollback; RollbackNote = $t.RollbackNote
            Recommended = $recommended; Compatible = $compat.Ok; CompatMessage = $compat.Message; Blocked = $block
            Applied = $applied; Selectable = $selectable
            DefaultSelected = ($selectable -and $recommended -and $tier -eq 'SAFE' -and $t.Rollback -eq 'Full' -and $laptopSafe -and -not $conflict -and $t.Kind -ne 'Info')
        }
    }
    return @($rows)
}

function Get-QuickOptimizeSet {
    param($Scan)
    return @(Get-Recommendations -Scan $Scan | Where-Object { $_.Risk -eq 'LOW RISK' -and $_.Selectable -and $_.Kind -notin @('Info', 'Trim') })
}

# ---------------------------------------------------------------
# CLEANUP / WORKING-SET TRIM / APP REMOVAL PRIMITIVES (used by the apply engine)
# ---------------------------------------------------------------

function Get-CleanupTargets {
    $win = $env:SystemRoot
    return @(
        @{ Key = 'UserTemp'; Name = 'User Temp'; Path = $env:TEMP; Admin = $false; Note = 'Files in use are skipped.' },
        @{ Key = 'WindowsTemp'; Name = 'Windows Temp'; Path = (Join-Path $win 'Temp'); Admin = $true; Note = 'Files in use are skipped.' },
        @{ Key = 'Thumbnails'; Name = 'Thumbnail Cache'; Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'); Filter = 'thumbcache_*.db'; Admin = $false; Note = 'Explorer rebuilds it; many files are in use.' },
        @{ Key = 'DeliveryOpt'; Name = 'Delivery Optimization Cache'; Path = (Join-Path $win 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'); Admin = $true; Note = 'Cached update data.' },
        @{ Key = 'WindowsUpdate'; Name = 'Windows Update Cache'; Path = (Join-Path $win 'SoftwareDistribution\Download'); Admin = $true; Note = 'Temporarily stops the Windows Update service. Skipped if a restart is pending.' },
        @{ Key = 'RecycleBin'; Name = 'Recycle Bin'; Path = ''; Admin = $false; Note = 'Permanently deletes everything in the Recycle Bin.' }
    )
}

function Get-RecycleBinStats {
    $stats = [pscustomobject]@{ Exists = $true; Bytes = [long]0; Files = 0; Locked = 0; LockedSampled = $false }
    try {
        $shell = New-Object -ComObject Shell.Application
        $items = @($shell.Namespace(0xA).Items())
        $stats.Files = $items.Count
        foreach ($i in $items) { $stats.Bytes += [long]$i.Size }
    } catch { Write-Log -Level WARN -Action 'RECYCLE_STATS' -ErrorText $_.Exception.Message }
    return $stats
}

function Get-CleanupEstimate {
    param($Target, [switch]$DetectLocked)
    if ($Target.Key -eq 'RecycleBin') { return (Get-RecycleBinStats) }
    $filter = '*'
    if ($Target.Filter) { $filter = $Target.Filter }
    return (Get-FolderStats -Path $Target.Path -Filter $filter -DetectLocked:$DetectLocked)
}

function Invoke-CleanupTarget {
    param([string]$Key)
    $t = @(Get-CleanupTargets | Where-Object { $_.Key -eq $Key })
    if ($t.Count -ne 1) { throw "Unknown cleanup target '$Key'" }
    $t = $t[0]
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would clean $($t.Name)"; return [pscustomobject]@{ Freed = 0; Removed = 0; Skipped = 0 } }
    if ($t.Admin -and -not (Test-Administrator)) { throw "$($t.Name) requires Administrator." }
    if ($Key -eq 'RecycleBin') {
        $before = Get-RecycleBinStats
        Write-Command 'Clear-RecycleBin -Force'
        Clear-RecycleBin -Force -ErrorAction Stop
        return [pscustomobject]@{ Freed = $before.Bytes; Removed = $before.Files; Skipped = 0 }
    }
    if ($Key -eq 'DeliveryOpt' -and (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)) {
        $before = Get-FolderStats -Path $t.Path
        Write-Command 'Delete-DeliveryOptimizationCache -Force'
        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
        $after = Get-FolderStats -Path $t.Path
        return [pscustomobject]@{ Freed = [math]::Max(0, $before.Bytes - $after.Bytes); Removed = [math]::Max(0, $before.Files - $after.Files); Skipped = $after.Files }
    }
    $wuWasRunning = $false
    if ($Key -eq 'WindowsUpdate') {
        if (Get-PendingRestart) { throw 'A restart is pending; the update cache is not cleaned until after the restart.' }
        $wu = Get-ServiceInfo -Name 'wuauserv'
        $wuWasRunning = ($wu.Status -eq 'Running')
        if ($wuWasRunning) { Stop-ServiceSafe -Name 'wuauserv' }
    }
    Write-Command ("Remove-Item -Path '{0}\{1}' -Recurse -Force   # files in use are skipped" -f $t.Path, $(if ($t.Filter) { $t.Filter } else { '*' }))
    $removed = 0
    $skipped = 0
    $freed = [long]0
    $lastErr = ''
    try {
        $filter = '*'
        if ($t.Filter) { $filter = $t.Filter }
        if (-not (Test-Path -LiteralPath $t.Path)) { return [pscustomobject]@{ Freed = 0; Removed = 0; Skipped = 0 } }
        foreach ($f in @(Get-ChildItem -LiteralPath $t.Path -Filter $filter -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            try { $len = [long]$f.Length; Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed++; $freed += $len }
            catch { $skipped++; $lastErr = $_.Exception.Message }
            if ((($removed + $skipped) % 100) -eq 0) { Write-Busy -Activity ('Cleaning ' + $t.Name) -Status ('{0} files removed, {1} skipped' -f $removed, $skipped) }
        }
        if ($filter -eq '*') {
            foreach ($d in @(Get-ChildItem -LiteralPath $t.Path -Directory -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)) {
                if (@(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                    try { Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop } catch { $skipped++; $lastErr = $_.Exception.Message }
                }
            }
        }
    } finally {
        if ($wuWasRunning) { try { Start-ServiceSafe -Name 'wuauserv' } catch { Write-Tag WARN "Windows Update service could not be restarted: $($_.Exception.Message)" } }
    }
    if ($skipped -gt 0) { Write-Log -Level WARN -Action 'CLEANUP_SKIPPED' -Target $t.Name -Message "$skipped item(s) skipped (in use or protected). Last error: $lastErr" }
    return [pscustomobject]@{ Freed = $freed; Removed = $removed; Skipped = $skipped }
}

$Script:CriticalProcesses = @('System', 'Registry', 'Idle', 'smss', 'csrss', 'wininit', 'services', 'lsass', 'winlogon', 'fontdrvhost', 'dwm', 'svchost', 'MemCompression', 'Secure System', 'explorer', 'powershell', 'pwsh')

function Invoke-WorkingSetTrim {
    # Advanced troubleshooting only. Does NOT create RAM. Windows pages the memory back in on demand.
    if ($Script:DryRun) { Write-Tag INFO '[DRY RUN] would trim working sets'; return [pscustomobject]@{ Trimmed = 0; Skipped = 0 } }
    if (-not ('DivNative.Psapi' -as [type])) {
        Add-Type -Namespace DivNative -Name Psapi -ErrorAction Stop -MemberDefinition '[System.Runtime.InteropServices.DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(System.IntPtr hProcess);'
    }
    $trimmed = 0
    $skipped = 0
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ($Script:CriticalProcesses -contains $p.ProcessName) { continue }
        try {
            if ([DivNative.Psapi]::EmptyWorkingSet($p.Handle)) { $trimmed++ } else { $skipped++ }
        } catch { $skipped++ }
    }
    return [pscustomobject]@{ Trimmed = $trimmed; Skipped = $skipped }
}

function Remove-AppPackageExact {
    param([string]$Name, [switch]$CurrentUserOnly)
    if ($Name -match '[\*\?\[\]]') { throw "Wildcards are not allowed in package names ('$Name')." }
    if (Test-PackageProtected -Name $Name) { throw "$Name is a protected package and will not be removed." }
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would remove package $Name"; return 0 }
    $admin = ((Test-Administrator) -and -not $CurrentUserOnly)
    $pk = @()
    if ($admin) { $pk = @(Get-AppxPackage -Name $Name -AllUsers -ErrorAction Stop | Where-Object { $_.Name -eq $Name }) }
    else { $pk = @(Get-AppxPackage -Name $Name -ErrorAction Stop | Where-Object { $_.Name -eq $Name }) }
    $count = 0
    foreach ($p in $pk) {
        if ($p.IsFramework -or $p.NonRemovable) { Write-Tag SKIP "$($p.Name) is a framework or non-removable package"; continue }
        Write-Command ('Remove-AppxPackage -Package {0}{1}' -f $p.PackageFullName, $(if ($admin) { ' -AllUsers' } else { '' }))
        if ($admin) { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop } else { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop }
        $count++
    }
    if ($admin) {
        foreach ($pp in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $Name })) {
            Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null
        }
    }
    return $count
}

function Resolve-PowerPlanTarget {
    param([string]$PlanKey)
    $guid = $Script:PlanGuids[$PlanKey]
    $plans = @(Get-PowerPlans)
    if (@($plans | Where-Object { $_.Guid -eq $guid }).Count -gt 0) { return [pscustomobject]@{ Guid = $guid; Created = '' } }
    if ($PlanKey -eq 'Balanced') { throw 'The Balanced power plan is missing from this PC.' }
    if ($Script:DryRun) { return [pscustomobject]@{ Guid = $guid; Created = '' } }
    $out = & powercfg.exe -duplicatescheme $guid 2>&1
    $text = ($out | Out-String)
    if ($LASTEXITCODE -ne 0 -or $text -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        throw ("This PC does not offer the $($Script:PlanLabels[$PlanKey]) plan and it could not be created: " + $text.Trim())
    }
    $new = $Matches[1].ToLower()
    return [pscustomobject]@{ Guid = $new; Created = $new }
}

# ---------------------------------------------------------------
# TRANSACTIONAL APPLY ENGINE   PRECHECK -> BACKUP -> CHANGE -> VERIFY (-> ROLLBACK)
# ---------------------------------------------------------------

function Backup-Tweak {
    # Captures the CURRENT state of everything a tweak will touch. Returns a list of problems (strings).
    param($Tweak)
    $problems = New-Object System.Collections.Generic.List[string]
    $s = $Script:BackupSession
    switch ($Tweak.Kind) {
        'Registry' {
            foreach ($e in $Tweak.Entries) {
                $r = Backup-RegistryValue -Path $e.Path -Name $e.Name -TweakId $Tweak.Id
                if (-not $r.Supported) { $problems.Add("Cannot back up $($e.Path)\$($e.Name): unsupported value type $($r.Type)") }
            }
        }
        'Service' { if (-not (Backup-Service -Name $Tweak.Service -TweakId $Tweak.Id)) { $problems.Add("Service $($Tweak.Service) could not be read") } }
        'Task' { foreach ($t in $Tweak.Tasks) { [void](Backup-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -TweakId $Tweak.Id) } }
        'PowerPlan' { if (-not (Backup-PowerPlan -TweakId $Tweak.Id)) { $problems.Add('The active power plan could not be read') } }
        'Hibernation' { if (-not (Backup-Hibernation -TweakId $Tweak.Id)) { $problems.Add('The hibernation state could not be read') } }
        'Startup' { [void](Backup-StartupItem -Item $Tweak.StartupItem -TweakId $Tweak.Id) }
        'App' {
            $found = @(Backup-AppRemoval -Package $Tweak.Package -TweakId $Tweak.Id)
            $s.NotReversible.Add("Remove app: $($Tweak.Package) - may need to be reinstalled from Microsoft Store or another official source")
        }
        'Cleanup' { $s.NotReversible.Add("Cleanup: $($Tweak.Name) - deleted files cannot be restored") }
        'Trim' { $s.NotReversible.Add('Working-set trim: temporary, nothing to restore') }
        default { }
    }
    return $problems.ToArray()
}

function Get-BackupCoverage {
    # For the "Backup status" display. Needed = categories the selected changes touch.
    param([object[]]$Tweaks, $Session)
    $needed = @{ Registry = $false; Services = $false; Tasks = $false; 'Power Plan' = $false; Startup = $false; Hibernation = $false }
    foreach ($t in $Tweaks) {
        switch ($t.Kind) {
            'Registry' { $needed['Registry'] = $true }
            'Service' { $needed['Services'] = $true }
            'Task' { $needed['Tasks'] = $true }
            'PowerPlan' { $needed['Power Plan'] = $true }
            'Hibernation' { $needed['Hibernation'] = $true }
            'Startup' { $needed['Startup'] = $true }
            default { }
        }
    }
    $rows = @()
    foreach ($k in @('Registry', 'Services', 'Tasks', 'Power Plan', 'Startup', 'Hibernation')) {
        $key = $k -replace ' ', ''
        $covered = $false
        if ($Session) { $covered = (@($Session.Records[$key]).Count -gt 0) }
        $rows += [pscustomobject]@{ Name = $k; Needed = $needed[$k]; Covered = $covered }
    }
    return @($rows)
}

function Get-ApplyReadiness {
    param([object[]]$Tweaks)
    $writable = $false
    $why = ''
    try {
        if (-not (Test-Path -LiteralPath $Script:BackupsDir)) { New-Item -ItemType Directory -Path $Script:BackupsDir -Force -ErrorAction Stop | Out-Null }
        $probe = Join-Path $Script:BackupsDir ('.write-test-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
        $writable = $true
    } catch { $why = $_.Exception.Message }
    $admin = Test-Administrator
    $needAdmin = (@($Tweaks | Where-Object { $_.NeedsAdmin }).Count -gt 0)
    $notRev = @($Tweaks | Where-Object { $_.Rollback -eq 'None' } | ForEach-Object { $_.Name })
    $rpText = 'READY'
    if (-not $admin) { $rpText = 'NOT AVAILABLE (requires Administrator)' }
    return [pscustomobject]@{
        BackupReady = $writable; BackupProblem = $why; RestorePointText = $rpText; IsAdmin = $admin
        NeedsAdmin = $needAdmin; NeedsElevation = ($needAdmin -and -not $admin); NotReversible = @($notRev)
        HasAdvanced = (@($Tweaks | Where-Object { $_.Risk -eq 'ADVANCED' }).Count -gt 0)
        Coverage = @(Get-BackupCoverage -Tweaks $Tweaks -Session $null)
    }
}

function New-DivRestorePoint {
    param([string]$Description)
    if ($Script:DryRun) { return [pscustomobject]@{ Status = 'Skipped'; Message = 'dry run' } }
    if (-not (Test-Administrator)) { return [pscustomobject]@{ Status = 'Skipped'; Message = 'Creating a restore point requires Administrator.' } }
    try {
        Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction Stop
    } catch {
        Write-Log -Level WARN -Action 'RESTORE_POINT' -ErrorText ('Enable-ComputerRestore: ' + $_.Exception.Message)
    }
    try {
        Checkpoint-Computer -Description ("DIVoptimizer v{0} - {1}" -f $Script:Version, $Description) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable rpWarn
        if ($rpWarn) { return [pscustomobject]@{ Status = 'Skipped'; Message = (($rpWarn | Out-String).Trim()) } }
        Write-Log -Level INFO -Action 'RESTORE_POINT' -Result 'CREATED'
        return [pscustomobject]@{ Status = 'Created'; Message = '' }
    } catch {
        Write-Log -Level FAIL -Action 'RESTORE_POINT' -Result 'FAILED' -ErrorText $_.Exception.Message
        return [pscustomobject]@{ Status = 'Failed'; Message = $_.Exception.Message }
    }
}

function Restore-TweakRecords {
    # Rollback of ONE tweak from the in-memory backup records tagged with its Id.
    param($Tweak)
    $s = $Script:BackupSession
    if (-not $s) { return }
    foreach ($r in @($s.Records.Registry | Where-Object { $_.TweakId -eq $Tweak.Id })) { [void](Restore-RegistryValue -Record $r) }
    foreach ($r in @($s.Records.Services | Where-Object { $_.TweakId -eq $Tweak.Id })) { [void](Restore-ServiceRecord -Record $r) }
    foreach ($r in @($s.Records.Tasks | Where-Object { $_.TweakId -eq $Tweak.Id })) { [void](Restore-TaskRecord -Record $r) }
    foreach ($r in @($s.Records.Startup | Where-Object { $_.TweakId -eq $Tweak.Id })) { [void](Restore-StartupRecord -Record $r) }
    foreach ($r in @($s.Records.PowerPlan | Where-Object { $_.TweakId -eq $Tweak.Id })) { [void](Restore-PowerPlanRecord -Record $r) }
    foreach ($r in @($s.Records.Hibernation | Where-Object { $_.TweakId -eq $Tweak.Id })) { [void](Restore-HibernationRecord -Record $r) }
}

function Invoke-TweakChange {
    # The CHANGE step. Throws on failure. Verification is done by the caller.
    param($Tweak)
    switch ($Tweak.Kind) {
        'Registry' {
            foreach ($e in $Tweak.Entries) {
                Set-RegistryValueSafe -Path $e.Path -Name $e.Name -Type $e.Type -Value (ConvertFrom-RegistryRecordValue -Type $e.Type -Value $e.Value) | Out-Null
            }
        }
        'Service' {
            if (Test-ServiceProtected -Name $Tweak.Service) { throw "$($Tweak.Service) is a protected service." }
            $mode = switch ($Tweak.ServiceTarget) { 'Disabled' { 'disabled' } 'Manual' { 'demand' } default { 'auto' } }
            Set-ServiceStartMode -Name $Tweak.Service -Mode $mode | Out-Null
            if ($Tweak.ServiceTarget -eq 'Disabled') {
                $i = Get-ServiceInfo -Name $Tweak.Service
                if ($i.Status -eq 'Running') {
                    try { Stop-ServiceSafe -Name $Tweak.Service } catch { Write-Tag WARN "$($Tweak.Service) is disabled but could not be stopped now (it stops at next restart): $($_.Exception.Message)" }
                }
            }
        }
        'Task' { foreach ($t in $Tweak.Tasks) { $i = Get-TaskInfo -TaskPath $t.Path -TaskName $t.Name; if ($i.Exists) { Set-TaskEnabledSafe -TaskPath $t.Path -TaskName $t.Name -Enabled ([bool]$Tweak.StartupEnable) | Out-Null } } }
        'PowerPlan' {
            $r = Resolve-PowerPlanTarget -PlanKey $Tweak.PlanKey
            if ($r.Created -and $Script:BackupSession -and $Script:BackupSession.Records.PowerPlan.Count -gt 0) { $Script:BackupSession.Records.PowerPlan[0].CreatedPlanGuid = $r.Created }
            Set-ActivePowerPlan -Guid $r.Guid | Out-Null
        }
        'Hibernation' { Set-HibernationState -Enabled $false | Out-Null }
        'Startup' {
            $bytes = New-StartupApprovedBytes -Enabled ([bool]$Tweak.StartupEnable)
            Set-RegistryValueSafe -Path $Tweak.StartupItem.ApprovedPath -Name $Tweak.StartupItem.ApprovedName -Type Binary -Value $bytes | Out-Null
        }
        'App' { [void](Remove-AppPackageExact -Name $Tweak.Package) }
        'Cleanup' {
            $r = Invoke-CleanupTarget -Key $Tweak.CleanupTarget
            $Tweak | Add-Member -NotePropertyName ResultNote -NotePropertyValue ("freed {0}; {1} file(s) removed, {2} skipped" -f (Format-Bytes $r.Freed), $r.Removed, $r.Skipped) -Force
        }
        'Trim' {
            $r = Invoke-WorkingSetTrim
            $Tweak | Add-Member -NotePropertyName ResultNote -NotePropertyValue ("{0} process(es) trimmed, {1} skipped" -f $r.Trimmed, $r.Skipped) -Force
        }
        default { throw "Tweak kind '$($Tweak.Kind)' cannot be applied." }
    }
}

function Invoke-ApplyPlan {
    param(
        [object[]]$Tweaks,
        [string]$Description = 'Optimization',
        [string]$ProfileName = '',
        [switch]$AdvancedConfirmed,
        [scriptblock]$Prompt,
        [scriptblock]$Progress
    )
    $res = [pscustomobject]@{
        Aborted = $false; AbortReason = ''; NeedsElevation = $false; BackupId = ''; BackupOk = $false; BackupDir = ''
        RestorePoint = [pscustomobject]@{ Status = 'Not attempted'; Message = '' }
        Items = @(); Success = 0; Failed = 0; Skipped = 0; RestartNeeded = $false; RestartReasons = @(); LogFile = ''
    }
    $say = { param($m, $p = -1) if ($Progress) { & $Progress $m $p } else { Write-Busy -Activity 'Applying changes' -Status $m -Percent $p } }
    $abort = { param($why) Clear-Busy; $res.Aborted = $true; $res.AbortReason = $why; Write-Log -Level WARN -Action 'APPLY_ABORT' -Message $why; return $res }

    if ($Script:DryRun) { return (& $abort 'Dry run: no changes are made.') }
    if (@($Tweaks).Count -eq 0) { return (& $abort 'Nothing was selected.') }
    $isAdv = (@($Tweaks | Where-Object { $_.Risk -eq 'ADVANCED' }).Count -gt 0)
    if ($isAdv -and -not $AdvancedConfirmed) { return (& $abort 'Advanced changes need explicit confirmation.') }
    if ((@($Tweaks | Where-Object { $_.NeedsAdmin }).Count -gt 0) -and -not (Test-Administrator)) {
        $res.NeedsElevation = $true
        return (& $abort 'Some selected changes require Administrator.')
    }
    foreach ($t in $Tweaks) {
        $c = Test-TweakCompat -Tweak $t -Windows $Script:LastScan.Windows
        if (-not $c.Ok) { return (& $abort "'$($t.Name)': $($c.Message)") }
    }

    # 1. System Restore point
    & $say 'Creating a System Restore point...' 5
    $rp = New-DivRestorePoint -Description $Description
    $res.RestorePoint = $rp
    if ($rp.Status -eq 'Failed') {
        Write-Tag WARN "System Restore point could not be created: $($rp.Message)"
        $go = $false
        if ($Prompt) { $go = [bool](& $Prompt ("A System Restore point could not be created:`n$($rp.Message)`n`nContinue anyway? DIVoptimizer's own backup will still be made.") $isAdv) }
        if (-not $go) { return (& $abort 'Cancelled because the System Restore point failed.') }
    }

    # 2. DIVoptimizer backup (captured BEFORE any change), then 3. verify it
    & $say 'Creating and verifying the backup...' 15
    $backupProblems = @()
    try {
        $s = New-Backup -Description $Description -ProfileName $ProfileName
        $s.SystemRestore = [pscustomobject]@{ Status = $rp.Status; Message = $rp.Message }
        foreach ($t in $Tweaks) { $backupProblems += @(Backup-Tweak -Tweak $t) }
        Save-BackupSession
        $chk = Test-Backup -Dir $s.Dir
        if (-not $chk.Ok) { $backupProblems += @($chk.Problems) }
        $res.BackupId = $s.Id; $res.BackupDir = $s.Dir
    } catch {
        $backupProblems += $_.Exception.Message
    }
    $res.BackupOk = (@($backupProblems).Count -eq 0)
    if (-not $res.BackupOk) {
        Write-Log -Level FAIL -Action 'BACKUP_VERIFY' -BackupId $res.BackupId -ErrorText (@($backupProblems) -join ' | ')
        Write-Tag FAIL ('Backup problem: ' + (@($backupProblems) -join ' | '))
        if ($isAdv) { return (& $abort 'Advanced changes were cancelled because the backup failed.') }
        $go = $false
        if ($Prompt) { $go = [bool](& $Prompt ("The backup could not be created or verified:`n" + (@($backupProblems) -join "`n") + "`n`nContinue WITHOUT a complete backup? These changes would not be automatically reversible.") $false) }
        if (-not $go) { return (& $abort 'Cancelled because the backup failed.') }
    }

    # 4. Apply, one transaction per tweak
    $items = @()
    $doneCount = 0
    $totalCount = [Math]::Max(1, @($Tweaks).Count)
    foreach ($t in $Tweaks) {
        $pct = 20 + [int](75 * $doneCount / $totalCount)
        & $say ("Applying ({0} of {1}): {2}" -f ($doneCount + 1), $totalCount, $t.Name) $pct
        $doneCount++
        $item = [pscustomobject]@{ Id = $t.Id; Name = $t.Name; Risk = $t.Risk; Status = 'Failed'; Message = ''; Before = ''; After = '' }
        try {
            $item.Before = Get-TweakCurrent -Tweak $t
            if (($t.Kind -notin @('Cleanup', 'Info', 'Trim')) -and (Test-TweakApplied -Tweak $t)) {
                $item.Status = 'Skipped'; $item.Message = 'Already in the requested state.'; $item.After = $item.Before
            } else {
                if ($t.Kind -eq 'Registry' -and $res.BackupOk) {
                    foreach ($e in $t.Entries) {
                        $rec = @($Script:BackupSession.Records.Registry | Where-Object { $_.Path -eq $e.Path -and $_.Name -eq $e.Name })
                        if ($rec.Count -gt 0 -and -not $rec[0].Supported) { throw "The existing value type of $($e.Path)\$($e.Name) cannot be backed up, so it was left unchanged." }
                    }
                }
                Invoke-TweakChange -Tweak $t
                if ($t.Kind -in @('Cleanup', 'Trim')) {
                    $item.Status = 'Success'; $item.Message = [string]$t.ResultNote; $item.After = $item.Message
                } else {
                    if (-not (Test-TweakApplied -Tweak $t)) { throw 'Verification failed: the setting did not change as expected.' }
                    $item.After = Get-TweakCurrent -Tweak $t
                    $item.Status = 'Success'
                }
            }
        } catch {
            $item.Status = 'Failed'; $item.Message = $_.Exception.Message
            Write-Tag FAIL ("{0}: {1}" -f $t.Name, $_.Exception.Message)
            if ($res.BackupOk -and $t.Kind -notin @('Cleanup', 'Trim', 'App')) {
                Write-Tag INFO "Rolling back: $($t.Name)"
                try { Restore-TweakRecords -Tweak $t; $item.Message += ' (rolled back to the previous state)' } catch { $item.Message += ' (rollback also failed: ' + $_.Exception.Message + ')' }
            }
        }
        $logResult = $item.Status.ToUpper()
        Write-Log -Level $(if ($item.Status -eq 'Failed') { 'FAIL' } else { 'INFO' }) -Action 'TWEAK_APPLY' -Target $t.Name -Before $item.Before -After $item.After -BackupId $res.BackupId -Result $logResult -ErrorText $(if ($item.Status -eq 'Failed') { $item.Message } else { '' }) -Message $item.Message
        $items += $item
        if ($item.Status -eq 'Success') {
            $res.Success++
            if ($t.Restart -ne 'No') { $res.RestartNeeded = $true; $res.RestartReasons += ("{0}: {1}" -f $t.Restart, $t.Name) }
        } elseif ($item.Status -eq 'Failed') { $res.Failed++ } else { $res.Skipped++ }
        if ($Script:BackupSession) { $Script:BackupSession.Changes.Add([pscustomobject]@{ TweakId = $t.Id; Name = $t.Name; Risk = $t.Risk; Result = $item.Status; Before = $item.Before; After = $item.After }) }
    }
    $res.Items = @($items)
    $Script:Counters.Success += $res.Success; $Script:Counters.Failed += $res.Failed; $Script:Counters.Skipped += $res.Skipped
    if ($res.RestartNeeded) { $Script:RestartNeeded = $true; foreach ($r in $res.RestartReasons) { $Script:RestartReasons.Add($r) } }

    # 5. Finalise the backup (adds change list and any created power plan) and log
    & $say 'Finalizing the backup record...' 97
    if ($Script:BackupSession) {
        try {
            $Script:BackupSession.Applied = [pscustomobject]@{ Successful = $res.Success; Failed = $res.Failed; Skipped = $res.Skipped }
            Save-BackupSession
        } catch { Write-Tag WARN ('The backup could not be finalised: ' + $_.Exception.Message) }
    }
    if ($Script:SessionLogPath) { $res.LogFile = $Script:SessionLogPath }
    Clear-Busy
    return $res
}
# ---------------------------------------------------------------
# RESOURCE MONITOR (read-only; never terminates anything)
# ---------------------------------------------------------------

function Get-ResourceSnapshot {
    param([int]$SampleMs = 1000)
    $cores = [Environment]::ProcessorCount
    $t0 = Get-Date
    $cpu0 = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { if ($null -ne $p.CPU) { $cpu0[$p.Id] = [double]$p.CPU } }
    $net0 = @(Get-CimSafe -Class Win32_PerfRawData_Tcpip_NetworkInterface)
    $rx0 = ($net0 | Measure-Object -Property BytesReceivedPersec -Sum).Sum
    $tx0 = ($net0 | Measure-Object -Property BytesSentPersec -Sum).Sum
    Start-Sleep -Milliseconds $SampleMs
    $elapsed = ((Get-Date) - $t0).TotalSeconds
    $rows = @()
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $pct = 0
        if ($null -ne $p.CPU -and $cpu0.ContainsKey($p.Id) -and $elapsed -gt 0) {
            $pct = [math]::Round((([double]$p.CPU - $cpu0[$p.Id]) / $elapsed / $cores) * 100, 1)
            if ($pct -lt 0) { $pct = 0 }
        }
        $rows += [pscustomobject]@{ Name = $p.ProcessName; Id = $p.Id; CpuPct = $pct; RamMB = [math]::Round($p.WorkingSet64 / 1MB, 0) }
    }
    $net1 = @(Get-CimSafe -Class Win32_PerfRawData_Tcpip_NetworkInterface)
    $rx1 = ($net1 | Measure-Object -Property BytesReceivedPersec -Sum).Sum
    $tx1 = ($net1 | Measure-Object -Property BytesSentPersec -Sum).Sum
    $rxKb = 0
    $txKb = 0
    if ($elapsed -gt 0 -and $null -ne $rx0 -and $null -ne $rx1) { $rxKb = [math]::Round((($rx1 - $rx0) / 1KB) / $elapsed, 0); $txKb = [math]::Round((($tx1 - $tx0) / 1KB) / $elapsed, 0) }
    $disk = Get-CimSafe -Class Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
    $mem = Get-MemoryInfo
    $sto = Get-StorageInfo
    return [pscustomobject]@{
        CpuPct = (Get-CpuLoad); RamPct = $mem.UsedPct; RamUsedGB = $mem.UsedGB; RamTotalGB = $mem.TotalGB
        DiskBusyPct = $(if ($disk) { [int]$disk.PercentDiskTime } else { $null }); DiskFreeGB = $sto.FreeGB
        NetRxKBs = $rxKb; NetTxKBs = $txKb; Processes = @($rows); ProcessCount = $rows.Count
    }
}

# ---------------------------------------------------------------
# BENCHMARK (measured values only - nothing is estimated or invented)
# ---------------------------------------------------------------

function New-BenchSnapshot {
    param([string]$Label)
    $samples = @()
    for ($i = 0; $i -lt 5; $i++) {
        Write-Busy -Activity ('Benchmark: ' + $Label) -Status ('Sample {0} of 5' -f ($i + 1)) -Percent ($i * 20)
        $c = Get-CpuLoad
        if ($null -ne $c) { $samples += [double]$c }
        Start-Sleep -Seconds 1
    }
    Clear-Busy
    $mem = Get-MemoryInfo
    $sto = Get-StorageInfo
    $startup = @(Get-StartupItems | Where-Object { $_.Enabled }).Count
    return [pscustomobject]@{
        Label = $Label; Taken = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); ToolVersion = $Script:Version
        CpuAvgPct = $(if ($samples.Count -gt 0) { [math]::Round((($samples | Measure-Object -Average).Average), 1) } else { $null })
        RamUsedPct = $mem.UsedPct; RamUsedGB = $mem.UsedGB; StartupEnabled = $startup; DiskFreeGB = $sto.FreeGB
        ProcessCount = @(Get-Process).Count
    }
}

function Save-BenchSnapshot {
    param($Snapshot, [string]$Name)
    if ($Script:ReadOnlyRun) { return $null }
    if ($Name -notmatch '^[A-Za-z0-9_\-]+$') { throw 'Use only letters, digits, - and _ in the snapshot name.' }
    $path = Join-Path $Script:BenchDir ($Name + '.json')
    Write-JsonFile -Path $path -Object $Snapshot
    return $path
}

function Get-BenchSnapshots {
    if (-not (Test-Path -LiteralPath $Script:BenchDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $Script:BenchDir -Filter '*.json' -File | Sort-Object LastWriteTime -Descending)
}

function Compare-BenchSnapshots {
    param($Before, $After)
    $defs = @(
        @{ K = 'CpuAvgPct'; N = 'Idle CPU (avg of 5 samples)'; U = '%' },
        @{ K = 'RamUsedPct'; N = 'RAM used'; U = '%' },
        @{ K = 'RamUsedGB'; N = 'RAM used'; U = ' GB' },
        @{ K = 'StartupEnabled'; N = 'Enabled startup items'; U = '' },
        @{ K = 'DiskFreeGB'; N = 'System drive free space'; U = ' GB' },
        @{ K = 'ProcessCount'; N = 'Running processes'; U = '' }
    )
    $rows = @()
    foreach ($d in $defs) {
        $b = $Before.($d.K)
        $a = $After.($d.K)
        $chg = 'n/a'
        if ($null -ne $b -and $null -ne $a) { $v = [math]::Round(([double]$a - [double]$b), 1); $chg = ('{0:+0.#;-0.#;0}{1}' -f $v, $d.U) }
        $rows += [pscustomobject]@{ Metric = $d.N; Before = ("{0}{1}" -f $b, $d.U); After = ("{0}{1}" -f $a, $d.U); Change = $chg }
    }
    return @($rows)
}

# ---------------------------------------------------------------
# UPDATE CHECK (explicit; never replaces or runs anything by itself)
# ---------------------------------------------------------------

function Get-UpdateInfo {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { Write-Log -Level WARN -Action 'TLS' -ErrorText $_.Exception.Message }
    $u = [uri]$Script:UpdateManifestUrl
    if ($u.Scheme -ne 'https') { throw 'The update source must use HTTPS.' }
    $raw = Invoke-RestMethod -Uri $Script:UpdateManifestUrl -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    $m = $raw
    if ($raw -is [string]) { $m = ConvertFrom-Json -InputObject $raw }
    $latest = $null
    try { $latest = [version][string]$m.version } catch { throw 'The update manifest has no valid version.' }
    if ([string]$m.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'The update manifest has no valid SHA-256.' }
    $pu = [uri][string]$m.url
    if ($pu.Scheme -ne 'https' -or @('github.com', 'raw.githubusercontent.com', 'objects.githubusercontent.com') -notcontains $pu.Host) {
        throw "The download source '$($pu.Host)' is not on the allowed list."
    }
    $current = [version]$Script:Version
    return [pscustomobject]@{
        Current = $current.ToString(); Latest = $latest.ToString(); Newer = ($latest -gt $current)
        Notes = [string]$m.notes; Url = [string]$m.url; Sha256 = ([string]$m.sha256).ToUpper(); Source = $Script:UpdateManifestUrl
    }
}

function Save-UpdatePackage {
    # Downloads, verifies SHA-256, reports Authenticode status. It does NOT install or execute anything.
    param($Info)
    if (-not (Test-Path -LiteralPath $Script:UpdatesDir)) { New-Item -ItemType Directory -Path $Script:UpdatesDir -Force -ErrorAction Stop | Out-Null }
    $zip = Join-Path $Script:UpdatesDir ("DIVoptimizer-v{0}.zip" -f $Info.Latest)
    Invoke-WebRequest -Uri $Info.Url -OutFile $zip -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    $h = Get-Sha256 -Path $zip
    if ($h -ne $Info.Sha256) {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        throw "SHA-256 mismatch. Expected $($Info.Sha256) but the download is $h. The file was deleted."
    }
    $stage = Join-Path $Script:UpdatesDir ("v{0}" -f $Info.Latest)
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
    $sig = 'No DIVoptimizer.ps1 found in the package'
    $main = @(Get-ChildItem -LiteralPath $stage -Filter 'DIVoptimizer.ps1' -Recurse -File | Select-Object -First 1)
    if ($main.Count -gt 0) { $sig = [string](Get-AuthenticodeSignature -FilePath $main[0].FullName).Status }
    return [pscustomobject]@{ Zip = $zip; Folder = $stage; HashOk = $true; Signature = $sig }
}

# ---------------------------------------------------------------
# MAINTENANCE + NETWORK TOOLS
# ---------------------------------------------------------------

function Get-MaintenanceCommands {
    return @(
        @{ Key = '1'; Name = 'DISM CheckHealth'; Category = 'Diagnostics'; Exe = 'DISM.exe'; Args = @('/Online', '/Cleanup-Image', '/CheckHealth'); Note = 'Fast, read-only.'; Confirm = $false },
        @{ Key = '2'; Name = 'DISM ScanHealth'; Category = 'Diagnostics'; Exe = 'DISM.exe'; Args = @('/Online', '/Cleanup-Image', '/ScanHealth'); Note = 'Slower, read-only.'; Confirm = $false },
        @{ Key = '3'; Name = 'DISM RestoreHealth'; Category = 'Repair'; Exe = 'DISM.exe'; Args = @('/Online', '/Cleanup-Image', '/RestoreHealth'); Note = 'May download replacement files and take a long time.'; Confirm = $true },
        @{ Key = '4'; Name = 'SFC /scannow'; Category = 'Repair'; Exe = 'sfc.exe'; Args = @('/scannow'); Note = 'Checks and repairs protected system files; can take several minutes.'; Confirm = $true },
        @{ Key = '5'; Name = 'Component Store Cleanup'; Category = 'Cleanup'; Exe = 'DISM.exe'; Args = @('/Online', '/Cleanup-Image', '/StartComponentCleanup'); Note = 'Removes superseded component versions; recently installed updates can no longer be uninstalled afterwards.'; Confirm = $true }
    )
}

function Invoke-MaintenanceCommand {
    param($Cmd)
    if (-not (Test-Administrator)) { throw 'Windows maintenance tools require Administrator.' }
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would run $($Cmd.Name)"; return 0 }
    $a = @($Cmd.Args)
    Write-Log -Level INFO -Action 'MAINTENANCE' -Target $Cmd.Name -Result 'STARTED'
    & $Cmd.Exe @a
    $code = $LASTEXITCODE
    Write-Log -Level $(if ($code -eq 0) { 'INFO' } else { 'WARN' }) -Action 'MAINTENANCE' -Target $Cmd.Name -Result ("exit code {0}" -f $code)
    return $code
}

function Get-LaptopWarnings {
    param($Scan, [string]$Operation)
    $w = @()
    if (-not $Scan) { return @() }
    if ($Scan.Hardware.BatteryPresent) {
        if ($Scan.Power.AcConnected -eq $false) { $w += "This laptop is running on battery ($($Scan.Power.BatteryPercent)%). Connect AC power before: $Operation." }
        if ($null -ne $Scan.Power.ThermalC -and $Scan.Power.ThermalC -ge 85) { $w += "The reported temperature is already high ($($Scan.Power.ThermalC) C). Let the laptop cool first." }
    }
    return @($w)
}

function Test-HostName {
    param([string]$Name)
    return ($Name -match '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,251}[A-Za-z0-9])?$' -or $Name -match '^[0-9a-fA-F:]+$')
}

function Invoke-NetworkTool {
    # Category: Diagnostics (read-only) | Repair | Reset. Reset/Repair can briefly interrupt connectivity.
    param([ValidateSet('FlushDns', 'ResetWinsock', 'ResetTcpIp')][string]$Tool)
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would run $Tool"; return $true }
    switch ($Tool) {
        'FlushDns' { $out = & ipconfig.exe /flushdns 2>&1 }
        'ResetWinsock' { if (-not (Test-Administrator)) { throw 'Requires Administrator.' }; $out = & netsh.exe winsock reset 2>&1 }
        'ResetTcpIp' { if (-not (Test-Administrator)) { throw 'Requires Administrator.' }; $out = & netsh.exe int ip reset 2>&1 }
    }
    $code = $LASTEXITCODE
    Write-Log -Level $(if ($code -eq 0) { 'INFO' } else { 'FAIL' }) -Action 'NETWORK_TOOL' -Target $Tool -Result ("exit code {0}" -f $code) -Message (($out | Out-String).Trim())
    if ($code -ne 0) { throw ("{0} failed (exit {1}): {2}" -f $Tool, $code, (($out | Out-String).Trim())) }
    if ($Tool -ne 'FlushDns') { $Script:RestartNeeded = $true; $Script:RestartReasons.Add("Network reset: $Tool") }
    return $true
}

# ---------------------------------------------------------------
# ELEVATION  (start normally; ask for Administrator only when a change needs it)
# ---------------------------------------------------------------

function Test-AllowedScriptUrl {
    # HTTPS and GitHub hosts only.
    param([string]$Url)
    try { $u = [uri]$Url } catch { return $false }
    return ($u.Scheme -eq 'https' -and @('raw.githubusercontent.com', 'github.com') -contains $u.Host)
}

function Get-SelfUrl {
    $o = $env:DIVOPTIMIZER_URL
    if ($o -and (Test-AllowedScriptUrl -Url $o)) { return $o }
    return $Script:SelfUrl
}

function ConvertTo-SafeIdList {
    # Only plain identifiers may be placed into a relaunch command line.
    param([string[]]$Ids)
    $ok = @($Ids | Where-Object { $_ -match '^[A-Za-z0-9_\-]+$' })
    return ($ok -join ',')
}

function Get-RelaunchModeArgs {
    # Switches that make the elevated copy start in the same mode. An empty result means the GUI.
    param([bool]$IsConsole, [bool]$IsQuick, [string]$ProfileId = '', [bool]$IsUndo = $false)
    $a = @()
    if ($IsUndo) { $a += '-Undo' }
    elseif ($IsQuick) { $a += '-Quick' }
    elseif ($ProfileId -and $Script:Profiles.Contains($ProfileId)) { $a += '-ProfileName'; $a += $ProfileId }
    elseif ($IsConsole) { $a += '-Console' }
    return $a
}

function Request-Elevation {
    param([string]$Why, [string[]]$Ids = @(), [switch]$Silent, [string[]]$ModeArgs = $null)
    Write-Tag INFO "Administrator is needed because: $Why"
    if (-not $Silent) {
        if (-not (Read-YesNo -Prompt 'Relaunch DIVoptimizer as Administrator now? (Windows will show a UAC prompt)' -DefaultYes)) { return $false }
    }
    $hostExe = (Get-Process -Id $PID).Path
    $safeIds = ConvertTo-SafeIdList -Ids $Ids
    $mode = @()
    if ($PSBoundParameters.ContainsKey('ModeArgs')) { $mode = @($ModeArgs) } elseif (-not $Script:IsGui) { $mode = @('-Console') }
    foreach ($m in $mode) {
        if ($m -notmatch '^-?[A-Za-z0-9]+$') { Write-Tag FAIL 'An unsafe relaunch argument was rejected.'; return $false }
    }
    $a = @()
    if ($PSCommandPath) {
        # Started from a saved file: re-run that same file.
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
        $a += $mode
        if ($safeIds) { $a += '-Preselect'; $a += ('"' + $safeIds + '"') }
    } else {
        # Started with irm | iex: re-run the same one-liner from the fixed HTTPS URL.
        $url = Get-SelfUrl
        if (-not (Test-AllowedScriptUrl -Url $url)) { Write-Tag FAIL 'The script URL is not an allowed HTTPS GitHub address, so it will not be run elevated.'; return $false }
        $inner = "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((Invoke-RestMethod -Uri '$url' -UseBasicParsing)))"
        if (@($mode).Count -gt 0) { $inner += (' ' + ($mode -join ' ')) }
        if ($safeIds) { $inner += " -Preselect '$safeIds'" }
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
        $a += '-Command'
        $a += ('"' + $inner + '"')
    }
    try {
        Start-Process -FilePath $hostExe -ArgumentList $a -Verb RunAs -ErrorAction Stop
        Write-Log -Level INFO -Action 'ELEVATE' -Message ($Why + $(if ($PSCommandPath) { ' (file)' } else { ' (remote one-liner)' }))
        return $true
    } catch {
        Write-Tag FAIL "Elevation was cancelled or failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-ElevationUserMismatch {
    try {
        $signedIn = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ($signedIn -and ($signedIn -ne $me)) { return "Running as $me but signed in as $signedIn. Per-user (HKCU) settings and backups apply to $me." }
    } catch { Write-Log -Level WARN -Action 'USER_CHECK' -ErrorText $_.Exception.Message }
    return $null
}

# ---------------------------------------------------------------
# LOG / HISTORY READERS
# ---------------------------------------------------------------

function Get-LogFiles {
    if (-not (Test-Path -LiteralPath $Script:LogsDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $Script:LogsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.jsonl', '.log') } | Sort-Object Name -Descending)
}

function Read-LogFile {
    param([string]$Path)
    $out = @()
    foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        if ($Path -like '*.jsonl') {
            try { $out += (Format-LogEntry -Entry (ConvertFrom-Json -InputObject $line)) } catch { $out += $line }
        } else { $out += $line }
    }
    return @($out)
}

function Get-ChangeHistory {
    return @(Get-BackupList | Where-Object { $_.Format -eq 'v2' })
}

# ---------------------------------------------------------------
# NAMES FROM THE PROJECT SPECIFICATION (thin wrappers over the implementation above)
# ---------------------------------------------------------------

function Get-SystemInfo { return (Get-SystemScan) }

function Restore-Service { param($Record) return (Restore-ServiceRecord -Record $Record) }

function Restore-ScheduledTask { param($Record) return (Restore-TaskRecord -Record $Record) }

function Restore-PowerPlan { param($Record) return (Restore-PowerPlanRecord -Record $Record) }

function Test-Compatibility { param($Tweak, $Windows) return (Test-TweakCompat -Tweak $Tweak -Windows $Windows) }

function Show-Recommendations {
    param([object[]]$Recommendations)
    $i = 0
    foreach ($r in @($Recommendations)) { $i++; Show-RecRow -Rec $r -Index $i -Selected ([bool]$r.DefaultSelected) }
}

function Apply-Recommendation {
    # Applies one or more recommendation rows through the full PRECHECK -> BACKUP -> CHANGE -> VERIFY engine.
    param([object[]]$Recommendation, [string]$Description = 'Recommendation', [switch]$AdvancedConfirmed, [scriptblock]$Prompt)
    $tweaks = @($Recommendation | ForEach-Object { $_.Tweak })
    return (Invoke-ApplyPlan -Tweaks $tweaks -Description $Description -AdvancedConfirmed:$AdvancedConfirmed -Prompt $Prompt)
}
# ---------------------------------------------------------------
# CONSOLE: shared building blocks
# ---------------------------------------------------------------

function ConvertTo-RecFromTweak {
    # Wraps an ad-hoc tweak (startup item, app, service, cleanup...) in the same shape Get-Recommendations returns.
    param($Tweak)
    $cur = ''
    $new = ''
    try { $cur = Get-TweakCurrent -Tweak $Tweak; $new = Get-TweakNew -Tweak $Tweak } catch { Write-Log -Level WARN -Action 'TWEAK_STATE' -Target $Tweak.Id -ErrorText $_.Exception.Message }
    $compat = Test-TweakCompat -Tweak $Tweak -Windows $Script:LastScan.Windows
    return [pscustomobject]@{
        Tweak = $Tweak; Id = $Tweak.Id; Name = $Tweak.Name; Category = $Tweak.Category; Risk = $Tweak.Risk; Kind = $Tweak.Kind
        Current = $cur; New = $new; Why = $Tweak.Reason; Reason = $Tweak.Reason; Downside = $Tweak.Downside; Restart = $Tweak.Restart
        Rollback = $Tweak.Rollback; RollbackNote = $Tweak.RollbackNote; Recommended = $false; Compatible = $compat.Ok; CompatMessage = $compat.Message
        Blocked = $null; Applied = $false; Selectable = $compat.Ok; DefaultSelected = $false
    }
}

function New-CleanupTweak {
    param($Target)
    $risk = 'LOW RISK'
    if (@('RecycleBin', 'WindowsUpdate', 'DeliveryOpt') -contains $Target.Key) { $risk = 'OPTIONAL' }
    return (New-Tweak @{
        Id = ('clean-' + $Target.Key.ToLower()); Name = ('Clean ' + $Target.Name); Category = 'Cleanup'; Risk = $risk; Kind = 'Cleanup'
        CleanupTarget = $Target.Key; NeedsAdmin = [bool]$Target.Admin
        Reason = 'Recovers disk space / removes temporary or stale cache data.'
        Downside = $Target.Note; Rollback = 'None'; RollbackNote = 'Deleted files cannot be restored.'
    })
}

function New-PowerPlanTweak {
    param([string]$Key)
    $risk = if ($Key -eq 'Maximum') { 'ADVANCED' } else { 'OPTIONAL' }
    $down = 'Results vary; Balanced is the Windows default.'
    if ($Key -ne 'Balanced') { $down = 'May increase power consumption. May increase heat and fan noise. May reduce battery life on laptops. Does not automatically improve FPS.' }
    return (New-Tweak @{
        Id = ('power-' + $Key.ToLower()); Name = ('Power plan: ' + $Script:PlanLabels[$Key]); Category = 'Power'; Risk = $risk; Kind = 'PowerPlan'; PlanKey = $Key
        Reason = 'You chose this power plan.'; Downside = $down
    })
}

function Show-RecRow {
    param($Rec, [int]$Index, [bool]$Selected)
    $mark = '[ ]'
    if (-not $Rec.Selectable) { $mark = ' - ' } elseif ($Selected) { $mark = '[x]' }
    Write-Host ('  {0,3} {1} ' -f $Index, $mark) -NoNewline
    Write-Risk $Rec.Risk
    Write-Host (' ' + $Rec.Name)
    if (-not $Rec.Compatible) { Write-Host ('          ' + $Rec.CompatMessage) -ForegroundColor DarkYellow }
    elseif ($Rec.Blocked) { Write-Host ('          Not offered: ' + $Rec.Blocked) -ForegroundColor DarkYellow }
    elseif ($Rec.Applied) { Write-Host '          Already set.' -ForegroundColor DarkGray }
    else { Write-Host ('          {0}  ->  {1}' -f $Rec.Current, $Rec.New) -ForegroundColor DarkGray }
}

function Show-RecDetails {
    param($R)
    Write-Host ''
    Write-Host ('  ' + $R.Name) -ForegroundColor White
    Write-KV 'Category' $R.Category
    Write-Host '   ' -NoNewline; Write-Host ('{0,-18}' -f 'Risk') -ForegroundColor DarkGray -NoNewline; Write-Risk $R.Risk; Write-Host ''
    Write-KV 'Current' $R.Current
    Write-KV 'New' $R.New
    Write-KV 'Why' $R.Why
    Write-KV 'Potential downside' $R.Downside
    Write-KV 'Restart required' $R.Restart
    $rb = $R.Rollback
    if ($R.Rollback -eq 'None') { $rb = 'NOT reversible automatically. ' + $R.RollbackNote } elseif ($R.Rollback -eq 'Full') { $rb = 'Available' }
    Write-KV 'Rollback' $rb
}

function Read-TweakSelection {
    # Interactive checklist. Returns the selected rec rows, or $null if the user went back.
    param([object[]]$Recs, [string]$Title, [string[]]$PreselectIds = @())
    $ordered = @()
    foreach ($risk in @('LOW RISK', 'OPTIONAL', 'ADVANCED')) { $ordered += @($Recs | Where-Object { $_.Risk -eq $risk }) }
    $ordered += @($Recs | Where-Object { @('LOW RISK', 'OPTIONAL', 'ADVANCED') -notcontains $_.Risk })
    $Recs = @($ordered)
    $sel = @{}
    foreach ($r in $Recs) { if ($r.DefaultSelected) { $sel[$r.Id] = $true } }
    foreach ($id in $PreselectIds) { $m = @($Recs | Where-Object { $_.Id -eq $id -and $_.Selectable }); if ($m.Count -gt 0) { $sel[$id] = $true } }
    while ($true) {
        Clear-Host
        Show-Header $Title
        for ($i = 0; $i -lt $Recs.Count; $i++) {
            $r = $Recs[$i]
            Show-RecRow -Rec $r -Index ($i + 1) -Selected ([bool]$sel[$r.Id])
        }
        Write-Host ''
        Write-Host '   Numbers (e.g. 1,3) toggle  |  L = all LOW RISK  |  N = none  |  D <n> = details' -ForegroundColor DarkGray
        Write-Host '   A = apply selected  |  B = back.   ADVANCED items are never selected automatically.' -ForegroundColor DarkGray
        $c = (Read-Host '   Choice').Trim()
        if ($c -match '^[Bb]$') { return $null }
        if ($c -match '^[Nn]$') { $sel = @{}; continue }
        if ($c -match '^[Ll]$') { foreach ($r in $Recs) { if ($r.Selectable -and $r.Risk -eq 'LOW RISK' -and $r.Kind -ne 'Info') { $sel[$r.Id] = $true } }; continue }
        if ($c -match '^[Dd]\s*(\d+)$') {
            $n = [int]$Matches[1]
            if ($n -ge 1 -and $n -le $Recs.Count) { Show-RecDetails -R $Recs[$n - 1]; Wait-Enter }
            continue
        }
        if ($c -match '^[Aa]$') {
            $chosen = @($Recs | Where-Object { $sel[$_.Id] -and $_.Selectable -and $_.Kind -ne 'Info' })
            if ($chosen.Count -eq 0) { Write-Tag INFO 'Nothing selected.'; Start-Sleep -Seconds 1; continue }
            return $chosen
        }
        foreach ($tok in ($c -split '[,\s]+')) {
            if ($tok -match '^\d+$') {
                $n = [int]$tok
                if ($n -ge 1 -and $n -le $Recs.Count) {
                    $r = $Recs[$n - 1]
                    if ($r.Kind -eq 'Info') { Write-Tag INFO 'Use the Startup Manager (main menu) to review startup apps.'; Start-Sleep -Seconds 1 }
                    elseif ($r.Selectable) { if ($sel[$r.Id]) { $sel.Remove($r.Id) } else { $sel[$r.Id] = $true } }
                    else { Write-Tag SKIP 'That item cannot be selected on this PC.'; Start-Sleep -Seconds 1 }
                }
            }
        }
    }
}

function Show-ApplyResult {
    param($Res)
    Write-Host ''
    if ($Res.Aborted) {
        Write-Section 'Cancelled'
        Write-Host ('   ' + $Res.AbortReason) -ForegroundColor Yellow
        Write-Host '   No settings were changed.' -ForegroundColor DarkGray
        return
    }
    $title = 'OPTIMIZATION COMPLETE'
    $color = 'Green'
    if ($Res.Failed -gt 0) { $title = 'COMPLETED WITH WARNINGS'; $color = 'Yellow' }
    Write-Section $title
    Write-KV 'Successful' $Res.Success 'Green'
    Write-KV 'Failed' $Res.Failed $(if ($Res.Failed -gt 0) { 'Red' } else { 'Gray' })
    Write-KV 'Skipped' $Res.Skipped 'Yellow'
    Write-Host ''
    foreach ($i in @($Res.Items)) {
        $tag = switch ($i.Status) { 'Success' { 'OK' } 'Failed' { 'FAIL' } default { 'SKIP' } }
        $line = $i.Name
        if ($i.Status -eq 'Success' -and $i.Before -ne $i.After -and $i.After) { $line += ("   [{0} -> {1}]" -f $i.Before, $i.After) }
        if ($i.Message) { $line += ('   ' + $i.Message) }
        Write-Host ('   [{0}] ' -f $tag) -ForegroundColor $(switch ($tag) { 'OK' { 'Green' } 'FAIL' { 'Red' } default { 'DarkYellow' } }) -NoNewline
        Write-Host $line
    }
    Write-Host ''
    Write-KV 'Backup' $(if ($Res.BackupId) { $Res.BackupId + $(if ($Res.BackupOk) { '' } else { '  (INCOMPLETE)' }) } else { 'none' })
    Write-KV 'System Restore' $(if ($Res.RestorePoint.Message) { "$($Res.RestorePoint.Status): $($Res.RestorePoint.Message)" } else { $Res.RestorePoint.Status })
    Write-KV 'Restart required' $(if ($Res.RestartNeeded) { 'YES' } else { 'NO' }) $(if ($Res.RestartNeeded) { 'Yellow' } else { 'Gray' })
    foreach ($r in @($Res.RestartReasons)) { Write-Host ('      - ' + $r) -ForegroundColor DarkGray }
    if ($Res.LogFile) { Write-KV 'Log' $Res.LogFile }
    if ($Res.Failed -gt 0) { Write-Host '   Failed changes were rolled back where possible. See the log for details.' -ForegroundColor Yellow }
}

function Invoke-RetentionPrompt {
    $over = @(Get-BackupsOverRetention)
    if ($over.Count -eq 0) { return }
    Write-Section 'Backup retention'
    Write-Host '   Your retention setting keeps fewer backups than currently exist. These would be deleted:' -ForegroundColor Yellow
    foreach ($b in $over) { Write-Host ('   {0}   {1}   {2}' -f $b.Id, $b.Created, (Format-Bytes $b.SizeBytes)) }
    if (Read-YesNo -Prompt 'Delete these backups?') {
        foreach ($b in $over) { try { Remove-BackupFolder -Dir $b.Path; Write-Tag OK "Deleted backup $($b.Id)" } catch { Write-Tag FAIL "Could not delete $($b.Id): $($_.Exception.Message)" } }
    } else { Write-Tag INFO 'No backups were deleted.' }
}

function Invoke-ReviewAndApply {
    param([object[]]$Recs, [string]$Description = 'Optimization', [string]$ProfileName = '')
    $Recs = @($Recs)
    $tweaks = @($Recs | ForEach-Object { $_.Tweak })
    if ($tweaks.Count -eq 0) { Write-Tag INFO 'Nothing selected.'; return $null }
    Clear-Host
    Show-Header 'REVIEW CHANGES'
    Write-Host ("   {0} change(s) selected" -f $tweaks.Count) -ForegroundColor White
    foreach ($risk in @('LOW RISK', 'OPTIONAL', 'ADVANCED')) {
        foreach ($r in @($Recs | Where-Object { $_.Risk -eq $risk })) {
            Write-Host ''
            Write-Host '   ' -NoNewline; Write-Risk $risk; Write-Host (' ' + $r.Name)
            Write-Host ('        {0}  ->  {1}' -f $r.Current, $r.New)
            Write-Host ('        Downside: ' + $r.Downside) -ForegroundColor DarkGray
            if ($r.Restart -ne 'No') { Write-Host ('        Restart required: ' + $r.Restart) -ForegroundColor Yellow }
            if ($r.Rollback -eq 'None') { Write-Host ('        NOT reversible automatically. ' + $r.RollbackNote) -ForegroundColor Yellow }
        }
    }
    $ready = Get-ApplyReadiness -Tweaks $tweaks
    Write-Section 'Safety checks'
    Write-KV 'Backup' $(if ($ready.BackupReady) { 'READY' } else { 'NOT READY: ' + $ready.BackupProblem }) $(if ($ready.BackupReady) { 'Green' } else { 'Red' })
    Write-KV 'System Restore' $ready.RestorePointText $(if ($ready.IsAdmin) { 'Green' } else { 'Yellow' })
    foreach ($c in @($ready.Coverage | Where-Object { $_.Needed })) { Write-Host ('      [x] {0} will be backed up' -f $c.Name) -ForegroundColor DarkGray }
    foreach ($n in @($ready.NotReversible)) { Write-Host ('      [!] Not reversible automatically: ' + $n) -ForegroundColor Yellow }
    foreach ($t in $tweaks) {
        if ($t.Kind -eq 'PowerPlan' -and $t.PlanKey -ne 'Balanced' -and $Script:LastScan.Hardware.DeviceType -eq 'Laptop') {
            Write-Host '      [!] Laptop: this plan may increase power consumption, heat and fan noise and reduce battery life.' -ForegroundColor Yellow
            foreach ($w in @(Get-LaptopWarnings -Scan $Script:LastScan -Operation 'changing the power plan')) { Write-Host ('      [!] ' + $w) -ForegroundColor Yellow }
        }
    }
    Write-Host ''
    if ($ready.NeedsElevation) {
        Write-Tag WARN 'Some of these changes modify system-wide settings and need Administrator.'
        $ids = @($tweaks | ForEach-Object { $_.Id })
        if (Request-Elevation -Why 'system-wide settings (HKLM, services, scheduled tasks or restore points) can only be changed by an Administrator' -Ids $ids) { Write-Host '   A new elevated window was opened. You can close this one.'; $Script:QuitRequested = $true; Wait-Enter; return $null }
        return $null
    }
    if (-not $ready.BackupReady) { Write-Tag FAIL 'The backup folder is not writable, so changes cannot be applied safely.'; return $null }
    $go = $false
    if ($ready.HasAdvanced) {
        Write-Host '   This selection includes ADVANCED changes that may affect Windows functionality.' -ForegroundColor Red
        $a = Read-Host '   Type YES (capitals) to apply, anything else to cancel'
        $go = ($a -ceq 'YES')
    } else {
        $go = Read-YesNo -Prompt 'Apply these changes?'
    }
    if (-not $go) { Write-Tag INFO 'Cancelled. Nothing was changed.'; return $null }
    $prompt = { param($m, $adv) Write-Host ''; Write-Tag WARN ($m -replace "`n", ' '); return (Read-YesNo -Prompt 'Continue?') }
    $res = Invoke-ApplyPlan -Tweaks $tweaks -Description $Description -ProfileName $ProfileName -AdvancedConfirmed:$ready.HasAdvanced -Prompt $prompt
    Show-ApplyResult -Res $res
    if (-not $res.Aborted) { Invoke-RetentionPrompt }
    if ($res.RestartNeeded -and -not $res.Aborted) { if (Read-YesNo -Prompt 'Restart now?') { Restart-Computer -Confirm:$false } }
    return $res
}

# ---------------------------------------------------------------
# CONSOLE PAGES
# ---------------------------------------------------------------

function Show-SystemSummary {
    param($Scan)
    $h = $Scan.Hardware
    Write-Section 'System'
    Write-KV 'Windows' ("{0}  (build {1}, {2})" -f $Scan.Windows.Caption, $Scan.Windows.Build, $Scan.Windows.Architecture)
    Write-KV 'Device' ("{0}  |  {1}" -f $h.DeviceType, $(if ($h.Touch) { 'touchscreen' } else { 'no touchscreen detected' }))
    Write-KV 'CPU' ("{0}  ({1}C/{2}T)" -f $h.Cpu, $h.Cores, $h.LogicalProcessors)
    Write-KV 'Memory' ("{0} GB" -f $h.RamGB)
    Write-KV 'Graphics' $(if (@($h.Gpus).Count -gt 0) { $h.Gpus[0].Name } else { 'Unknown' })
    Write-KV 'System drive' ("{0}  |  {1}  |  {2} GB free" -f $Scan.Storage.Drive, $h.SystemDriveType, $Scan.Storage.FreeGB)
    Write-KV 'Power plan' $Scan.Power.PlanName
    if ($Scan.Windows.Status -ne 'Supported') { Write-KV 'Support' $Scan.Windows.Status 'Yellow' }
    Write-KV 'Administrator' $(if ($Scan.IsAdmin) { 'YES' } else { 'NO (requested only when a change needs it)' }) $(if ($Scan.IsAdmin) { 'Green' } else { 'DarkYellow' })
}

function Invoke-ScanPage {
    Clear-Host
    Show-Header 'SCAN SYSTEM (read-only, changes nothing)'
    Write-Host '   Scanning...' -ForegroundColor DarkGray
    $scan = Get-SystemScan
    Show-ScanReport -Scan $scan
    Wait-Enter
}

function Invoke-RecommendationsPage {
    param([string]$ProfileName = '')
    Clear-Host
    Write-Host '   Analysing your PC...' -ForegroundColor DarkGray
    $scan = Get-SystemScan
    $recs = @(Get-Recommendations -Scan $scan -ProfileName $ProfileName)
    if ($recs.Count -eq 0) { Write-Tag INFO 'No recommendations for this PC right now. Nothing needs changing.'; Wait-Enter; return }
    $title = 'RECOMMENDATIONS'
    if ($ProfileName) { $title = "$($ProfileName.ToUpper()) PROFILE" }
    $pre = @()
    if ($Script:PreselectIds) { $pre = @($Script:PreselectIds) }
    $chosen = Read-TweakSelection -Recs $recs -Title $title -PreselectIds $pre
    $Script:PreselectIds = @()
    if ($chosen) { [void](Invoke-ReviewAndApply -Recs $chosen -Description $(if ($ProfileName) { "$ProfileName Profile" } else { 'Recommendations' }) -ProfileName $ProfileName); Wait-Enter }
}

function Invoke-QuickOptimize {
    Clear-Host
    Show-Header 'QUICK OPTIMIZE (LOW RISK only)'
    Write-Host '   Applies only LOW RISK recommendations for this PC. Never advanced changes.' -ForegroundColor DarkGray
    Write-Host '   Before applying: preview  ->  System Restore point  ->  backup  ->  verification.' -ForegroundColor DarkGray
    $scan = Get-SystemScan
    $set = @(Get-QuickOptimizeSet -Scan $scan)
    if ($set.Count -eq 0) { Write-Tag INFO 'Nothing LOW RISK needs changing on this PC.'; Wait-Enter; return }
    [void](Invoke-ReviewAndApply -Recs $set -Description 'Quick Optimize')
    Wait-Enter
}

function Invoke-ProfilesMenu {
    while ($true) {
        Clear-Host
        Show-Header 'PROFILES'
        $suggest = 'Desktop'
        if ($Script:LastScan) {
            if ($Script:LastScan.Hardware.DeviceType -eq 'Laptop') { $suggest = 'Laptop' }
            elseif ($Script:LastScan.Hardware.RamGB -le 8) { $suggest = 'LowResource' }
        }
        $i = 0
        $keys = @($Script:Profiles.Keys)
        foreach ($k in $keys) { $i++; Write-Menu "$i" ("{0} Profile" -f $k) $(if ($k -eq $suggest) { '(suggested for this PC)  ' + $Script:Profiles[$k] } else { $Script:Profiles[$k] }) }
        Write-Menu 'B' 'Back'
        $c = Read-Host '   Choice'
        if ($c -match '^[Bb]$') { return }
        if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $keys.Count) { Invoke-RecommendationsPage -ProfileName $keys[[int]$c - 1] }
    }
}

function Invoke-CategoryPage {
    param([string]$Title, [string[]]$Categories)
    Clear-Host
    Write-Host '   Reading current settings...' -ForegroundColor DarkGray
    $scan = Get-SystemScan
    $recs = @(Get-Recommendations -Scan $scan -All | Where-Object { $Categories -contains $_.Category -and $_.Risk -ne 'ADVANCED' })
    if ($recs.Count -eq 0) { Write-Tag INFO 'Nothing available in this category.'; Wait-Enter; return }
    $chosen = Read-TweakSelection -Recs $recs -Title $Title
    if ($chosen) { [void](Invoke-ReviewAndApply -Recs $chosen -Description $Title); Wait-Enter }
}

function Invoke-OptionalAppsPage {
    Clear-Host
    Show-Header 'OPTIONAL APPS (you choose what to remove)'
    Write-Host '   Removing an app is NOT automatically reversible. It may need to be reinstalled from' -ForegroundColor Yellow
    Write-Host '   Microsoft Store or another official source. Exact package names only; system components are protected.' -ForegroundColor Yellow
    Write-Host ''
    $installed = @{}
    foreach ($p in @(Get-AppxPackage -ErrorAction SilentlyContinue)) { $installed[[string]$p.Name] = $true }
    $recs = @()
    foreach ($e in @($Script:AppCatalog)) {
        if (-not $installed.ContainsKey([string]$e.Package)) { continue }
        if (Test-PackageProtected -Name $e.Package) { continue }
        $recs += (ConvertTo-RecFromTweak -Tweak (New-AppTweak -Entry $e))
    }
    if ($recs.Count -eq 0) { Write-Tag INFO 'None of the catalog apps are installed for this user.'; Wait-Enter; return }
    foreach ($r in $recs) { $r.DefaultSelected = $false }
    $chosen = Read-TweakSelection -Recs $recs -Title 'OPTIONAL APPS'
    if ($chosen) { [void](Invoke-ReviewAndApply -Recs $chosen -Description 'Optional Apps'); Wait-Enter }
}

function Invoke-StartupPage {
    $includeTasks = $false
    while ($true) {
        Clear-Host
        Show-Header 'STARTUP MANAGER'
        $items = @(Get-StartupItems -IncludeTasks:$includeTasks)
        if ($items.Count -eq 0) { Write-Tag INFO 'No startup items found.'; Wait-Enter; return }
        $i = 0
        foreach ($it in $items) {
            $i++
            Write-Host ('  {0,3}  ' -f $i) -NoNewline
            Write-Host ('{0,-9}' -f $(if ($it.Enabled) { 'Enabled' } else { 'Disabled' })) -ForegroundColor $(if ($it.Enabled) { 'Green' } else { 'DarkGray' }) -NoNewline
            Write-Host $it.Name
            $imp = 'not measured (not running now)'
            if ($null -ne $it.RunningMB) { $imp = "running now, using about $($it.RunningMB) MB RAM" }
            Write-Host ('         {0}   |   {1}' -f $it.Source, $imp) -ForegroundColor DarkGray
            Write-Host ('         ' + $it.Command) -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '   D <n,n>  disable   |   E <n,n>  enable   |   O <n>  open location   |   T  toggle scheduled tasks list   |   B  back' -ForegroundColor DarkGray
        Write-Host '   Entries are never deleted; only their enabled flag changes.' -ForegroundColor DarkGray
        $c = (Read-Host '   Choice').Trim()
        if ($c -match '^[Bb]$') { return }
        if ($c -match '^[Tt]$') { $includeTasks = -not $includeTasks; continue }
        if ($c -match '^[Oo]\s*(\d+)$') {
            $n = [int]$Matches[1]
            if ($n -ge 1 -and $n -le $items.Count) {
                $it = $items[$n - 1]
                if ($it.Kind -eq 'Folder' -and (Test-Path -LiteralPath $it.Command)) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $it.Command + '"') }
                else { Write-Host ('   Command: ' + $it.Command) }
                Wait-Enter
            }
            continue
        }
        if ($c -match '^([DdEe])\s*([\d,\s]+)$') {
            $verbKey = [string]$Matches[1]
            $numList = [string]$Matches[2]
            $enable = ($verbKey -match '^[Ee]$')
            $recs = @()
            foreach ($tok in ($numList -split '[,\s]+')) {
                if ($tok -match '^\d+$' -and [int]$tok -ge 1 -and [int]$tok -le $items.Count) {
                    $it = $items[[int]$tok - 1]
                    $recs += (ConvertTo-RecFromTweak -Tweak (New-StartupTweak -Item $it -Enable $enable))
                }
            }
            if ($recs.Count -gt 0) { [void](Invoke-ReviewAndApply -Recs $recs -Description 'Startup Manager'); Wait-Enter }
        }
    }
}

function Invoke-CleanupPage {
    Clear-Host
    Show-Header 'CLEANUP (recover disk space - not an optimization)'
    Write-Host '   Estimating sizes (this can take a moment)...' -ForegroundColor DarkGray
    $targets = @(Get-CleanupTargets)
    $recs = @()
    $i = 0
    foreach ($t in $targets) {
        $i++
        Write-Busy -Activity 'Estimating cleanup sizes' -Status $t.Name -Percent ([int](100 * ($i - 1) / $targets.Count))
        $est = Get-CleanupEstimate -Target $t -DetectLocked
        $line = '{0,-30} {1,10}   {2:N0} files' -f $t.Name, (Format-Bytes $est.Bytes), $est.Files
        if ($est.Locked -gt 0) { $line += ('   {0} currently locked{1}' -f $est.Locked, $(if ($est.LockedSampled) { ' (sampled)' } else { '' })) }
        if ($t.Admin -and -not (Test-Administrator)) { $line += '   (needs Administrator)' }
        Write-Host ('  {0,3}  {1}' -f $i, $line)
        $rec = ConvertTo-RecFromTweak -Tweak (New-CleanupTweak -Target $t)
        $rec.Current = ('{0}, {1:N0} files' -f (Format-Bytes $est.Bytes), $est.Files)
        $recs += $rec
    }
    Clear-Busy
    Write-Host ''
    Write-Host '   Cleanup removes files; it does not make games faster. Deleted files cannot be restored.' -ForegroundColor DarkGray
    $chosen = Read-TweakSelection -Recs $recs -Title 'CLEANUP'
    if ($chosen) { [void](Invoke-ReviewAndApply -Recs $chosen -Description 'Cleanup'); Wait-Enter }
}

function Invoke-NetworkPage {
    while ($true) {
        Clear-Host
        Show-Header 'NETWORK TOOLS (diagnostics and repair - not optimization)'
        Write-Section 'Diagnostics (read-only)'
        Write-Menu '1' 'Show IP configuration'
        Write-Menu '2' 'DNS server information'
        Write-Menu '3' 'Ping test'
        Write-Menu '4' 'Network adapters'
        Write-Section 'Repair'
        Write-Menu '5' 'Flush DNS cache' '(brief, harmless)'
        Write-Section 'Reset (can interrupt connectivity; restart required; not reversible)'
        Write-Menu '6' 'Reset Winsock'
        Write-Menu '7' 'Reset TCP/IP stack'
        Write-Menu 'B' 'Back'
        $c = Read-Host '   Choice'
        try {
            switch ($c) {
                '1' { Get-NetIPConfiguration | Format-List | Out-Host }
                '2' { Get-DnsClientServerAddress | Format-Table -AutoSize | Out-Host }
                '3' {
                    $h = (Read-Host '   Host to ping (for example 1.1.1.1)').Trim()
                    if (Test-HostName -Name $h) { Test-Connection -ComputerName $h -Count 4 | Out-Host } else { Write-Tag WARN 'That does not look like a valid host name or address.' }
                }
                '4' { Get-NetAdapter | Format-Table -AutoSize | Out-Host }
                '5' { [void](Invoke-NetworkTool -Tool FlushDns); Write-Tag OK 'DNS cache flushed' }
                '6' {
                    Write-Tag WARN 'Resets the Winsock catalog. Network connectivity may be interrupted and a restart is required. Not reversible automatically.'
                    if (Read-YesNo -Prompt 'Continue?') { [void](Invoke-NetworkTool -Tool ResetWinsock); Write-Tag OK 'Winsock reset. Restart required.' }
                }
                '7' {
                    Write-Tag WARN 'Resets TCP/IP settings (static IP/DNS settings may be lost). Connectivity may be interrupted and a restart is required. Not reversible automatically.'
                    if (Read-YesNo -Prompt 'Continue?') { [void](Invoke-NetworkTool -Tool ResetTcpIp); Write-Tag OK 'TCP/IP reset. Restart required.' }
                }
                { $_ -match '^[Bb]$' } { return }
            }
        } catch { Write-Tag FAIL $_.Exception.Message }
        Wait-Enter
    }
}

function Invoke-MaintenancePage {
    while ($true) {
        Clear-Host
        Show-Header 'WINDOWS MAINTENANCE (repair tools - not performance boosters)'
        $cmds = @(Get-MaintenanceCommands)
        foreach ($c in $cmds) { Write-Menu $c.Key ('{0,-26}' -f $c.Name) ('[{0}] {1}' -f $c.Category, $c.Note) }
        Write-Menu 'B' 'Back'
        $k = Read-Host '   Choice'
        if ($k -match '^[Bb]$') { return }
        $cmd = @($cmds | Where-Object { $_.Key -eq $k })
        if ($cmd.Count -ne 1) { continue }
        $cmd = $cmd[0]
        try {
            if (-not (Test-Administrator)) { Write-Tag WARN 'These tools need Administrator.'; if (Request-Elevation -Why 'DISM and SFC require Administrator') { $Script:QuitRequested = $true; return }; continue }
            foreach ($w in @(Get-LaptopWarnings -Scan $Script:LastScan -Operation $cmd.Name)) { Write-Tag WARN $w }
            if ($cmd.Confirm -and -not (Read-YesNo -Prompt ("{0}. {1} Run it?" -f $cmd.Name, $cmd.Note))) { continue }
            $code = Invoke-MaintenanceCommand -Cmd $cmd
            if ($code -eq 0) { Write-Tag OK "$($cmd.Name) finished (exit code 0)" } else { Write-Tag WARN "$($cmd.Name) finished with exit code $code" }
        } catch { Write-Tag FAIL $_.Exception.Message }
        Wait-Enter
    }
}

function Show-BackupTable {
    param([object[]]$List)
    $i = 0
    foreach ($b in $List) {
        $i++
        $fmt = switch ($b.Format) { 'v2' { 'v0.7' } 'legacy' { 'legacy v0.6' } default { $b.Format } }
        Write-Host ('  {0,3}  {1,-19} {2,-12} {3,10}  {4}' -f $i, $b.Id, $fmt, (Format-Bytes $b.SizeBytes), $b.Description)
    }
}

function Invoke-RestoreFlow {
    param($Backup, [string[]]$Types = @('Registry', 'Services', 'Tasks', 'Startup', 'PowerPlan', 'Hibernation'))
    if (-not $Backup) { Write-Tag SKIP 'No backup selected.'; return }
    Write-Host ''
    Write-KV 'Backup' $Backup.Id
    Write-KV 'Created' $Backup.Created
    Write-KV 'Size' (Format-Bytes $Backup.SizeBytes)
    Write-KV 'Description' $Backup.Description
    $chk = Test-BackupDir -Dir $Backup.Path
    if ($chk.Format -eq 'v2' -and -not $chk.Ok) {
        Write-Tag FAIL 'This backup failed verification and will not be restored:'
        foreach ($p in $chk.Problems) { Write-Host ('      ' + $p) -ForegroundColor Red }
        return
    }
    if ($chk.Format -eq 'legacy') { Write-Host $Script:LegacyMessage -ForegroundColor Yellow }
    if ($chk.Format -eq 'v2') {
        foreach ($n in @($chk.Meta.NotReversible)) { Write-Host ('   Not restorable automatically: ' + $n) -ForegroundColor Yellow }
    }
    if (-not (Test-Administrator)) { Write-Tag WARN 'Not running as Administrator: HKLM settings, services, tasks and power settings may fail to restore.' }
    if (-not (Read-YesNo -Prompt 'Restore this backup now?')) { return }
    $r = Restore-Backup -Dir $Backup.Path -Types $Types
    if ($r.Refused) { Write-Host ''; Write-Host $r.Message -ForegroundColor Yellow; return }
    Write-Host ''
    Write-KV 'Restored' $r.Success 'Green'
    Write-KV 'Failed' $r.Failed $(if ($r.Failed -gt 0) { 'Red' } else { 'Gray' })
    Write-KV 'Skipped' $r.Skipped 'Yellow'
    if ($r.Failed -gt 0) { Write-Tag WARN 'Some items could not be restored. See the log.' }
    Write-Tag INFO 'A restart or sign-out may be needed for some settings to take effect.'
}

function New-FullStateBackup {
    # Manual snapshot of everything DIVoptimizer knows how to manage, as it is right now.
    $scan = $Script:LastScan
    if (-not $scan) { $scan = Get-SystemScan }
    $s = New-Backup -Description 'Manual backup of current settings'
    $s.SystemRestore = [pscustomobject]@{ Status = 'Not attempted'; Message = 'Manual backup' }
    $catalog = @(Get-TweakCatalog -Scan $scan)
    $k = 0
    foreach ($t in $catalog) {
        $k++
        Write-Busy -Activity 'Creating backup' -Status $t.Name -Percent ([int](85 * $k / [Math]::Max(1, $catalog.Count)))
        $c = Test-TweakCompat -Tweak $t -Windows $scan.Windows
        if (-not $c.Ok) { continue }
        if ($t.Kind -in @('Cleanup', 'Trim', 'App')) { continue }
        [void](Backup-Tweak -Tweak $t)
    }
    Write-Busy -Activity 'Creating backup' -Status 'Startup items...' -Percent 90
    foreach ($it in @(Get-StartupItems | Where-Object { $_.Kind -ne 'Task' })) { [void](Backup-StartupItem -Item $it -TweakId 'manual') }
    Write-Busy -Activity 'Creating backup' -Status 'Writing and verifying files...' -Percent 96
    Save-BackupSession
    $chk = Test-Backup -Dir $s.Dir
    Clear-Busy
    return [pscustomobject]@{ Session = $s; Check = $chk }
}

function Invoke-BackupPage {
    while ($true) {
        Clear-Host
        Show-Header 'BACKUP / RESTORE'
        $list = @(Get-BackupList)
        $set = Get-DivSettings
        Write-KV 'Backup folder' $Script:BackupsDir
        Write-KV 'Retention' ([string]$set.BackupRetention)
        Write-Host ''
        if ($list.Count -eq 0) { Write-Host '   No backups yet.' -ForegroundColor DarkGray } else { Show-BackupTable -List $list }
        Write-Host ''
        Write-Menu 'V' 'View a backup' ; Write-Menu 'C' 'Create backup now (snapshot of current settings)'
        Write-Menu 'R' 'Restore a backup' ; Write-Menu 'D' 'Delete a backup' ; Write-Menu 'O' 'Open backup folder'
        Write-Menu 'S' 'Set retention (5 / 10 / 20 / All)' ; Write-Menu 'B' 'Back'
        $c = (Read-Host '   Choice').Trim()
        if ($c -match '^[Bb]$') { return }
        try {
            switch -Regex ($c) {
                '^[Cc]$' {
                    if (-not (Read-YesNo -Prompt 'Create a backup of the current values of every setting DIVoptimizer manages?' -DefaultYes)) { break }
                    $r = New-FullStateBackup
                    if ($r.Check.Ok) { Write-Tag OK "Backup $($r.Session.Id) created and verified." } else { Write-Tag FAIL ('Backup verification problems: ' + (@($r.Check.Problems) -join ' | ')) }
                    Wait-Enter
                }
                '^[Oo]$' { if (-not (Test-Path -LiteralPath $Script:BackupsDir)) { New-Item -ItemType Directory -Path $Script:BackupsDir -Force | Out-Null }; Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Script:BackupsDir + '"') }
                '^[Ss]$' {
                    $v = (Read-Host '   Keep how many backups? 5, 10, 20 or All').Trim()
                    if ($v -in @('5', '10', '20')) { $set.BackupRetention = $v; Save-DivSettings -Settings $set; Write-Tag OK "Retention set to $v. Older backups are only deleted after you confirm." }
                    elseif ($v -ieq 'All') { $set.BackupRetention = 'All'; Save-DivSettings -Settings $set; Write-Tag OK 'All backups are kept.' }
                    else { Write-Tag WARN 'Not a valid choice.' }
                    Wait-Enter
                }
                '^[VvRrDd]$' {
                    if ($list.Count -eq 0) { Write-Tag SKIP 'No backups.'; Wait-Enter; break }
                    $n = (Read-Host '   Backup number').Trim()
                    if ($n -notmatch '^\d+$' -or [int]$n -lt 1 -or [int]$n -gt $list.Count) { Write-Tag WARN 'Invalid number.'; Wait-Enter; break }
                    $b = $list[[int]$n - 1]
                    if ($c -match '^[Vv]$') {
                        $chk = Test-BackupDir -Dir $b.Path
                        Write-KV 'Backup' $b.Id; Write-KV 'Created' $b.Created; Write-KV 'Format' $b.Format; Write-KV 'Size' (Format-Bytes $b.SizeBytes)
                        Write-KV 'Verified' $(if ($chk.Ok) { 'YES' } else { 'NO' }) $(if ($chk.Ok) { 'Green' } else { 'Red' })
                        if ($b.Meta) { foreach ($ch in @($b.Meta.Changes)) { Write-Host ('      {0}   [{1} -> {2}]  {3}' -f $ch.Name, $ch.Before, $ch.After, $ch.Result) -ForegroundColor DarkGray } }
                        foreach ($p in @($chk.Problems)) { Write-Host ('      ' + $p) -ForegroundColor Yellow }
                        Wait-Enter
                    } elseif ($c -match '^[Rr]$') { Invoke-RestoreFlow -Backup $b; Wait-Enter }
                    else {
                        Write-Host ''
                        Write-KV 'Backup ID' $b.Id; Write-KV 'Backup date' $b.Created; Write-KV 'Backup size' (Format-Bytes $b.SizeBytes)
                        if (Read-YesNo -Prompt 'Permanently delete this backup?') { Remove-BackupFolder -Dir $b.Path; Write-Tag OK "Deleted $($b.Id)" }
                        Wait-Enter
                    }
                }
            }
        } catch { Write-Tag FAIL $_.Exception.Message; Wait-Enter }
    }
}

function Invoke-HistoryPage {
    while ($true) {
        Clear-Host
        Show-Header 'HISTORY'
        $h = @(Get-ChangeHistory)
        if ($h.Count -eq 0) { Write-Host '   No changes have been applied yet.' -ForegroundColor DarkGray; Wait-Enter; return }
        $i = 0
        foreach ($b in $h) {
            $i++
            $label = $b.Description
            if (-not $label) { $label = 'Changes' }
            Write-Host ('  {0,3}  {1}' -f $i, $b.Created) -ForegroundColor White
            Write-Host ('       {0}   {1} change(s)   Backup: {2}' -f $label, $b.ChangeCount, $b.Id) -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '   V <n> view  |  R <n> restore  |  L <n> open log  |  B back' -ForegroundColor DarkGray
        $c = (Read-Host '   Choice').Trim()
        if ($c -match '^[Bb]$') { return }
        if ($c -match '^([VvRrLl])\s*(\d+)$') {
            $act = ([string]$Matches[1]).ToUpper()
            $n = [int]$Matches[2]
            if ($n -lt 1 -or $n -gt $h.Count) { continue }
            $b = $h[$n - 1]
            switch ($act) {
                'V' {
                    foreach ($ch in @($b.Meta.Changes)) { Write-Host ('   [{0}] {1}   {2} -> {3}   ({4})' -f $ch.Risk, $ch.Name, $ch.Before, $ch.After, $ch.Result) }
                    Wait-Enter
                }
                'R' { Invoke-RestoreFlow -Backup $b; Wait-Enter }
                'L' {
                    $lf = Join-Path $Script:LogsDir ([string]$b.Meta.LogFile)
                    if ($b.Meta.LogFile -and (Test-Path -LiteralPath $lf)) { Read-LogFile -Path $lf | Out-Host } else { Write-Tag SKIP 'The log file for this entry was not found.' }
                    Wait-Enter
                }
            }
        }
    }
}

function Invoke-ServiceManagerPage {
    Clear-Host
    Show-Header 'SERVICE MANAGER (Advanced Tools)'
    Write-Host '   Nothing here is recommended automatically. Each service shows what it does and the risk.' -ForegroundColor Yellow
    $scan = Get-SystemScan
    $recs = @()
    foreach ($e in @($Script:ServiceCatalog)) {
        $info = Get-ServiceInfo -Name $e.Name
        if (-not $info.Exists) { continue }
        $tw = New-ServiceTweak -Entry $e -Target 'Disabled'
        $r = ConvertTo-RecFromTweak -Tweak $tw
        if ($e.Guard -eq 'Touch' -and $scan.Hardware.Touch) { $r.Selectable = $false; $r.Blocked = 'Touchscreen detected.' }
        if ($r.Current -match '^Disabled') { $r.Applied = $true; $r.Selectable = $false }
        $r.Why = ("{0}  Recommendation: {1}" -f $e.Why, $e.Guidance)
        $recs += $r
    }
    if ($recs.Count -eq 0) { Write-Tag INFO 'None of the catalog services are present.'; Wait-Enter; return }
    $chosen = Read-TweakSelection -Recs $recs -Title 'SERVICE MANAGER'
    if ($chosen) { [void](Invoke-ReviewAndApply -Recs $chosen -Description 'Service Manager'); Wait-Enter }
}

function Invoke-PowerPlanPage {
    Clear-Host
    Show-Header 'POWER PLAN (Advanced Tools)'
    $scan = Get-SystemScan
    Write-KV 'Current plan' $scan.Power.PlanName
    Write-KV 'Device' $scan.Hardware.DeviceType
    if ($scan.Hardware.BatteryPresent) { Write-KV 'Battery' ("{0}%  AC: {1}" -f $scan.Power.BatteryPercent, $scan.Power.AcLine) }
    Write-Host ''
    Write-Host '   High-performance plans: may increase power consumption, heat and fan noise, and may reduce battery life.' -ForegroundColor Yellow
    Write-Host '   They do not automatically improve FPS.' -ForegroundColor Yellow
    Write-Host ''
    $keys = @('Balanced', 'Performance', 'Maximum')
    $i = 0
    foreach ($k in $keys) { $i++; Write-Menu "$i" $Script:PlanLabels[$k] }
    Write-Menu 'B' 'Back'
    $c = Read-Host '   Choice'
    if ($c -match '^[123]$') {
        $rec = ConvertTo-RecFromTweak -Tweak (New-PowerPlanTweak -Key $keys[[int]$c - 1])
        [void](Invoke-ReviewAndApply -Recs @($rec) -Description 'Power plan')
        Wait-Enter
    }
}

function Invoke-BenchmarkPage {
    while ($true) {
        Clear-Host
        Show-Header 'BENCHMARK (before / after, measured values only)'
        Write-Host '   Captures real measurements: idle CPU, RAM, startup item count, free disk space, process count.' -ForegroundColor DarkGray
        Write-Host '   Application startup time and FPS are NOT measured by DIVoptimizer; use the game or a benchmark tool for those.' -ForegroundColor DarkGray
        Write-Host '   Idle CPU is noisy: close other programs and take both snapshots under similar conditions.' -ForegroundColor DarkGray
        Write-Host ''
        $snaps = @(Get-BenchSnapshots)
        $i = 0
        foreach ($s in $snaps) { $i++; Write-Host ('  {0,3}  {1}   {2}' -f $i, $s.BaseName, $s.LastWriteTime) }
        Write-Host ''
        Write-Menu 'N' 'Capture a new snapshot' ; Write-Menu 'C' 'Compare two snapshots' ; Write-Menu 'B' 'Back'
        $c = (Read-Host '   Choice').Trim()
        if ($c -match '^[Bb]$') { return }
        try {
            if ($c -match '^[Nn]$') {
                $name = (Read-Host '   Name (letters, digits, - _), for example before').Trim()
                Write-Host '   Measuring for about 5 seconds...' -ForegroundColor DarkGray
                $snap = New-BenchSnapshot -Label $name
                $p = Save-BenchSnapshot -Snapshot $snap -Name $name
                Write-Tag OK "Saved $p"
                Wait-Enter
            } elseif ($c -match '^[Cc]$') {
                if ($snaps.Count -lt 2) { Write-Tag SKIP 'Capture at least two snapshots first.'; Wait-Enter; continue }
                $a = [int](Read-Host '   BEFORE snapshot number')
                $b = [int](Read-Host '   AFTER snapshot number')
                $rows = @(Compare-BenchSnapshots -Before (Read-JsonFile -Path $snaps[$a - 1].FullName) -After (Read-JsonFile -Path $snaps[$b - 1].FullName))
                Write-Host ''
                Write-Host ('  {0,-34} {1,-14} {2,-14} {3}' -f 'METRIC', 'BEFORE', 'AFTER', 'CHANGE') -ForegroundColor DarkCyan
                foreach ($r in $rows) { Write-Host ('  {0,-34} {1,-14} {2,-14} {3}' -f $r.Metric, $r.Before, $r.After, $r.Change) }
                Wait-Enter
            }
        } catch { Write-Tag FAIL $_.Exception.Message; Wait-Enter }
    }
}

function Invoke-AdvancedPage {
    while ($true) {
        Clear-Host
        Show-Header 'ADVANCED TOOLS (potentially disruptive - each needs confirmation)'
        Write-Menu '1' 'Service Manager'
        Write-Menu '2' 'Registry tweaks' '(Windows Update delivery)'
        Write-Menu '3' 'Scheduled tasks' '(telemetry tasks)'
        Write-Menu '4' 'Hibernation'
        Write-Menu '5' 'Network reset' '(see Network Tools)'
        Write-Menu '6' 'Temporary Working-Set Trim'
        Write-Menu '7' 'Power plan'
        Write-Menu '8' 'App removal' '(see Optional Apps)'
        Write-Menu '9' 'Benchmark (before/after)'
        Write-Menu 'B' 'Back'
        $c = (Read-Host '   Choice').Trim()
        if ($c -match '^[Bb]$') { return }
        $scan = Get-SystemScan
        switch ($c) {
            '1' { Invoke-ServiceManagerPage }
            '2' { $r = @(Get-Recommendations -Scan $scan -All | Where-Object { $_.Id -eq 'delivery-opt-off' }); $ch = Read-TweakSelection -Recs $r -Title 'REGISTRY TWEAKS'; if ($ch) { [void](Invoke-ReviewAndApply -Recs $ch -Description 'Registry tweak'); Wait-Enter } }
            '3' { $r = @(Get-Recommendations -Scan $scan -All | Where-Object { $_.Id -eq 'tasks-telemetry' }); $ch = Read-TweakSelection -Recs $r -Title 'SCHEDULED TASKS'; if ($ch) { [void](Invoke-ReviewAndApply -Recs $ch -Description 'Scheduled tasks'); Wait-Enter } }
            '4' { $r = @(Get-Recommendations -Scan $scan -All | Where-Object { $_.Id -eq 'hibernate-off' }); $ch = Read-TweakSelection -Recs $r -Title 'HIBERNATION'; if ($ch) { [void](Invoke-ReviewAndApply -Recs $ch -Description 'Hibernation'); Wait-Enter } }
            '5' { Invoke-NetworkPage }
            '6' {
                Clear-Host
                Write-Host '   Temporary Working-Set Trim' -ForegroundColor White
                Write-Host '   This does not create additional physical RAM.' -ForegroundColor Yellow
                Write-Host '   Windows may reload memory when applications need it.' -ForegroundColor Yellow
                Write-Host '   This is intended for temporary memory pressure or troubleshooting.' -ForegroundColor Yellow
                $r = @(Get-Recommendations -Scan $scan -All | Where-Object { $_.Id -eq 'trim-workingset' })
                $ch = Read-TweakSelection -Recs $r -Title 'WORKING-SET TRIM'
                if ($ch) { [void](Invoke-ReviewAndApply -Recs $ch -Description 'Working-set trim'); Wait-Enter }
            }
            '7' { Invoke-PowerPlanPage }
            '8' { Invoke-OptionalAppsPage }
            '9' { Invoke-BenchmarkPage }
        }
    }
}

function Invoke-ResourcePage {
    $sort = 'RAM'
    while ($true) {
        Clear-Host
        Show-Header 'RESOURCE MONITOR / HEALTH (read-only; never ends processes)'
        $snap = Get-ResourceSnapshot
        Write-KV 'CPU' $(if ($null -ne $snap.CpuPct) { "$($snap.CpuPct)%" } else { 'n/a' })
        Write-KV 'RAM' ("{0}%  ({1} of {2} GB)" -f $snap.RamPct, $snap.RamUsedGB, $snap.RamTotalGB)
        Write-KV 'Disk' ("{0} GB free   busy {1}" -f $snap.DiskFreeGB, $(if ($null -ne $snap.DiskBusyPct) { "$($snap.DiskBusyPct)%" } else { 'n/a' }))
        Write-KV 'Network' ("down {0} KB/s   up {1} KB/s" -f $snap.NetRxKBs, $snap.NetTxKBs)
        Write-Section ("Top processes by {0}" -f $sort)
        $top = if ($sort -eq 'CPU') { $snap.Processes | Sort-Object CpuPct -Descending | Select-Object -First 15 } elseif ($sort -eq 'NAME') { $snap.Processes | Sort-Object Name | Select-Object -First 15 } else { $snap.Processes | Sort-Object RamMB -Descending | Select-Object -First 15 }
        $top | Format-Table Name, Id, @{ N = 'CPU %'; E = { $_.CpuPct } }, @{ N = 'RAM MB'; E = { $_.RamMB } } -AutoSize | Out-Host
        Write-Host '   R = RAM sort  |  C = CPU sort  |  N = name sort  |  Enter = refresh  |  B = back' -ForegroundColor DarkGray
        $c = (Read-Host '   Choice').Trim()
        if ($c -match '^[Bb]$') { return }
        if ($c -match '^[Rr]$') { $sort = 'RAM' } elseif ($c -match '^[Cc]$') { $sort = 'CPU' } elseif ($c -match '^[Nn]$') { $sort = 'NAME' }
    }
}

function Invoke-DashboardPage {
    Clear-Host
    Show-Header 'HEALTH DASHBOARD (facts only)'
    $scan = Get-SystemScan
    $m = Get-HealthMetrics -Scan $scan
    foreach ($k in $m.Keys) { Write-KV $k $m[$k] }
    Write-Host ''
    Write-Host '   These are measurements, not a score. There is no "optimization percentage".' -ForegroundColor DarkGray
    Wait-Enter
    Invoke-ResourcePage
}

function Invoke-ExportPage {
    Clear-Host
    Show-Header 'EXPORT SYSTEM REPORT'
    $scan = Get-SystemScan
    $f = (Read-Host '   Format: TXT or JSON [TXT]').Trim().ToLower()
    if ($f -ne 'json') { $f = 'txt' }
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop) { $desktop = $Script:LocalBase }
    $def = Join-Path $desktop ("DIVoptimizer-Report-{0}.{1}" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'), $f)
    $p = (Read-Host "   Save to [$def]").Trim()
    if (-not $p) { $p = $def }
    try { Export-SystemReport -Scan $scan -Path $p -Format $f; Write-Tag OK "Report saved: $p"; Write-Host '   It contains no user name, computer name, serial numbers, file paths or startup command lines.' -ForegroundColor DarkGray } catch { Write-Tag FAIL $_.Exception.Message }
    Wait-Enter
}

function Invoke-UpdatePage {
    Clear-Host
    Show-Header 'CHECK FOR UPDATES'
    Write-Host '   Nothing is downloaded or run unless you ask, and nothing is ever installed automatically.' -ForegroundColor DarkGray
    try {
        $u = Get-UpdateInfo
        Write-KV 'Current' ('v' + $u.Current)
        Write-KV 'Latest' ('v' + $u.Latest)
        Write-KV 'Release notes' $u.Notes
        Write-KV 'Download source' $u.Url
        Write-KV 'SHA-256' $u.Sha256
        if ($u.Newer) {
            if (Read-YesNo -Prompt 'Download it to a staging folder and verify the SHA-256?') {
                $r = Save-UpdatePackage -Info $u
                Write-Tag OK "SHA-256 verified. Signature status: $($r.Signature)"
                Write-Host "   Package: $($r.Zip)"
                Write-Host "   Extracted to: $($r.Folder)"
                Write-Host '   Review it, then run the new DIVoptimizer.ps1 yourself. DIVoptimizer does not replace or run it for you.' -ForegroundColor Yellow
            }
        } else { Write-Tag OK 'You are on the latest version.' }
    } catch { Write-Tag FAIL ('Could not check for updates: ' + $_.Exception.Message) }
    Wait-Enter
}

function Show-AboutPage {
    Clear-Host
    Show-Header 'ABOUT'
    Write-KV 'Program' "$($Script:AppName) v$($Script:Version)"
    Write-KV 'Author' $Script:Author
    Write-KV 'Data folder' $Script:DataRoot
    Write-KV 'Backups' $Script:BackupsDir
    Write-KV 'Logs' $Script:LogsDir
    Write-Host ''
    Write-Host '   DIVoptimizer does not guarantee FPS increases, lower latency, lower temperatures, or faster' -ForegroundColor DarkGray
    Write-Host '   Windows performance. Performance depends on hardware, drivers, applications, configuration,' -ForegroundColor DarkGray
    Write-Host '   thermals and workload. It focuses on transparent configuration changes, maintenance, cleanup' -ForegroundColor DarkGray
    Write-Host '   and user-controlled optimization.' -ForegroundColor DarkGray
    Wait-Enter
}

# ---------------------------------------------------------------
# SCAN-ONLY, DRY-RUN AND MAIN MENU
# ---------------------------------------------------------------

function Invoke-DryRunReport {
    # -WhatIf: prints what COULD change. Makes no change of any kind (no registry, services, files, logs).
    $scan = Get-SystemScan
    Write-Host ''
    Write-Host 'DIVoptimizer DRY RUN' -ForegroundColor Cyan
    Write-Host ("v{0}" -f $Script:Version) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'System:'
    Write-Host ("  Windows {0}  (build {1})" -f $scan.Windows.Generation, $scan.Windows.Build)
    Write-Host ("  {0} GB RAM" -f $scan.Hardware.RamGB)
    Write-Host ("  {0}" -f $scan.Hardware.SystemDriveType)
    Write-Host ("  {0}" -f $scan.Hardware.DeviceType)
    $all = @(Get-Recommendations -Scan $scan -All)
    $rec = @($all | Where-Object { $_.Recommended -and $_.Compatible -and -not $_.Blocked -and -not $_.Applied })
    $other = @($all | Where-Object { -not $_.Recommended -and $_.Compatible -and -not $_.Blocked -and -not $_.Applied -and $_.Kind -notin @('Info') })
    $show = {
        param($rows)
        foreach ($risk in @('LOW RISK', 'OPTIONAL', 'ADVANCED')) {
            foreach ($r in @($rows | Where-Object { $_.Risk -eq $risk })) {
                Write-Host ''
                Write-Host ('[{0}]' -f $risk) -ForegroundColor $(switch ($risk) { 'LOW RISK' { 'Green' } 'OPTIONAL' { 'Yellow' } default { 'Red' } })
                Write-Host $r.Name
                Write-Host ('{0} -> {1}' -f $r.Current, $r.New)
                if ($r.Restart -ne 'No') { Write-Host ("Restart required: {0}" -f $r.Restart) -ForegroundColor DarkGray }
                if ($r.Rollback -eq 'None') { Write-Host 'Not reversible automatically' -ForegroundColor DarkGray }
            }
        }
    }
    Write-Host ''
    Write-Host 'Potential changes (recommended for this PC):'
    if ($rec.Count -eq 0) { Write-Host '  (none)' } else { & $show $rec }
    Write-Host ''
    Write-Host ''
    Write-Host 'Other available options (NOT recommended automatically):'
    if ($other.Count -eq 0) { Write-Host '  (none)' } else { & $show $other }
    Write-Host ''
    $en = @($scan.Startup | Where-Object { $_.Enabled }).Count
    Write-Host ("Startup apps enabled: {0} (review in the Startup Manager)" -f $en)
    Write-Host ''
    Write-Host 'NO CHANGES WERE MADE.' -ForegroundColor Green
    Write-Host ''
}

# ---------------------------------------------------------------
# HEALTH CHECK (read-only) AND UNDO (restore the newest backup)
# ---------------------------------------------------------------

function Get-HealthReport {
    $rows = New-Object System.Collections.Generic.List[object]
    $add = { param($n, $ok, $d) $rows.Add([pscustomobject]@{ Check = $n; Ok = [bool]$ok; Detail = $d }) }
    & $add 'Windows PowerShell 5.1 or newer' ($PSVersionTable.PSVersion.Major -ge 5) ([string]$PSVersionTable.PSVersion)
    & $add 'Running as Administrator' (Test-Administrator) 'Needed to apply or restore system settings; not needed for -Scan, -WhatIf or -Health.'
    $writable = $false
    try {
        if (-not (Test-Path -LiteralPath $Script:BackupsDir)) { $writable = $true } else { $probe = Join-Path $Script:BackupsDir '.health'; Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop; Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue; $writable = $true }
    } catch { $writable = $false }
    & $add 'Backup folder is writable' $writable $Script:BackupsDir
    $backups = @(Get-BackupList)
    & $add 'Backups found' $true ('{0} backup(s)' -f $backups.Count)
    $bad = 0
    foreach ($b in $backups) {
        if ($b.Format -eq 'v2') { $c = Test-BackupDir -Dir $b.Path; if (-not $c.Ok) { $bad++ } } elseif ($b.Format -in @('corrupt', 'unknown')) { $bad++ }
    }
    & $add 'Backups pass verification' ($bad -eq 0) $(if ($bad -eq 0) { 'All checked backups verified.' } else { ('{0} backup(s) failed verification and cannot be restored.' -f $bad) })
    $svcOk = ($Script:ServiceAllowList.Count -eq 2)
    & $add 'Service allow-list' $svcOk ('Only these may be changed: ' + ($Script:ServiceAllowList -join ', '))
    return @($rows)
}

function Show-HealthReport {
    Write-Host ''
    Write-Host ('DIVoptimizer v{0} - health check (read-only, changes nothing)' -f $Script:Version) -ForegroundColor Cyan
    foreach ($r in @(Get-HealthReport)) {
        $tag = 'OK  '; $col = 'Green'
        if (-not $r.Ok) { $tag = 'WARN'; $col = 'Yellow' }
        Write-Host ('  [{0}] {1} - {2}' -f $tag, $r.Check, $r.Detail) -ForegroundColor $col
    }
    Write-Host ''
}

function Invoke-UndoLast {
    # Restores the newest backup that passes verification, after showing what it is and asking first.
    $cands = @(Get-BackupList | Where-Object { $_.Format -in @('v2', 'legacy') })
    if ($cands.Count -eq 0) { Write-Tag SKIP 'There is no backup to undo.'; return }
    $pick = $null
    foreach ($b in $cands) {
        if ($b.Format -eq 'v2') { $c = Test-BackupDir -Dir $b.Path; if (-not $c.Ok) { Write-Tag WARN ("Skipping {0}: it failed verification." -f $b.Id); continue } }
        $pick = $b; break
    }
    if (-not $pick) { Write-Tag FAIL 'No backup passed verification, so nothing was restored.'; return }
    Write-Tag INFO ('The newest usable backup is {0}.' -f $pick.Id)
    Invoke-RestoreFlow -Backup $pick
}

function Show-MainMenu {
    $left = @(
        @{ Kind = 'H'; Text = 'Analyze' },
        @{ Kind = 'I'; Key = '1'; Text = 'Scan System' },
        @{ Kind = 'I'; Key = '2'; Text = 'Recommendations' },
        @{ Kind = 'I'; Key = '3'; Text = 'Quick Optimize' },
        @{ Kind = 'I'; Key = '4'; Text = 'Profiles' },
        @{ Kind = 'B' },
        @{ Kind = 'H'; Text = 'Optimize' },
        @{ Kind = 'I'; Key = '5'; Text = 'Performance' },
        @{ Kind = 'I'; Key = '6'; Text = 'Gaming' },
        @{ Kind = 'I'; Key = '7'; Text = 'Privacy' },
        @{ Kind = 'I'; Key = '8'; Text = 'Optional Apps' },
        @{ Kind = 'I'; Key = '9'; Text = 'Startup Manager' }
    )
    $right = @(
        @{ Kind = 'H'; Text = 'Maintain' },
        @{ Kind = 'I'; Key = '10'; Text = 'Cleanup' },
        @{ Kind = 'I'; Key = '11'; Text = 'Network Tools' },
        @{ Kind = 'I'; Key = '12'; Text = 'Windows Maintenance' },
        @{ Kind = 'B' },
        @{ Kind = 'H'; Text = 'Recover' },
        @{ Kind = 'I'; Key = '13'; Text = 'Backup / Restore' },
        @{ Kind = 'I'; Key = '14'; Text = 'History' },
        @{ Kind = 'B' },
        @{ Kind = 'H'; Text = 'More' },
        @{ Kind = 'I'; Key = '15'; Text = 'Advanced Tools' },
        @{ Kind = 'I'; Key = '16'; Text = 'Dashboard / Resources' },
        @{ Kind = 'I'; Key = '17'; Text = 'Export Report' },
        @{ Kind = 'I'; Key = '18'; Text = 'Check for Updates' },
        @{ Kind = 'I'; Key = '19'; Text = 'About' },
        @{ Kind = 'I'; Key = '20'; Text = 'DIVuninstaller' },
        @{ Kind = 'I'; Key = '21'; Text = 'Junk Cleaner' },
        @{ Kind = 'I'; Key = '0'; Text = 'Exit' }
    )
    $colW = [int](($Script:Width - 2) / 2)
    while ($true) {
        Clear-Host
        Show-Banner
        $s = $Script:LastScan
        $adminTxt = if ($s.IsAdmin) { 'Admin' } else { 'Standard user' }
        $backups = @(Get-BackupList).Count
        Write-Host ('  {0}  |  {1}  |  {2} GB  |  {3}  |  {4}  |  Backups: {5}' -f $s.Windows.Caption, $s.Hardware.DeviceType, $s.Hardware.RamGB, $s.Hardware.SystemDriveType, $adminTxt, $backups) -ForegroundColor DarkGray
        Write-Host ''
        $rows = [Math]::Max($left.Count, $right.Count)
        for ($i = 0; $i -lt $rows; $i++) {
            $l = if ($i -lt $left.Count) { $left[$i] } else { $null }
            $r = if ($i -lt $right.Count) { $right[$i] } else { $null }
            Write-Cell -Cell $l -Width $colW
            Write-Cell -Cell $r -Width $colW
            Write-Host ''
        }
        Write-Host ''
        Write-Host ('  ' + ('-' * ($Script:Width - 4))) -ForegroundColor DarkGray
        Write-Host '  Scan -> recommend -> preview -> backup -> your approval -> apply -> verify -> restore.' -ForegroundColor DarkGray
        $c = (Read-Host '  Select an option').Trim()
        try {
            switch ($c) {
                '1'  { Invoke-ScanPage }
                '2'  { Invoke-RecommendationsPage }
                '3'  { Invoke-QuickOptimize }
                '4'  { Invoke-ProfilesMenu }
                '5'  { Invoke-CategoryPage -Title 'PERFORMANCE' -Categories @('Performance') }
                '6'  { Invoke-CategoryPage -Title 'GAMING' -Categories @('Gaming') }
                '7'  { Invoke-CategoryPage -Title 'PRIVACY' -Categories @('Privacy') }
                '8'  { Invoke-OptionalAppsPage }
                '9'  { Invoke-StartupPage }
                '10' { Invoke-CleanupPage }
                '11' { Invoke-NetworkPage }
                '12' { Invoke-MaintenancePage }
                '13' { Invoke-BackupPage }
                '14' { Invoke-HistoryPage }
                '15' { Invoke-AdvancedPage }
                '16' { Invoke-DashboardPage }
                '17' { Invoke-ExportPage }
                '18' { Invoke-UpdatePage }
                '19' { Show-AboutPage }
                '20' { Invoke-UninstallerPage }
                '21' { Invoke-JunkPage }
                '0'  { return }
                default { Write-Tag WARN 'Invalid choice'; Start-Sleep -Seconds 1 }
            }
        } catch {
            Write-Tag FAIL ('Unexpected error: ' + $_.Exception.Message)
            Write-Log -Level FAIL -Action 'UI_ERROR' -ErrorText $_.Exception.ToString()
            Wait-Enter
        }
        if ($Script:QuitRequested) { return }
    }
}

function Show-SessionSummary {
    Clear-Host
    Show-Header 'SESSION SUMMARY'
    Write-KV 'Successful' $Script:Counters.Success 'Green'
    Write-KV 'Skipped' $Script:Counters.Skipped 'Yellow'
    Write-KV 'Failed' $Script:Counters.Failed $(if ($Script:Counters.Failed -gt 0) { 'Red' } else { 'Gray' })
    if ($Script:BackupSession) { Write-KV 'Last backup' $Script:BackupSession.Id }
    if ($Script:SessionLogPath) { Write-KV 'Log' $Script:SessionLogPath }
    if ($Script:RestartNeeded) { Write-Host ''; Write-Host '   A restart is needed for some changes to take effect.' -ForegroundColor Yellow }
    Write-Host ''
}

function Start-ConsoleApp {
    Initialize-Console
    Clear-Host
    Show-Banner
    Write-Host ''
    Write-Host '   Scanning your system (read-only)...' -ForegroundColor DarkGray
    $scan = Get-SystemScan
    if (-not $scan.Windows.Supported) {
        Write-Tag FAIL "This PC is not supported: $($scan.Windows.Status)"
        Wait-Enter
        return
    }
    Show-SystemSummary -Scan $scan
    $mm = Test-ElevationUserMismatch
    if ($mm -and $scan.IsAdmin) { Write-Tag WARN $mm }
    Start-Sleep -Seconds 1
    if ($Script:PreselectIds -and @($Script:PreselectIds).Count -gt 0 -and $scan.IsAdmin) { Invoke-RecommendationsPage }
    Show-MainMenu
    Show-SessionSummary
}
# ---------------------------------------------------------------
# GUI (WPF). Pages are functions that fill one content panel. All state lives in $Script:Gui* variables
# so event handlers never depend on a local scope that has already ended.
# ---------------------------------------------------------------

$Script:GuiWindow = $null
$Script:GuiContent = $null
$Script:GuiStatus = $null
$Script:GuiBusyOverlay = $null
$Script:GuiBusyTitle = $null
$Script:GuiBusyDetail = $null
$Script:GuiBusyBar = $null
$Script:GuiStarted = $false
$Script:GuiChecks = New-Object System.Collections.Generic.List[object]

$Script:GuiXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DIVoptimizer" Height="780" Width="1040" MinHeight="560" MinWidth="820"
        WindowStartupLocation="CenterScreen" Background="#0B1220" FontFamily="Segoe UI Variable Text, Segoe UI">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#1B2742"/>
      <Setter Property="Foreground" Value="#E8EEF8"/>
      <Setter Property="BorderBrush" Value="#25324D"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Margin" Value="3"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E8EEF8"/>
      <Setter Property="Margin" Value="2,6,2,2"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#E8EEF8"/>
    </Style>
    <Style TargetType="Expander">
      <Setter Property="Foreground" Value="#8DA0BF"/>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#131D33" BorderBrush="#25324D" BorderThickness="0,0,0,1" Padding="18,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="DIV" FontSize="22" FontWeight="Bold" Foreground="#7C8CFF"/>
          <TextBlock Text="optimizer" FontSize="22" FontWeight="Bold" Foreground="White"/>
          <TextBlock x:Name="VersionText" FontSize="12" Foreground="#8DA0BF" VerticalAlignment="Bottom" Margin="10,0,0,3"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock x:Name="SysLine" Foreground="#8DA0BF" FontSize="12" VerticalAlignment="Center" Margin="0,0,12,0"/>
          <Button x:Name="HomeBtn" Content="HOME"/>
        </StackPanel>
      </Grid>
    </Border>
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
      <StackPanel x:Name="Content" Margin="24,16,24,16"/>
    </ScrollViewer>
    <Border Grid.Row="2" Background="#131D33" BorderBrush="#25324D" BorderThickness="0,1,0,0" Padding="16,8">
      <TextBlock x:Name="StatusText" Text="Ready." Foreground="#8DA0BF" TextWrapping="Wrap"/>
    </Border>
    <Grid x:Name="BusyOverlay" Grid.RowSpan="3" Background="#D90B1220" Visibility="Collapsed" Panel.ZIndex="10">
      <Border Background="#131D33" BorderBrush="#25324D" BorderThickness="1" CornerRadius="14" Padding="32,26" HorizontalAlignment="Center" VerticalAlignment="Center" MinWidth="440" MaxWidth="640">
        <StackPanel>
          <TextBlock x:Name="BusyTitle" Text="Working..." FontSize="18" FontWeight="Bold" Foreground="White"/>
          <TextBlock x:Name="BusyDetail" Text="" Foreground="#8DA0BF" Margin="0,6,0,16" TextWrapping="Wrap"/>
          <ProgressBar x:Name="BusyBar" Height="8" Minimum="0" Maximum="100" IsIndeterminate="True" Foreground="#7C8CFF" Background="#25324D" BorderThickness="0"/>
          <TextBlock Text="Please wait. Nothing else can be clicked until this finishes." FontSize="11" Foreground="#6F82A3" Margin="0,12,0,0"/>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

function Get-GuiBrush {
    param([string]$Hex)
    return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex)
}

function Update-GuiUi {
    try { $Script:GuiWindow.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render) } catch { Write-Log -Level WARN -Action 'GUI_REFRESH' -ErrorText $_.Exception.Message }
}

function Set-GuiStatus {
    param([string]$Text)
    $Script:GuiStatus.Text = $Text
    Update-GuiUi
}

function Start-GuiBusy {
    param([string]$Title = 'Working...', [string]$Detail = '')
    if (-not $Script:GuiBusyOverlay) { return }
    $Script:GuiBusyTitle.Text = $Title
    $Script:GuiBusyDetail.Text = $Detail
    $Script:GuiBusyBar.IsIndeterminate = $true
    $Script:GuiBusyOverlay.Visibility = 'Visible'
    $Script:GuiStatus.Text = $Title
    Update-GuiUi
}

function Set-GuiBusy {
    param([string]$Text, [int]$Percent = -1)
    if (-not $Script:GuiBusyOverlay) { return }
    $Script:GuiBusyDetail.Text = $Text
    if ($Percent -ge 0) { $Script:GuiBusyBar.IsIndeterminate = $false; $Script:GuiBusyBar.Value = [Math]::Min(100, $Percent) }
    else { $Script:GuiBusyBar.IsIndeterminate = $true }
    $Script:GuiStatus.Text = $Text
    Update-GuiUi
}

function Stop-GuiBusy {
    if (-not $Script:GuiBusyOverlay) { return }
    $Script:GuiBusyOverlay.Visibility = 'Collapsed'
    Update-GuiUi
}

function Invoke-GuiWithBusy {
    # Runs a task behind the loading overlay and ALWAYS removes the overlay afterwards, even on an error.
    param([string]$Title, [string]$Detail = '', [scriptblock]$Action)
    Start-GuiBusy -Title $Title -Detail $Detail
    try { return (& $Action) } finally { Stop-GuiBusy }
}

function New-GuiText {
    param([string]$Text, [int]$Size = 13, [string]$Color = '#E8EEF8', [switch]$Bold, [string]$Margin = '0,2,0,2')
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.Foreground = (Get-GuiBrush $Color)
    $t.TextWrapping = 'Wrap'
    $t.Margin = $Margin
    if ($Bold) { $t.FontWeight = 'Bold' }
    return $t
}

function New-GuiButton {
    param([string]$Text, [scriptblock]$OnClick, $Tag = $null, [int]$Width = 0, [string]$Bg = '')
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $Text
    $b.Tag = $Tag
    if ($Width -gt 0) { $b.Width = $Width }
    if ($Bg) { $b.Background = (Get-GuiBrush $Bg); $b.Foreground = (Get-GuiBrush '#FFFFFF') }
    $b.Add_Click($OnClick)
    return $b
}

function Add-GuiChild {
    param($Parent, $Child)
    [void]$Parent.Children.Add($Child)
}

function Reset-GuiPage {
    param([string]$Title, [string]$Subtitle = '')
    $Script:GuiContent.Children.Clear()
    $Script:GuiChecks.Clear()
    Add-GuiChild $Script:GuiContent (New-GuiText -Text $Title -Size 22 -Bold -Margin '0,0,0,2')
    if ($Subtitle) { Add-GuiChild $Script:GuiContent (New-GuiText -Text $Subtitle -Size 12 -Color '#8DA0BF' -Margin '0,0,0,12') }
}

function Show-GuiMessage {
    param([string]$Text, [string]$Title = 'DIVoptimizer', [string]$Icon = 'Information')
    [void][System.Windows.MessageBox]::Show($Script:GuiWindow, $Text, $Title, 'OK', $Icon)
}

function Confirm-Gui {
    param([string]$Text, [string]$Title = 'DIVoptimizer', [string]$Icon = 'Question')
    $r = [System.Windows.MessageBox]::Show($Script:GuiWindow, $Text, $Title, 'YesNo', $Icon, 'No')
    return ($r -eq 'Yes')
}

function Show-GuiTextDialog {
    param([string]$Title, [string]$Text)
    $w = New-Object System.Windows.Window
    $w.Title = $Title; $w.Width = 820; $w.Height = 600; $w.Owner = $Script:GuiWindow
    $w.WindowStartupLocation = 'CenterOwner'; $w.Background = (Get-GuiBrush '#0B1220')
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Text = $Text; $tb.IsReadOnly = $true; $tb.FontFamily = 'Consolas'; $tb.FontSize = 12
    $tb.Background = (Get-GuiBrush '#131D33'); $tb.Foreground = (Get-GuiBrush '#E8EEF8')
    $tb.VerticalScrollBarVisibility = 'Auto'; $tb.HorizontalScrollBarVisibility = 'Auto'; $tb.Margin = '10'
    $w.Content = $tb
    [void]$w.ShowDialog()
}

function Show-GuiReviewDialog {
    # Returns $true when the user approves. ADVANCED changes require ticking an acknowledgement box.
    param([object[]]$Recs, $Ready)
    $w = New-Object System.Windows.Window
    $w.Title = 'Review changes'; $w.Width = 760; $w.Height = 680; $w.Owner = $Script:GuiWindow
    $w.WindowStartupLocation = 'CenterOwner'; $w.Background = (Get-GuiBrush '#0B1220')
    $root = New-Object System.Windows.Controls.Grid
    $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = '*'
    $r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = 'Auto'
    [void]$root.RowDefinitions.Add($r1); [void]$root.RowDefinitions.Add($r2)
    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = '18'
    $sv.Content = $sp
    Add-GuiChild $sp (New-GuiText -Text 'REVIEW CHANGES' -Size 20 -Bold)
    Add-GuiChild $sp (New-GuiText -Text ("{0} change(s) selected" -f @($Recs).Count) -Color '#8DA0BF' -Margin '0,0,0,10')
    $arrow = [string][char]0x2192
    foreach ($risk in @('LOW RISK', 'OPTIONAL', 'ADVANCED')) {
        $color = switch ($risk) { 'LOW RISK' { '#3FB950' } 'OPTIONAL' { '#D29922' } default { '#F85149' } }
        foreach ($r in @($Recs | Where-Object { $_.Risk -eq $risk })) {
            Add-GuiChild $sp (New-GuiText -Text $risk -Size 11 -Bold -Color $color -Margin '0,10,0,0')
            Add-GuiChild $sp (New-GuiText -Text $r.Name -Bold)
            Add-GuiChild $sp (New-GuiText -Text ("{0}  {1}  {2}" -f $r.Current, $arrow, $r.New) -Color '#8DA0BF')
            if ($r.Restart -ne 'No') { Add-GuiChild $sp (New-GuiText -Text ('Restart required: ' + $r.Restart) -Size 12 -Color '#D29922') }
            if ($r.Rollback -eq 'None') { Add-GuiChild $sp (New-GuiText -Text ('Not reversible automatically. ' + $r.RollbackNote) -Size 12 -Color '#D29922') }
        }
    }
    Add-GuiChild $sp (New-GuiText -Text 'SAFETY CHECKS' -Size 11 -Bold -Color '#7C8CFF' -Margin '0,16,0,2')
    Add-GuiChild $sp (New-GuiText -Text ('Backup: ' + $(if ($Ready.BackupReady) { 'READY' } else { 'NOT READY - ' + $Ready.BackupProblem })))
    Add-GuiChild $sp (New-GuiText -Text ('System Restore: ' + $Ready.RestorePointText))
    foreach ($c in @($Ready.Coverage | Where-Object { $_.Needed })) { Add-GuiChild $sp (New-GuiText -Text ("{0} will be backed up" -f $c.Name) -Size 12 -Color '#8DA0BF') }
    foreach ($n in @($Ready.NotReversible)) { Add-GuiChild $sp (New-GuiText -Text ('Not reversible automatically: ' + $n) -Size 12 -Color '#D29922') }
    foreach ($t in @($Recs)) {
        if ($t.Kind -eq 'PowerPlan' -and $t.Tweak.PlanKey -ne 'Balanced' -and $Script:LastScan.Hardware.DeviceType -eq 'Laptop') {
            Add-GuiChild $sp (New-GuiText -Text 'Laptop: this plan may increase power consumption, heat and fan noise, and reduce battery life.' -Size 12 -Color '#D29922')
        }
    }
    $bar = New-Object System.Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'; $bar.HorizontalAlignment = 'Right'; $bar.Margin = '12'
    [System.Windows.Controls.Grid]::SetRow($bar, 1)
    $apply = New-GuiButton -Text 'APPLY' -Width 110 -Bg '#238636' -OnClick { param($s, $e) [System.Windows.Window]::GetWindow($s).DialogResult = $true }
    $cancel = New-GuiButton -Text 'CANCEL' -Width 110 -OnClick { param($s, $e) [System.Windows.Window]::GetWindow($s).DialogResult = $false }
    if ($Ready.HasAdvanced) {
        $ack = New-Object System.Windows.Controls.CheckBox
        $ack.Content = 'I understand these ADVANCED changes may affect Windows functionality'
        $ack.Foreground = (Get-GuiBrush '#F85149'); $ack.VerticalAlignment = 'Center'; $ack.Margin = '0,0,14,0'
        $ack.Tag = $apply
        $apply.IsEnabled = $false
        $ack.Add_Checked({ param($s, $e) $s.Tag.IsEnabled = $true })
        $ack.Add_Unchecked({ param($s, $e) $s.Tag.IsEnabled = $false })
        [void]$bar.Children.Add($ack)
    }
    if (-not $Ready.BackupReady) { $apply.IsEnabled = $false }
    [void]$bar.Children.Add($apply); [void]$bar.Children.Add($cancel)
    [void]$root.Children.Add($sv); [void]$root.Children.Add($bar)
    $w.Content = $root
    return ($w.ShowDialog() -eq $true)
}

function Show-GuiResult {
    param($Res)
    Reset-GuiPage -Title $(if ($Res.Aborted) { 'CANCELLED' } elseif ($Res.Failed -gt 0) { 'COMPLETED WITH WARNINGS' } else { 'OPTIMIZATION COMPLETE' })
    if ($Res.Aborted) {
        Add-GuiChild $Script:GuiContent (New-GuiText -Text $Res.AbortReason -Color '#D29922')
        Add-GuiChild $Script:GuiContent (New-GuiText -Text 'No settings were changed.' -Color '#8DA0BF')
        return
    }
    Add-GuiChild $Script:GuiContent (New-GuiText -Text ("Successful: {0}     Failed: {1}     Skipped: {2}" -f $Res.Success, $Res.Failed, $Res.Skipped) -Size 15)
    foreach ($i in @($Res.Items)) {
        $col = switch ($i.Status) { 'Success' { '#3FB950' } 'Failed' { '#F85149' } default { '#D29922' } }
        $line = ("{0}: {1}" -f $i.Status.ToUpper(), $i.Name)
        if ($i.Message) { $line += ('  -  ' + $i.Message) }
        Add-GuiChild $Script:GuiContent (New-GuiText -Text $line -Color $col -Size 12)
    }
    Add-GuiChild $Script:GuiContent (New-GuiText -Text ('Backup: ' + $(if ($Res.BackupId) { $Res.BackupId } else { 'none' })) -Margin '0,14,0,0')
    Add-GuiChild $Script:GuiContent (New-GuiText -Text ('System Restore: ' + $Res.RestorePoint.Status + $(if ($Res.RestorePoint.Message) { ' - ' + $Res.RestorePoint.Message } else { '' })))
    Add-GuiChild $Script:GuiContent (New-GuiText -Text ('Restart required: ' + $(if ($Res.RestartNeeded) { 'YES' } else { 'NO' })))
    $bar = New-Object System.Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'; $bar.Margin = '0,14,0,0'
    Add-GuiChild $bar (New-GuiButton -Text 'VIEW LOG' -Width 110 -Tag $Res -OnClick {
        param($s, $e)
        $r = $s.Tag
        if ($r.LogFile -and (Test-Path -LiteralPath $r.LogFile)) { Show-GuiTextDialog -Title 'Log' -Text ((Read-LogFile -Path $r.LogFile) -join "`r`n`r`n") } else { Show-GuiMessage 'No log file is available for this session.' }
    })
    if ($Res.BackupId) {
        Add-GuiChild $bar (New-GuiButton -Text 'RESTORE' -Width 110 -Tag $Res -OnClick {
            param($s, $e)
            $b = @(Get-BackupList | Where-Object { $_.Id -eq $s.Tag.BackupId })
            if ($b.Count -gt 0) { Invoke-GuiRestore -Backup $b[0] }
        })
    }
    Add-GuiChild $bar (New-GuiButton -Text 'CLOSE' -Width 110 -OnClick { Show-GuiDashboard })
    Add-GuiChild $Script:GuiContent $bar
    if ($Res.RestartNeeded) {
        Add-GuiChild $Script:GuiContent (New-GuiButton -Text 'RESTART NOW' -Width 130 -OnClick { if (Confirm-Gui 'Restart Windows now? Save your work first.') { Restart-Computer -Confirm:$false } })
    }
}

function Invoke-GuiApply {
    param([object[]]$Recs, [string]$Description = 'Optimization', [string]$ProfileName = '')
    $Recs = @($Recs)
    if ($Recs.Count -eq 0) { Show-GuiMessage 'Nothing is selected.'; return }
    $tweaks = @($Recs | ForEach-Object { $_.Tweak })
    $ready = Get-ApplyReadiness -Tweaks $tweaks
    if ($ready.NeedsElevation) {
        if (Confirm-Gui "Some of these changes modify system-wide settings (HKLM, services, scheduled tasks or restore points) and need Administrator.`n`nRelaunch DIVoptimizer as Administrator? Windows will show a UAC prompt.") {
            $ids = @($tweaks | ForEach-Object { $_.Id })
            if (Request-Elevation -Why 'selected changes modify system-wide settings' -Ids $ids -Silent) { $Script:GuiWindow.Close() }
        }
        return
    }
    if (-not (Show-GuiReviewDialog -Recs $Recs -Ready $ready)) { Set-GuiStatus 'Cancelled. Nothing was changed.'; return }
    $prompt = { param($m, $adv) return (Confirm-Gui ($m) 'DIVoptimizer - warning' 'Warning') }
    $progress = { param($m, $p) Set-GuiBusy -Text $m -Percent $p }
    Start-GuiBusy -Title 'Applying changes' -Detail 'Preparing...'
    try {
        $res = Invoke-ApplyPlan -Tweaks $tweaks -Description $Description -ProfileName $ProfileName -AdvancedConfirmed:$ready.HasAdvanced -Prompt $prompt -Progress $progress
    } finally { Stop-GuiBusy }
    Set-GuiStatus 'Done.'
    Show-GuiResult -Res $res
}

function Invoke-GuiRestore {
    param($Backup)
    $chk = Test-BackupDir -Dir $Backup.Path
    if ($chk.Format -eq 'v2' -and -not $chk.Ok) { Show-GuiMessage ("This backup failed verification and will not be restored:`n`n" + (@($chk.Problems) -join "`n")) 'Restore refused' 'Error'; return }
    if ($chk.Format -eq 'legacy') { Show-GuiMessage $Script:LegacyMessage 'Legacy backup' 'Warning' }
    $msg = "Restore backup $($Backup.Id)?`nCreated: $($Backup.Created)`nSize: $(Format-Bytes $Backup.SizeBytes)`n`nSettings are put back to the recorded original values. Apps that were removed cannot be restored automatically."
    if (-not (Test-Administrator)) { $msg += "`n`nNot running as Administrator: HKLM settings, services, tasks and power settings may fail to restore." }
    if (-not (Confirm-Gui $msg 'Confirm restore')) { return }
    Set-GuiStatus "Restoring $($Backup.Id)..."
    $r = Invoke-GuiWithBusy -Title 'Restoring backup' -Detail "Restoring $($Backup.Id)..." -Action { Restore-Backup -Dir $Backup.Path }
    Set-GuiStatus 'Restore finished.'
    if ($r.Refused) { Show-GuiMessage $r.Message 'Restore refused' 'Warning'; return }
    Show-GuiMessage ("Restored: {0}`nFailed: {1}`nSkipped: {2}`n`nA restart or sign-out may be needed for some settings. See the log for details." -f $r.Success, $r.Failed, $r.Skipped) 'Restore finished'
}

# ---- generic tweak-list page ----

function Show-GuiTweakPage {
    param([string]$Title, [string]$Subtitle, [object[]]$Recs, [string]$Description, [string]$ProfileName = '', [string[]]$PreselectIds = @())
    Reset-GuiPage -Title $Title -Subtitle $Subtitle
    $Recs = @($Recs)
    if ($Recs.Count -eq 0) { Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Nothing to show here for this PC.' -Color '#8DA0BF'); return }
    $arrow = [string][char]0x2192
    foreach ($risk in @('LOW RISK', 'OPTIONAL', 'ADVANCED')) {
        $group = @($Recs | Where-Object { $_.Risk -eq $risk })
        if ($group.Count -eq 0) { continue }
        $color = switch ($risk) { 'LOW RISK' { '#3FB950' } 'OPTIONAL' { '#D29922' } default { '#F85149' } }
        Add-GuiChild $Script:GuiContent (New-GuiText -Text $risk -Size 12 -Bold -Color $color -Margin '0,14,0,0')
        foreach ($r in $group) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $r.Name
            $cb.Tag = $r
            $cb.IsEnabled = ($r.Selectable -and $r.Kind -ne 'Info')
            $cb.IsChecked = ($r.DefaultSelected -or (@($PreselectIds) -contains $r.Id -and $r.Selectable))
            $Script:GuiChecks.Add($cb)
            Add-GuiChild $Script:GuiContent $cb
            $sub = if (-not $r.Compatible) { $r.CompatMessage } elseif ($r.Blocked) { 'Not offered: ' + $r.Blocked } elseif ($r.Applied) { 'Already set.' } else { ("{0}  {1}  {2}" -f $r.Current, $arrow, $r.New) }
            Add-GuiChild $Script:GuiContent (New-GuiText -Text $sub -Size 12 -Color '#8DA0BF' -Margin '22,0,0,0')
            $exp = New-Object System.Windows.Controls.Expander
            $exp.Header = 'Details'; $exp.Margin = '20,0,0,0'
            $dp = New-Object System.Windows.Controls.StackPanel
            Add-GuiChild $dp (New-GuiText -Text ('Why: ' + $r.Why) -Size 12 -Color '#C8D3E8')
            Add-GuiChild $dp (New-GuiText -Text ('Potential downside: ' + $r.Downside) -Size 12 -Color '#C8D3E8')
            Add-GuiChild $dp (New-GuiText -Text ('Restart required: ' + $r.Restart) -Size 12 -Color '#C8D3E8')
            $rb = if ($r.Rollback -eq 'None') { 'NOT reversible automatically. ' + $r.RollbackNote } else { 'Available' }
            Add-GuiChild $dp (New-GuiText -Text ('Rollback: ' + $rb) -Size 12 -Color '#C8D3E8')
            $exp.Content = $dp
            Add-GuiChild $Script:GuiContent $exp
        }
    }
    $bar = New-Object System.Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'; $bar.Margin = '0,18,0,0'
    Add-GuiChild $bar (New-GuiButton -Text 'SELECT ALL LOW RISK' -OnClick { foreach ($c in $Script:GuiChecks) { if ($c.IsEnabled) { $c.IsChecked = ($c.Tag.Risk -eq 'LOW RISK') } } })
    Add-GuiChild $bar (New-GuiButton -Text 'SELECT NONE' -OnClick { foreach ($c in $Script:GuiChecks) { $c.IsChecked = $false } })
    $Script:GuiApplyArgs = @{ Description = $Description; ProfileName = $ProfileName }
    Add-GuiChild $bar (New-GuiButton -Text 'APPLY SELECTED' -Bg '#238636' -OnClick {
        $chosen = @($Script:GuiChecks | Where-Object { $_.IsChecked -and $_.IsEnabled } | ForEach-Object { $_.Tag })
        Invoke-GuiApply -Recs $chosen -Description $Script:GuiApplyArgs.Description -ProfileName $Script:GuiApplyArgs.ProfileName
    })
    Add-GuiChild $Script:GuiContent $bar
    Add-GuiChild $Script:GuiContent (New-GuiText -Text 'ADVANCED items are never selected automatically.' -Size 11 -Color '#8DA0BF' -Margin '0,6,0,0')
}

# ---- pages ----

function Show-GuiScan {
    Set-GuiStatus 'Scanning (read-only)...'
    $scan = Invoke-GuiWithBusy -Title 'Scanning your PC' -Detail 'Reading hardware and settings. This does not change anything.' -Action { Get-SystemScan }
    Update-GuiSysLine
    Reset-GuiPage -Title 'System scan' -Subtitle 'Read-only. Nothing was changed.'
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Text = ((Get-ScanReportLines -Scan $scan) -join "`r`n")
    $tb.IsReadOnly = $true; $tb.FontFamily = 'Consolas'; $tb.FontSize = 12; $tb.Height = 520
    $tb.Background = (Get-GuiBrush '#131D33'); $tb.Foreground = (Get-GuiBrush '#E8EEF8')
    $tb.VerticalScrollBarVisibility = 'Auto'; $tb.HorizontalScrollBarVisibility = 'Auto'
    Add-GuiChild $Script:GuiContent $tb
    Set-GuiStatus 'Scan complete.'
}

function Show-GuiRecommendations {
    param([string]$ProfileName = '')
    Set-GuiStatus 'Analysing...'
    $scan = Invoke-GuiWithBusy -Title 'Scanning your PC' -Detail 'Reading hardware and settings. This does not change anything.' -Action { Get-SystemScan }
    $recs = @(Get-Recommendations -Scan $scan -ProfileName $ProfileName)
    $title = 'Recommendations'
    if ($ProfileName) { $title = "$ProfileName Profile" }
    $pre = @()
    if ($Script:PreselectIds) { $pre = @($Script:PreselectIds); $Script:PreselectIds = @() }
    Show-GuiTweakPage -Title $title -Subtitle 'Chosen for THIS PC. LOW RISK items are ticked; nothing is applied until you review and approve it.' -Recs $recs -Description $title -ProfileName $ProfileName -PreselectIds $pre
    Set-GuiStatus 'Ready.'
}

function Show-GuiCategory {
    param([string]$Title, [string[]]$Categories)
    Set-GuiStatus 'Reading settings...'
    $scan = Invoke-GuiWithBusy -Title 'Scanning your PC' -Detail 'Reading hardware and settings. This does not change anything.' -Action { Get-SystemScan }
    $recs = @(Get-Recommendations -Scan $scan -All | Where-Object { $Categories -contains $_.Category -and $_.Risk -ne 'ADVANCED' })
    Show-GuiTweakPage -Title $Title -Subtitle 'Current to new values are shown for every option.' -Recs $recs -Description $Title
    Set-GuiStatus 'Ready.'
}

function Invoke-GuiQuickOptimize {
    Set-GuiStatus 'Analysing...'
    $scan = Invoke-GuiWithBusy -Title 'Scanning your PC' -Detail 'Reading hardware and settings. This does not change anything.' -Action { Get-SystemScan }
    $set = @(Get-QuickOptimizeSet -Scan $scan)
    if ($set.Count -eq 0) { Show-GuiMessage 'Nothing LOW RISK needs changing on this PC.'; Set-GuiStatus 'Ready.'; return }
    Invoke-GuiApply -Recs $set -Description 'Quick Optimize'
}

function Show-GuiOptionalApps {
    Reset-GuiPage -Title 'Optional apps' -Subtitle 'You choose what to remove. Removal is NOT automatically reversible; apps may need to be reinstalled from Microsoft Store or another official source.'
    $recs = @(Invoke-GuiWithBusy -Title 'Checking installed apps' -Detail 'Reading the list of Windows apps...' -Action {
        $installed = @{}
        foreach ($p in @(Get-AppxPackage -ErrorAction SilentlyContinue)) { $installed[[string]$p.Name] = $true }
        $out = @()
        $cat = @($Script:AppCatalog)
        $k = 0
        foreach ($e in $cat) {
            $k++
            Set-GuiBusy -Text ('Checking ' + $e.Label) -Percent ([int](100 * $k / $cat.Count))
            if (-not $installed.ContainsKey([string]$e.Package)) { continue }
            if (Test-PackageProtected -Name $e.Package) { continue }
            $out += (ConvertTo-RecFromTweak -Tweak (New-AppTweak -Entry $e))
        }
        return $out
    })
    $Script:GuiContent.Children.Clear()
    Show-GuiTweakPage -Title 'Optional apps' -Subtitle 'You choose what to remove. Removal is NOT automatically reversible; apps may need to be reinstalled from Microsoft Store or another official source.' -Recs $recs -Description 'Optional Apps'
}

function Show-GuiStartup {
    Reset-GuiPage -Title 'Startup manager' -Subtitle 'Entries are never deleted; only their enabled flag changes. Impact shown is observed RAM of running programs.'
    $items = @(Invoke-GuiWithBusy -Title 'Reading startup items' -Detail 'Including scheduled tasks that run at sign-in...' -Action { Get-StartupItems -IncludeTasks })
    if ($items.Count -eq 0) { Add-GuiChild $Script:GuiContent (New-GuiText -Text 'No startup items found.'); return }
    foreach ($it in $items) {
        $row = New-Object System.Windows.Controls.Grid
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '*'
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
        [void]$row.ColumnDefinitions.Add($c1); [void]$row.ColumnDefinitions.Add($c2)
        $sp = New-Object System.Windows.Controls.StackPanel
        $imp = if ($null -ne $it.RunningMB) { "running now, about $($it.RunningMB) MB RAM" } else { 'impact not measured' }
        Add-GuiChild $sp (New-GuiText -Text ("{0}   [{1}]" -f $it.Name, $(if ($it.Enabled) { 'Enabled' } else { 'Disabled' })) -Bold -Color $(if ($it.Enabled) { '#3FB950' } else { '#8DA0BF' }))
        Add-GuiChild $sp (New-GuiText -Text ("{0}   |   {1}" -f $it.Source, $imp) -Size 11 -Color '#8DA0BF')
        Add-GuiChild $sp (New-GuiText -Text $it.Command -Size 11 -Color '#6F82A3')
        [void]$row.Children.Add($sp)
        $btns = New-Object System.Windows.Controls.StackPanel
        $btns.Orientation = 'Horizontal'
        [System.Windows.Controls.Grid]::SetColumn($btns, 1)
        $label = if ($it.Enabled) { 'DISABLE' } else { 'ENABLE' }
        Add-GuiChild $btns (New-GuiButton -Text $label -Width 90 -Tag @{ Item = $it; Enable = (-not $it.Enabled) } -OnClick {
            param($s, $e)
            $d = $s.Tag
            $rec = ConvertTo-RecFromTweak -Tweak (New-StartupTweak -Item $d.Item -Enable $d.Enable)
            Invoke-GuiApply -Recs @($rec) -Description 'Startup Manager'
        })
        if ($it.Kind -eq 'Folder') {
            Add-GuiChild $btns (New-GuiButton -Text 'OPEN' -Width 70 -Tag $it -OnClick { param($s, $e) Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $s.Tag.Command + '"') })
        }
        [void]$row.Children.Add($btns)
        $row.Margin = '0,6,0,6'
        Add-GuiChild $Script:GuiContent $row
    }
}

function Show-GuiCleanup {
    Reset-GuiPage -Title 'Cleanup' -Subtitle 'Recovers disk space and removes temporary/stale data. It is not an optimization and does not make games faster. Deleted files cannot be restored.'
    $recs = @(Invoke-GuiWithBusy -Title 'Estimating cleanup sizes' -Detail 'Counting files and checking which are in use...' -Action {
        $out = @()
        $targets = @(Get-CleanupTargets)
        $k = 0
        foreach ($t in $targets) {
            Set-GuiBusy -Text ('Checking ' + $t.Name) -Percent ([int](100 * $k / $targets.Count))
            $k++
            $est = Get-CleanupEstimate -Target $t -DetectLocked
            $rec = ConvertTo-RecFromTweak -Tweak (New-CleanupTweak -Target $t)
            $rec.Current = ('{0}, {1:N0} files{2}' -f (Format-Bytes $est.Bytes), $est.Files, $(if ($est.Locked -gt 0) { ", $($est.Locked) currently locked" } else { '' }))
            $rec.DefaultSelected = $false
            $out += $rec
        }
        return $out
    })
    Show-GuiTweakPage -Title 'Cleanup' -Subtitle 'Recovers disk space and removes temporary/stale data. It is not an optimization. Deleted files cannot be restored.' -Recs $recs -Description 'Cleanup'
    Set-GuiStatus 'Ready.'
}

function Show-GuiNetwork {
    Reset-GuiPage -Title 'Network tools' -Subtitle 'Diagnostics, repair and reset tools. These are not optimizations. Reset operations can temporarily interrupt connectivity.'
    $p = $Script:GuiContent
    Add-GuiChild $p (New-GuiText -Text 'DIAGNOSTICS (read-only)' -Size 12 -Bold -Color '#7C8CFF' -Margin '0,10,0,0')
    $d = New-Object System.Windows.Controls.WrapPanel
    Add-GuiChild $d (New-GuiButton -Text 'IP configuration' -OnClick { Show-GuiTextDialog -Title 'IP configuration' -Text ((Get-NetIPConfiguration | Format-List | Out-String)) })
    Add-GuiChild $d (New-GuiButton -Text 'DNS servers' -OnClick { Show-GuiTextDialog -Title 'DNS servers' -Text ((Get-DnsClientServerAddress | Format-Table -AutoSize | Out-String)) })
    Add-GuiChild $d (New-GuiButton -Text 'Adapters' -OnClick { Show-GuiTextDialog -Title 'Network adapters' -Text ((Get-NetAdapter | Format-Table -AutoSize | Out-String)) })
    Add-GuiChild $d (New-GuiButton -Text 'Ping 1.1.1.1' -OnClick { Set-GuiStatus 'Pinging...'; Show-GuiTextDialog -Title 'Ping' -Text (Invoke-GuiWithBusy -Title 'Pinging 1.1.1.1' -Detail 'Sending 4 test packets...' -Action { Test-Connection -ComputerName 1.1.1.1 -Count 4 | Format-Table -AutoSize | Out-String }); Set-GuiStatus 'Ready.' })
    Add-GuiChild $p $d
    Add-GuiChild $p (New-GuiText -Text 'REPAIR' -Size 12 -Bold -Color '#7C8CFF' -Margin '0,14,0,0')
    Add-GuiChild $p (New-GuiButton -Text 'Flush DNS cache' -Width 180 -OnClick { try { [void](Invoke-NetworkTool -Tool FlushDns); Show-GuiMessage 'DNS cache flushed.' } catch { Show-GuiMessage $_.Exception.Message 'Failed' 'Error' } })
    Add-GuiChild $p (New-GuiText -Text 'RESET (can interrupt connectivity; restart required; not reversible automatically)' -Size 12 -Bold -Color '#F85149' -Margin '0,14,0,0')
    $r = New-Object System.Windows.Controls.WrapPanel
    Add-GuiChild $r (New-GuiButton -Text 'Reset Winsock' -OnClick {
        if (Confirm-Gui "Resets the Winsock catalog.`n`nNetwork connectivity may be interrupted and a restart is required. This is not reversible automatically. Continue?" 'Confirm' 'Warning') {
            try { [void](Invoke-NetworkTool -Tool ResetWinsock); Show-GuiMessage 'Winsock reset. Restart required.' } catch { Show-GuiMessage $_.Exception.Message 'Failed' 'Error' }
        }
    })
    Add-GuiChild $r (New-GuiButton -Text 'Reset TCP/IP' -OnClick {
        if (Confirm-Gui "Resets the TCP/IP stack. Static IP/DNS settings may be lost.`n`nConnectivity may be interrupted and a restart is required. This is not reversible automatically. Continue?" 'Confirm' 'Warning') {
            try { [void](Invoke-NetworkTool -Tool ResetTcpIp); Show-GuiMessage 'TCP/IP reset. Restart required.' } catch { Show-GuiMessage $_.Exception.Message 'Failed' 'Error' }
        }
    })
    Add-GuiChild $p $r
}

function Show-GuiMaintenance {
    Reset-GuiPage -Title 'Windows maintenance' -Subtitle 'Windows maintenance and repair tools - not performance boosters. They open in their own console window and need Administrator.'
    foreach ($c in @(Get-MaintenanceCommands)) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Margin = '0,6,0,6'
        Add-GuiChild $row (New-GuiText -Text ("{0}   [{1}]" -f $c.Name, $c.Category) -Bold)
        Add-GuiChild $row (New-GuiText -Text $c.Note -Size 12 -Color '#8DA0BF')
        Add-GuiChild $row (New-GuiButton -Text 'RUN' -Width 90 -Tag $c -OnClick {
            param($s, $e)
            $cmd = $s.Tag
            if (-not (Test-Administrator)) {
                if (Confirm-Gui 'DISM and SFC require Administrator. Relaunch DIVoptimizer as Administrator?') { if (Request-Elevation -Why 'DISM and SFC require Administrator' -Silent) { $Script:GuiWindow.Close() } }
                return
            }
            $warn = @(Get-LaptopWarnings -Scan $Script:LastScan -Operation $cmd.Name)
            $msg = "$($cmd.Name)`n$($cmd.Note)`n"
            if ($warn.Count -gt 0) { $msg += "`n" + ($warn -join "`n") + "`n" }
            if (-not (Confirm-Gui ($msg + "`nRun it now?") 'Confirm' 'Question')) { return }
            Write-Log -Level INFO -Action 'MAINTENANCE' -Target $cmd.Name -Result 'LAUNCHED (separate window)'
            Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', ($cmd.Exe + ' ' + (@($cmd.Args) -join ' ')))
        })
        Add-GuiChild $Script:GuiContent $row
    }
}

function Show-GuiBackups {
    Reset-GuiPage -Title 'Backup / restore' -Subtitle ('Backup folder: ' + $Script:BackupsDir)
    $list = @(Get-BackupList)
    $lb = New-Object System.Windows.Controls.ListBox
    $lb.Height = 300
    $lb.Background = (Get-GuiBrush '#131D33'); $lb.Foreground = (Get-GuiBrush '#E8EEF8')
    foreach ($b in $list) {
        $fmt = if ($b.Format -eq 'v2') { 'v0.7' } elseif ($b.Format -eq 'legacy') { 'legacy v0.6' } else { $b.Format }
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = ("{0}    {1}    {2}    {3}" -f $b.Id, $fmt, (Format-Bytes $b.SizeBytes), $b.Description)
        $item.Tag = $b
        [void]$lb.Items.Add($item)
    }
    $Script:GuiBackupList = $lb
    Add-GuiChild $Script:GuiContent $lb
    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = '0,10,0,0'
    Add-GuiChild $bar (New-GuiButton -Text 'CREATE BACKUP' -OnClick {
        if (-not (Confirm-Gui 'Create a backup of the current values of every setting DIVoptimizer manages?')) { return }
        $r = Invoke-GuiWithBusy -Title 'Creating backup' -Detail 'Recording the current value of every setting DIVoptimizer manages...' -Action { New-FullStateBackup }
        if ($r.Check.Ok) { Show-GuiMessage "Backup $($r.Session.Id) created and verified." } else { Show-GuiMessage ('Backup verification problems:' + "`n" + (@($r.Check.Problems) -join "`n")) 'Backup' 'Warning' }
        Show-GuiBackups
    })
    Add-GuiChild $bar (New-GuiButton -Text 'VERIFY' -OnClick {
        $it = $Script:GuiBackupList.SelectedItem
        if (-not $it) { Show-GuiMessage 'Select a backup first.'; return }
        $chk = Test-BackupDir -Dir $it.Tag.Path
        if ($chk.Ok) { Show-GuiMessage 'This backup passed verification.' } else { Show-GuiMessage (@($chk.Problems) -join "`n") 'Verification failed' 'Warning' }
    })
    Add-GuiChild $bar (New-GuiButton -Text 'RESTORE' -Bg '#238636' -OnClick {
        $it = $Script:GuiBackupList.SelectedItem
        if (-not $it) { Show-GuiMessage 'Select a backup first.'; return }
        Invoke-GuiRestore -Backup $it.Tag
    })
    Add-GuiChild $bar (New-GuiButton -Text 'DELETE' -OnClick {
        $it = $Script:GuiBackupList.SelectedItem
        if (-not $it) { Show-GuiMessage 'Select a backup first.'; return }
        $b = $it.Tag
        if (Confirm-Gui ("Permanently delete this backup?`n`nBackup ID: {0}`nBackup date: {1}`nBackup size: {2}" -f $b.Id, $b.Created, (Format-Bytes $b.SizeBytes)) 'Confirm delete' 'Warning') {
            try { Remove-BackupFolder -Dir $b.Path; Show-GuiBackups } catch { Show-GuiMessage $_.Exception.Message 'Failed' 'Error' }
        }
    })
    Add-GuiChild $bar (New-GuiButton -Text 'OPEN FOLDER' -OnClick {
        if (-not (Test-Path -LiteralPath $Script:BackupsDir)) { New-Item -ItemType Directory -Path $Script:BackupsDir -Force | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Script:BackupsDir + '"')
    })
    Add-GuiChild $Script:GuiContent $bar
    $set = Get-DivSettings
    Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Retention (older backups are only deleted after you confirm):' -Margin '0,14,0,2')
    $cmb = New-Object System.Windows.Controls.ComboBox
    $cmb.Width = 120; $cmb.HorizontalAlignment = 'Left'
    foreach ($v in @('5', '10', '20', 'All')) { [void]$cmb.Items.Add($v) }
    $cmb.SelectedItem = [string]$set.BackupRetention
    $cmb.Add_SelectionChanged({
        param($s, $e)
        $st = Get-DivSettings
        $st.BackupRetention = [string]$s.SelectedItem
        Save-DivSettings -Settings $st
        $over = @(Get-BackupsOverRetention)
        if ($over.Count -gt 0) {
            $txt = "These backups exceed your retention setting:`n`n" + ((@($over | ForEach-Object { "{0}   {1}   {2}" -f $_.Id, $_.Created, (Format-Bytes $_.SizeBytes) })) -join "`n") + "`n`nDelete them?"
            if (Confirm-Gui $txt 'Backup retention' 'Warning') { foreach ($b in $over) { try { Remove-BackupFolder -Dir $b.Path } catch { Show-GuiMessage $_.Exception.Message 'Failed' 'Error' } }; Show-GuiBackups }
        }
    })
    Add-GuiChild $Script:GuiContent $cmb
}

function Show-GuiHistory {
    Reset-GuiPage -Title 'History' -Subtitle 'Every applied change set, newest first.'
    $h = @(Get-ChangeHistory)
    if ($h.Count -eq 0) { Add-GuiChild $Script:GuiContent (New-GuiText -Text 'No changes have been applied yet.' -Color '#8DA0BF'); return }
    foreach ($b in $h) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Margin = '0,8,0,8'
        Add-GuiChild $row (New-GuiText -Text $b.Created -Bold)
        Add-GuiChild $row (New-GuiText -Text ("{0}    {1} change(s)    Backup: {2}" -f $(if ($b.Description) { $b.Description } else { 'Changes' }), $b.ChangeCount, $b.Id) -Size 12 -Color '#8DA0BF')
        $bar = New-Object System.Windows.Controls.StackPanel
        $bar.Orientation = 'Horizontal'
        Add-GuiChild $bar (New-GuiButton -Text 'VIEW' -Width 80 -Tag $b -OnClick {
            param($s, $e)
            $arrow = [string][char]0x2192
            $lines = @(foreach ($ch in @($s.Tag.Meta.Changes)) { "[{0}] {1}`r`n    {2} {3} {4}   ({5})" -f $ch.Risk, $ch.Name, $ch.Before, $arrow, $ch.After, $ch.Result })
            Show-GuiTextDialog -Title ('Changes - ' + $s.Tag.Id) -Text ($lines -join "`r`n`r`n")
        })
        Add-GuiChild $bar (New-GuiButton -Text 'RESTORE' -Width 90 -Tag $b -OnClick { param($s, $e) Invoke-GuiRestore -Backup $s.Tag })
        Add-GuiChild $bar (New-GuiButton -Text 'OPEN LOG' -Width 90 -Tag $b -OnClick {
            param($s, $e)
            $lf = Join-Path $Script:LogsDir ([string]$s.Tag.Meta.LogFile)
            if ($s.Tag.Meta.LogFile -and (Test-Path -LiteralPath $lf)) { Show-GuiTextDialog -Title 'Log' -Text ((Read-LogFile -Path $lf) -join "`r`n`r`n") } else { Show-GuiMessage 'The log file for this entry was not found.' }
        })
        Add-GuiChild $row $bar
        Add-GuiChild $Script:GuiContent $row
    }
}

function Show-GuiServices {
    Set-GuiStatus 'Reading services...'
    $scan = Invoke-GuiWithBusy -Title 'Scanning your PC' -Detail 'Reading hardware and settings. This does not change anything.' -Action { Get-SystemScan }
    $recs = @()
    foreach ($e in @($Script:ServiceCatalog)) {
        $info = Get-ServiceInfo -Name $e.Name
        if (-not $info.Exists) { continue }
        $r = ConvertTo-RecFromTweak -Tweak (New-ServiceTweak -Entry $e -Target 'Disabled')
        if ($e.Guard -eq 'Touch' -and $scan.Hardware.Touch) { $r.Selectable = $false; $r.Blocked = 'Touchscreen detected.' }
        if ($r.Current -match '^Disabled') { $r.Applied = $true; $r.Selectable = $false }
        $r.Why = ("{0}  Recommendation: {1}" -f $e.Why, $e.Guidance)
        $recs += $r
    }
    Show-GuiTweakPage -Title 'Service manager' -Subtitle 'Nothing here is recommended automatically. Each service lists what it does and the risk.' -Recs $recs -Description 'Service Manager'
    Set-GuiStatus 'Ready.'
}

function Show-GuiAdvanced {
    Reset-GuiPage -Title 'Advanced tools' -Subtitle 'Potentially disruptive. Each tool shows a full preview and needs explicit confirmation.'
    $p = $Script:GuiContent
    $w = New-Object System.Windows.Controls.WrapPanel
    Add-GuiChild $w (New-GuiButton -Text 'Service Manager' -OnClick { Show-GuiServices })
    Add-GuiChild $w (New-GuiButton -Text 'Registry tweaks' -OnClick { $r = @(Get-Recommendations -Scan $Script:LastScan -All | Where-Object { $_.Id -eq 'delivery-opt-off' }); Show-GuiTweakPage -Title 'Registry tweaks' -Subtitle 'Windows Update delivery' -Recs $r -Description 'Registry tweak' })
    Add-GuiChild $w (New-GuiButton -Text 'Scheduled tasks' -OnClick { $r = @(Get-Recommendations -Scan $Script:LastScan -All | Where-Object { $_.Id -eq 'tasks-telemetry' }); Show-GuiTweakPage -Title 'Scheduled tasks' -Subtitle 'Telemetry-related tasks' -Recs $r -Description 'Scheduled tasks' })
    Add-GuiChild $w (New-GuiButton -Text 'Hibernation' -OnClick { $r = @(Get-Recommendations -Scan $Script:LastScan -All | Where-Object { $_.Id -eq 'hibernate-off' }); Show-GuiTweakPage -Title 'Hibernation' -Subtitle 'Also turns off Fast Startup. The previous state is backed up and restored.' -Recs $r -Description 'Hibernation' })
    Add-GuiChild $w (New-GuiButton -Text 'Temporary Working-Set Trim' -OnClick {
        $r = @(Get-Recommendations -Scan $Script:LastScan -All | Where-Object { $_.Id -eq 'trim-workingset' })
        Show-GuiTweakPage -Title 'Temporary Working-Set Trim' -Subtitle 'This does not create additional physical RAM. Windows may reload memory when applications need it. Intended for temporary memory pressure or troubleshooting.' -Recs $r -Description 'Working-set trim'
    })
    Add-GuiChild $w (New-GuiButton -Text 'Optional apps' -OnClick { Show-GuiOptionalApps })
    Add-GuiChild $w (New-GuiButton -Text 'Network tools' -OnClick { Show-GuiNetwork })
    Add-GuiChild $p $w
    Add-GuiChild $p (New-GuiText -Text 'POWER PLAN' -Size 12 -Bold -Color '#7C8CFF' -Margin '0,16,0,0')
    Add-GuiChild $p (New-GuiText -Text 'High-performance plans may increase power consumption, heat and fan noise, and may reduce battery life on laptops. They do not automatically improve FPS.' -Size 12 -Color '#D29922')
    $pw = New-Object System.Windows.Controls.WrapPanel
    foreach ($k in @('Balanced', 'Performance', 'Maximum')) {
        Add-GuiChild $pw (New-GuiButton -Text $Script:PlanLabels[$k] -Tag $k -OnClick {
            param($s, $e)
            $rec = ConvertTo-RecFromTweak -Tweak (New-PowerPlanTweak -Key $s.Tag)
            Invoke-GuiApply -Recs @($rec) -Description 'Power plan'
        })
    }
    Add-GuiChild $p $pw
    Add-GuiChild $p (New-GuiText -Text 'BENCHMARK (measured values only)' -Size 12 -Bold -Color '#7C8CFF' -Margin '0,16,0,0')
    $bw = New-Object System.Windows.Controls.WrapPanel
    Add-GuiChild $bw (New-GuiButton -Text 'Capture snapshot' -OnClick {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $n = [Microsoft.VisualBasic.Interaction]::InputBox('Snapshot name (letters, digits, - _), for example: before', 'Benchmark', 'before')
        if (-not $n) { return }
        try { $snap = Invoke-GuiWithBusy -Title 'Benchmark' -Detail 'Taking 5 samples (about 5 seconds). Do not use the PC meanwhile.' -Action { New-BenchSnapshot -Label $n }; $path = Save-BenchSnapshot -Snapshot $snap -Name $n; Show-GuiMessage "Saved $path"; Set-GuiStatus 'Ready.' } catch { Show-GuiMessage $_.Exception.Message 'Failed' 'Error' }
    })
    Add-GuiChild $bw (New-GuiButton -Text 'Compare last two' -OnClick {
        $s = @(Get-BenchSnapshots)
        if ($s.Count -lt 2) { Show-GuiMessage 'Capture at least two snapshots first.'; return }
        $rows = @(Compare-BenchSnapshots -Before (Read-JsonFile -Path $s[1].FullName) -After (Read-JsonFile -Path $s[0].FullName))
        $txt = ("BEFORE: {0}   AFTER: {1}`r`n`r`n" -f $s[1].BaseName, $s[0].BaseName) + (($rows | ForEach-Object { '{0,-34} {1,-14} {2,-14} {3}' -f $_.Metric, $_.Before, $_.After, $_.Change }) -join "`r`n")
        Show-GuiTextDialog -Title 'Benchmark comparison' -Text $txt
    })
    Add-GuiChild $p $bw
}

function Show-GuiResources {
    Reset-GuiPage -Title 'Resource monitor' -Subtitle 'Read-only. Click a column header to sort. DIVoptimizer never ends processes.'
    $snap = Invoke-GuiWithBusy -Title 'Sampling resources' -Detail 'Measuring CPU, memory, disk and network for one second...' -Action { Get-ResourceSnapshot }
    Add-GuiChild $Script:GuiContent (New-GuiText -Text ("CPU {0}%     RAM {1}% ({2} of {3} GB)     Disk {4} GB free, busy {5}     Network down {6} KB/s, up {7} KB/s" -f $snap.CpuPct, $snap.RamPct, $snap.RamUsedGB, $snap.RamTotalGB, $snap.DiskFreeGB, $(if ($null -ne $snap.DiskBusyPct) { "$($snap.DiskBusyPct)%" } else { 'n/a' }), $snap.NetRxKBs, $snap.NetTxKBs) -Size 14)
    $grid = New-Object System.Windows.Controls.DataGrid
    $grid.Height = 440; $grid.IsReadOnly = $true; $grid.AutoGenerateColumns = $true; $grid.CanUserSortColumns = $true
    $grid.Background = (Get-GuiBrush '#131D33'); $grid.Foreground = (Get-GuiBrush '#E8EEF8'); $grid.RowBackground = (Get-GuiBrush '#131D33')
    $grid.AlternatingRowBackground = (Get-GuiBrush '#172138'); $grid.GridLinesVisibility = 'None'
    $grid.ItemsSource = [object[]]@($snap.Processes | Sort-Object RamMB -Descending)
    Add-GuiChild $Script:GuiContent $grid
    Add-GuiChild $Script:GuiContent (New-GuiButton -Text 'REFRESH' -Width 110 -OnClick { Show-GuiResources })
    Set-GuiStatus 'Ready.'
}

function Show-GuiReportAbout {
    Reset-GuiPage -Title 'Reports, updates and about'
    $p = $Script:GuiContent
    Add-GuiChild $p (New-GuiText -Text 'EXPORT SYSTEM REPORT' -Size 12 -Bold -Color '#7C8CFF' -Margin '0,6,0,0')
    Add-GuiChild $p (New-GuiText -Text 'Contains no user name, computer name, serial numbers, file paths or startup command lines.' -Size 12 -Color '#8DA0BF')
    $bar = New-Object System.Windows.Controls.WrapPanel
    foreach ($f in @('txt', 'json')) {
        Add-GuiChild $bar (New-GuiButton -Text ('Export ' + $f.ToUpper()) -Tag $f -OnClick {
            param($s, $e)
            $fmt = [string]$s.Tag
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.FileName = ("DIVoptimizer-Report-{0}.{1}" -f (Get-Date -Format 'yyyy-MM-dd'), $fmt)
            $dlg.Filter = ("{0} file|*.{1}" -f $fmt.ToUpper(), $fmt)
            if ($dlg.ShowDialog() -eq $true) {
                try { Export-SystemReport -Scan (Invoke-GuiWithBusy -Title 'Preparing report' -Action { Get-SystemScan }) -Path $dlg.FileName -Format $fmt; Show-GuiMessage "Report saved:`n$($dlg.FileName)" } catch { Show-GuiMessage $_.Exception.Message 'Failed' 'Error' }
            }
        })
    }
    Add-GuiChild $p $bar
    Add-GuiChild $p (New-GuiText -Text 'UPDATES' -Size 12 -Bold -Color '#7C8CFF' -Margin '0,18,0,0')
    Add-GuiChild $p (New-GuiText -Text 'Nothing is downloaded or run unless you ask, and nothing is installed automatically.' -Size 12 -Color '#8DA0BF')
    Add-GuiChild $p (New-GuiButton -Text 'Check for updates' -Width 160 -OnClick {
        try {
            $u = Invoke-GuiWithBusy -Title 'Checking for updates' -Detail 'Contacting the update source over HTTPS...' -Action { Get-UpdateInfo }
            $txt = "Current: v$($u.Current)`nLatest: v$($u.Latest)`n`nRelease notes:`n$($u.Notes)`n`nDownload source:`n$($u.Url)`n`nSHA-256:`n$($u.Sha256)"
            if ($u.Newer) {
                if (Confirm-Gui ($txt + "`n`nDownload to a staging folder and verify the SHA-256? It will NOT be installed or run.") 'Update available') {
                    $r = Invoke-GuiWithBusy -Title 'Downloading update' -Detail 'Downloading and verifying the SHA-256. Nothing is installed.' -Action { Save-UpdatePackage -Info $u }
                    Show-GuiMessage ("SHA-256 verified.`nSignature status: $($r.Signature)`n`nPackage: $($r.Zip)`nExtracted to: $($r.Folder)`n`nReview it and run the new DIVoptimizer.ps1 yourself.")
                }
            } else { Show-GuiMessage ($txt + "`n`nYou are on the latest version.") 'Up to date' }
        } catch { Show-GuiMessage ('Could not check for updates: ' + $_.Exception.Message) 'Update check' 'Warning' }
        Set-GuiStatus 'Ready.'
    })
    Add-GuiChild $p (New-GuiText -Text 'ABOUT' -Size 12 -Bold -Color '#7C8CFF' -Margin '0,18,0,0')
    Add-GuiChild $p (New-GuiText -Text "$($Script:AppName) v$($Script:Version)  by $($Script:Author)")
    Add-GuiChild $p (New-GuiText -Text ('Backups: ' + $Script:BackupsDir) -Size 12 -Color '#8DA0BF')
    Add-GuiChild $p (New-GuiText -Text ('Logs: ' + $Script:LogsDir) -Size 12 -Color '#8DA0BF')
    Add-GuiChild $p (New-GuiText -Text 'DIVoptimizer does not guarantee FPS increases, lower latency, lower temperatures, or faster Windows performance. Windows performance depends on hardware, drivers, applications, configuration, thermals, and workload. DIVoptimizer therefore focuses on transparent configuration changes, maintenance, cleanup, and user-controlled optimization rather than guaranteed performance claims.' -Size 12 -Color '#8DA0BF' -Margin '0,10,0,0')
}

function Update-GuiSysLine {
    $s = $Script:LastScan
    if (-not $s) { return }
    $Script:GuiSysLine.Text = ("{0}  |  {1}  |  {2} GB  |  {3}  |  {4}" -f $s.Windows.Caption, $s.Hardware.DeviceType, $s.Hardware.RamGB, $s.Hardware.SystemDriveType, $(if ($s.IsAdmin) { 'Administrator' } else { 'Standard user' }))
}

function New-GuiNavButton {
    param([string]$Text, [scriptblock]$OnClick, [string]$Bg = '')
    return (New-GuiButton -Text $Text -Width 200 -OnClick $OnClick -Bg $Bg)
}

# ---------------------------------------------------------------
# DIVuninstaller: uninstall a program, then find and quarantine what it leaves behind.
# Rules: the program's OWN uninstaller does the uninstall; leftovers are matched by exact name only;
# nothing is pre-selected; folders are MOVED to a quarantine folder (not deleted) and registry keys are
# exported first, so every cleanup can be undone until the quarantine is emptied.
# ---------------------------------------------------------------

$Script:QuarantineDir   = Join-Path $Script:DataRoot 'Quarantine'
$Script:UninstalledDir  = Join-Path $Script:DataRoot 'Uninstalled'
$Script:ExcludeFile     = Join-Path $Script:DataRoot 'uninstaller-exclude.json'
$Script:UninstallerSettingsFile = Join-Path $Script:DataRoot 'uninstaller-settings.json'

$Script:UninstallKeyRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
)

# Programs this tool will not uninstall (system, runtimes, drivers, security). Use Windows Settings > Apps for those.
$Script:ProtectedProgramPatterns = @(
    '^Microsoft Visual C\+\+', '^Microsoft \.NET', '^Microsoft Windows', '^Windows ', '^Microsoft Edge', '^Microsoft Update Health',
    'WebView2', '^Microsoft GameInput', '^Microsoft Store', 'DirectX', 'Defender', 'Security Health',
    'Driver', 'Chipset', 'Management Engine', '^NVIDIA (Graphics|HD Audio|PhysX|Control)', '^Realtek', '^AMD (Software|Chipset|Radeon)', '^Intel\(R\)',
    '^(KB\d+|Update for |Security Update|Hotfix)'
)

# Folder and registry names that are never offered as leftovers, whatever the program is called.
$Script:ProtectedLeafNames = @(
    'microsoft', 'windows', 'windows nt', 'windowsapps', 'common files', 'microsoft shared', 'packages', 'temp', 'programs',
    'classes', 'policies', 'system32', 'syswow64', 'drivers', 'program files', 'program files (x86)', 'programdata', 'users', 'appdata',
    'local', 'locallow', 'roaming', 'software', 'wow6432node', 'run', 'currentversion', 'uninstall', 'internet explorer', 'windows defender'
)

function Test-ProgramProtected {
    param([string]$Name, [string]$Publisher = '')
    foreach ($pat in $Script:ProtectedProgramPatterns) { if ($Name -match $pat) { return $true } }
    return $false
}

function ConvertTo-RegExePath {
    # HKCU:\Software\X  ->  HKCU\Software\X   (the form reg.exe expects)
    param([string]$Path)
    $p = $Path -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^Registry::', ''
    $p = $p -replace '^HKEY_LOCAL_MACHINE', 'HKLM' -replace '^HKEY_CURRENT_USER', 'HKCU'
    $p = $p -replace '^(HKLM|HKCU):', '$1'
    return $p
}

function ConvertTo-SafeFileName {
    param([string]$Text)
    $t = ($Text -replace '[^A-Za-z0-9_\-\.]+', '_').Trim('_')
    if ($t.Length -gt 40) { $t = $t.Substring(0, 40) }
    if (-not $t) { $t = 'item' }
    return $t
}

function Get-InstalledPrograms {
    param([string[]]$Keys = $Script:UninstallKeyRoots)
    $list = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($root in $Keys) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop
                $name = [string]$p.DisplayName
                if (-not $name) { continue }
                if ($p.SystemComponent -eq 1) { continue }
                if ($p.ParentKeyName -or $p.ParentDisplayName) { continue }
                $uninst = [string]$p.UninstallString
                $quiet = [string]$p.QuietUninstallString
                if (-not $uninst -and -not $quiet) { continue }
                $ver = [string]$p.DisplayVersion
                $dedupe = ($name + '|' + $ver).ToLower()
                if ($seen.ContainsKey($dedupe)) { continue }
                $seen[$dedupe] = $true
                $pub = [string]$p.Publisher
                $size = [long]0
                if ($p.EstimatedSize) { $size = [long]$p.EstimatedSize }
                $loc = ([string]$p.InstallLocation).Trim().Trim('"')
                $list.Add([pscustomobject]@{
                    Name = $name; Publisher = $pub; Version = $ver; InstallDate = [string]$p.InstallDate
                    InstallLocation = $loc; UninstallString = $uninst; QuietUninstallString = $quiet
                    SizeKB = $size; KeyName = [string]$k.PSChildName; KeyPath = [string]$k.Name
                    Scope = $(if ($k.Name -like 'HKEY_CURRENT_USER*') { 'User' } else { 'Machine' })
                    Protected = (Test-ProgramProtected -Name $name -Publisher $pub)
                })
            } catch {
                Write-Log -Level WARN -Action 'PROGRAM_LIST' -Target ([string]$k.Name) -ErrorText $_.Exception.Message
            }
        }
    }
    return @($list.ToArray() | Sort-Object -Property Name)
}

function Split-UninstallCommand {
    # Turns an UninstallString into a file and arguments. Returns $null when it cannot be done safely.
    param([string]$Text)
    $t = ([string]$Text).Trim()
    if (-not $t) { return $null }
    $file = ''
    $argText = ''
    if ($t.StartsWith('"')) {
        $end = $t.IndexOf('"', 1)
        if ($end -lt 2) { return $null }
        $file = $t.Substring(1, $end - 1)
        $argText = $t.Substring($end + 1).Trim()
    } elseif ($t -match '^(?i)msiexec(\.exe)?(\s+(.*))?$') {
        $file = 'msiexec.exe'
        $argText = [string]$Matches[3]
    } elseif ($t -match '^(?i)(.+?\.(exe|bat|cmd|com))(\s+(.*))?$') {
        $file = [string]$Matches[1]
        $argText = [string]$Matches[4]
    } else { return $null }
    if ($file -match '[\*\?\|<>]') { return $null }
    $isMsi = ($file -match '(?i)(^|[\\/])msiexec(\.exe)?$')
    if ($isMsi) {
        # Always ask Windows Installer to UNINSTALL the product code, even if the string says /I.
        $guid = ''
        if ($argText -match '(\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\})') { $guid = [string]$Matches[1] }
        if (-not $guid) { return $null }
        return [pscustomobject]@{ File = 'msiexec.exe'; Arguments = ('/x ' + $guid); IsMsi = $true }
    }
    if ($file -notmatch '^([A-Za-z]:[\\/]|\\\\)') { return $null }
    return [pscustomobject]@{ File = $file; Arguments = $argText; IsMsi = $false }
}

function Test-ProgramStillInstalled {
    param($Program)
    if (-not $Program.KeyPath) { return $false }
    return (Test-Path -LiteralPath ('Registry::' + $Program.KeyPath))
}

function Format-ProgramInstallDate {
    param([string]$Raw)
    if ($Raw -match '^(\d{4})(\d{2})(\d{2})$') { return ('{0}-{1}-{2}' -f $Matches[1], $Matches[2], $Matches[3]) }
    if ($Raw) { return $Raw }
    return 'unknown'
}

function Get-ProgramDetailsText {
    param($Program)
    if (-not $Program) { return '' }
    $sz = 'unknown'
    if ($Program.SizeKB -gt 0) { $sz = Format-Bytes ([double]$Program.SizeKB * 1024) }
    $loc = $Program.InstallLocation
    if (-not $loc) { $loc = 'not recorded' }
    $prot = ''
    if ($Program.Protected) { $prot = "`nProtected: cannot be uninstalled here (system, runtime, driver or security software)." }
    return ("{0}  {1}`nPublisher: {2}    Installed: {3}    Size: {4}`nLocation: {5}`nUninstall entry: {6}{7}" -f $Program.Name, $Program.Version, $(if ($Program.Publisher) { $Program.Publisher } else { 'unknown' }), (Format-ProgramInstallDate -Raw $Program.InstallDate), $sz, $loc, $Program.KeyPath, $prot)
}

function Get-ScanModeDescription {
    param([string]$Mode)
    switch ($Mode) {
        'None'     { return "Built-in: runs the program's own uninstaller only. No leftover scan." }
        'Safe'     { return 'Safe: the install folder, plus folders and registry keys with the program''s exact name under Program Files, ProgramData and Software.' }
        'Advanced' { return 'Advanced: everything in Moderate, plus Start Menu and Desktop shortcuts, App Paths entries, the program''s own uninstall entry, and an empty publisher folder.' }
        default    { return 'Moderate: everything in Safe, plus AppData folders and startup entries that point into the install folder.' }
    }
}

function Update-UninstallRecord {
    # Adds the outcome (mode, exit code, leftovers) to the record written when the uninstall started.
    param([string]$Dir, [hashtable]$Values)
    if ($Script:DryRun -or -not $Dir) { return }
    $path = Join-Path $Dir 'program.json'
    try {
        $o = [ordered]@{}
        if (Test-Path -LiteralPath $path) {
            $cur = Read-JsonFile -Path $path
            foreach ($pr in $cur.PSObject.Properties) { $o[$pr.Name] = $pr.Value }
        }
        foreach ($k in $Values.Keys) { $o[$k] = $Values[$k] }
        Write-JsonFile -Path $path -Object $o
    } catch { Write-Log -Level WARN -Action 'UNINSTALL_RECORD' -Target $Dir -ErrorText $_.Exception.Message }
}

function Get-UninstallHistory {
    param([string]$Root = $Script:UninstalledDir)
    $out = @()
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        $pj = Join-Path $d.FullName 'program.json'
        if (-not (Test-Path -LiteralPath $pj)) { continue }
        try {
            $r = Read-JsonFile -Path $pj
            $out += [pscustomobject]@{
                Id = $d.Name; Path = $d.FullName; Name = [string]$r.Name; Version = [string]$r.Version; Started = [string]$r.Started
                Mode = [string]$r.Mode; ExitCode = [string]$r.ExitCode; Forced = [bool]$r.Forced
                LeftoversFound = [string]$r.LeftoversFound; LeftoversMoved = [string]$r.LeftoversMoved; Quarantine = [string]$r.Quarantine
            }
        } catch { Write-Log -Level WARN -Action 'UNINSTALL_HISTORY' -Target $d.FullName -ErrorText $_.Exception.Message }
    }
    return @($out | Sort-Object Id -Descending)
}

function Invoke-ProgramUninstall {
    # Runs the program's own uninstaller after a restore point and a backup of its uninstall key.
    # -SkipUninstaller is the FORCED mode: nothing is run, the caller scans for what is left (broken or missing uninstaller).
    param($Program, [switch]$SkipRestorePoint, [switch]$SkipUninstaller)
    if ($Program.Protected) { throw "$($Program.Name) is a protected program. Use Windows Settings > Apps if you really want to remove it." }
    $cmd = $null
    if (-not $SkipUninstaller) {
        $cmd = Split-UninstallCommand -Text $Program.UninstallString
        if (-not $cmd) { throw "The uninstall command for $($Program.Name) could not be read safely, so it was not run." }
        if (-not $cmd.IsMsi -and -not (Test-Path -LiteralPath $cmd.File)) { throw "The uninstaller was not found: $($cmd.File). If it is missing, use Forced uninstall." }
    }
    if ($Script:DryRun) {
        if ($cmd) { Write-Tag INFO ("[DRY RUN] would run: {0} {1}" -f $cmd.File, $cmd.Arguments) } else { Write-Tag INFO ("[DRY RUN] would run a forced removal scan for {0} (no uninstaller)" -f $Program.Name) }
        return [pscustomobject]@{ Ran = $false; ExitCode = $null; BackupDir = ''; RestorePoint = 'Skipped'; StillInstalled = $true; Forced = [bool]$SkipUninstaller }
    }
    $stamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
    $dir = Join-Path $Script:UninstalledDir ('{0}-{1}' -f $stamp, (ConvertTo-SafeFileName -Text $Program.Name))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $rp = 'Skipped'
    if (-not $SkipRestorePoint) {
        $r = New-DivRestorePoint -Description ('DIVuninstaller - ' + $Program.Name)
        $rp = $r.Status
        if ($r.Message) { Write-Tag WARN ('Restore point: ' + $r.Message) }
    }
    $regFile = Join-Path $dir 'uninstall-key.reg'
    if ($Program.KeyPath) {
        $regPath = ConvertTo-RegExePath -Path $Program.KeyPath
        Write-Command ('reg.exe export "{0}" "{1}" /y' -f $regPath, $regFile)
        $out = & reg.exe export $regPath $regFile /y 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Tag WARN ('Could not back up the program entry: ' + (($out | Out-String).Trim())) }
    } else {
        Write-Tag INFO 'This program has no uninstall entry, so there is no registry entry to back up.'
    }
    if ((Get-UninstallerSettings).ForceStopExecutables) {
        $stopped = Stop-ProgramProcesses -Program $Program
        if ($stopped -gt 0) { Write-Tag INFO ("Stopped {0} running program(s) from the install folder." -f $stopped) }
    }
    Write-JsonFile -Path (Join-Path $dir 'program.json') -Object ([ordered]@{
        Name = $Program.Name; Publisher = $Program.Publisher; Version = $Program.Version; InstallLocation = $Program.InstallLocation
        UninstallString = $Program.UninstallString; KeyPath = $Program.KeyPath; Started = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Forced = [bool]$SkipUninstaller; RestorePoint = $rp
    })
    if ($SkipUninstaller) {
        Write-Log -Level INFO -Action 'FORCED_UNINSTALL' -Target $Program.Name -Message 'uninstaller skipped; leftover scan only'
        Write-Tag INFO 'Forced uninstall: the program''s own uninstaller is NOT run.'
        return [pscustomobject]@{ Ran = $false; ExitCode = $null; BackupDir = $dir; RestorePoint = $rp; StillInstalled = (Test-ProgramStillInstalled -Program $Program); Forced = $true }
    }
    Write-Log -Level INFO -Action 'UNINSTALL_START' -Target $Program.Name -Message ($cmd.File + ' ' + $cmd.Arguments)
    $splat = @{ FilePath = $cmd.File; Wait = $true; PassThru = $true; ErrorAction = 'Stop' }
    if ($cmd.Arguments) { $splat['ArgumentList'] = $cmd.Arguments }
    Write-Command ("Start-Process -FilePath '{0}'{1} -Wait" -f $cmd.File, $(if ($cmd.Arguments) { " -ArgumentList '" + $cmd.Arguments + "'" } else { '' }))
    $proc = Start-Process @splat
    $code = $proc.ExitCode
    $still = Test-ProgramStillInstalled -Program $Program
    Write-Log -Level $(if ($still) { 'WARN' } else { 'INFO' }) -Action 'UNINSTALL_DONE' -Target $Program.Name -Result ([string]$code) -Message $(if ($still) { 'still listed as installed' } else { 'no longer listed' })
    Update-UninstallRecord -Dir $dir -Values @{ ExitCode = $code }
    return [pscustomobject]@{ Ran = $true; ExitCode = $code; BackupDir = $dir; RestorePoint = $rp; StillInstalled = $still; Forced = $false }
}

function Get-DefaultFolderRoots {
    $r = @()
    $cands = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)
    if ($env:LOCALAPPDATA) { $cands += $env:LOCALAPPDATA; $cands += (Join-Path $env:LOCALAPPDATA 'Programs') }
    if ($env:APPDATA) { $cands += $env:APPDATA }
    foreach ($x in $cands) { if ($x -and ($r -notcontains $x)) { $r += $x } }
    return @($r)
}

function Get-DefaultShortcutRoots {
    $r = @()
    foreach ($sf in @('CommonPrograms', 'Programs', 'CommonDesktopDirectory', 'DesktopDirectory')) {
        try { $p = [Environment]::GetFolderPath($sf); if ($p -and ($r -notcontains $p)) { $r += $p } } catch { }
    }
    return @($r)
}

function Test-FolderHasNoFiles {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    return (@(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue).Count -eq 0)
}

function Get-ProgramLeftovers {
    # Exact-name matches only. Returns candidate items; the caller decides what to move. Nothing is changed here.
    # Mode: Safe < Moderate < Advanced (each includes the one before it).
    param(
        $Program,
        $OtherPrograms = @(),
        [ValidateSet('Safe', 'Moderate', 'Advanced')][string]$Mode = 'Moderate',
        [string[]]$FolderRoots = $null,
        [string[]]$SafeFolderRoots = $null,
        [string[]]$RegistryRoots = @('HKCU:\Software', 'HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node'),
        [string[]]$RunKeys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'),
        [string[]]$ShortcutRoots = $null,
        [string[]]$AppPathsKeys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths')
    )
    if ($null -eq $FolderRoots) { $FolderRoots = Get-DefaultFolderRoots }
    if ($null -eq $SafeFolderRoots) {
        $SafeFolderRoots = @($FolderRoots | Where-Object {
            ((-not $env:APPDATA) -or ($_ -notlike ($env:APPDATA + '*'))) -and ((-not $env:LOCALAPPDATA) -or ($_ -notlike ($env:LOCALAPPDATA + '*')))
        })
    }
    if ($null -eq $ShortcutRoots) { $ShortcutRoots = Get-DefaultShortcutRoots }
    $useRoots = $SafeFolderRoots
    if ($Mode -ne 'Safe') { $useRoots = $FolderRoots }

    $items = New-Object System.Collections.Generic.List[object]
    $seenPaths = @{}
    $names = @(Get-LeftoverNames -Program $Program)

    $add = {
        param($Type, $Path, $Name, $Detail, $Bytes, $Risk)
        $key = ($Type + '|' + $Path + '|' + $Name).ToLower()
        if ($seenPaths.ContainsKey($key)) { return }
        $seenPaths[$key] = $true
        $items.Add([pscustomobject]@{ Type = $Type; Path = $Path; Name = $Name; Detail = $Detail; SizeBytes = [long]$Bytes; Risk = $Risk })
    }

    # 1. The recorded install folder, if it is still there.
    if ($Program.InstallLocation -and (Test-Path -LiteralPath $Program.InstallLocation -PathType Container) -and (Test-LeftoverPathAllowed -Path $Program.InstallLocation -OtherPrograms $OtherPrograms)) {
        $st = Get-FolderStats -Path $Program.InstallLocation
        & $add 'Folder' $Program.InstallLocation '' 'Install folder' $st.Bytes 'CHECK'
    }
    # 2. Folders named exactly like the program under the usual places.
    foreach ($root in $useRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($n in $names) {
            $cand = Join-Path $root $n
            if ((Test-Path -LiteralPath $cand -PathType Container) -and (Test-LeftoverPathAllowed -Path $cand -OtherPrograms $OtherPrograms)) {
                $st = Get-FolderStats -Path $cand
                & $add 'Folder' $cand '' ('Folder under ' + $root) $st.Bytes 'LOW'
            }
            if ($Program.Publisher) {
                $cand2 = Join-Path (Join-Path $root $Program.Publisher) $n
                if ((Test-Path -LiteralPath $cand2 -PathType Container) -and (Test-LeftoverPathAllowed -Path $cand2 -OtherPrograms $OtherPrograms)) {
                    $st = Get-FolderStats -Path $cand2
                    & $add 'Folder' $cand2 '' ('Folder under ' + $root) $st.Bytes 'LOW'
                }
            }
        }
    }
    # 3. Registry keys named exactly like the program (or Publisher\Program).
    foreach ($root in $RegistryRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($n in $names) {
            $cand = Join-Path $root $n
            if (Test-Path -LiteralPath $cand) {
                $risk = 'CHECK'; if ($root -like 'HKCU*') { $risk = 'LOW' }
                & $add 'RegistryKey' $cand '' ('Settings key under ' + $root) 0 $risk
            }
            if ($Program.Publisher) {
                $cand2 = Join-Path (Join-Path $root $Program.Publisher) $n
                if (Test-Path -LiteralPath $cand2) {
                    $risk = 'CHECK'; if ($root -like 'HKCU*') { $risk = 'LOW' }
                    & $add 'RegistryKey' $cand2 '' ('Settings key under ' + $root) 0 $risk
                }
            }
        }
    }
    # 4. Moderate and Advanced: startup (Run) entries that point into the install folder.
    if ($Mode -ne 'Safe' -and $Program.InstallLocation -and $Program.InstallLocation.Length -ge 6) {
        foreach ($rk in $RunKeys) {
            if (-not (Test-Path -LiteralPath $rk)) { continue }
            $props = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
            if (-not $props) { continue }
            foreach ($pr in @($props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
                if (([string]$pr.Value).IndexOf($Program.InstallLocation, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    & $add 'RunValue' $rk $pr.Name ('Starts with Windows: ' + [string]$pr.Value) 0 'LOW'
                }
            }
        }
    }
    # 5. Advanced only.
    if ($Mode -eq 'Advanced') {
        # Start Menu / Desktop: a folder named exactly like the program, or a shortcut named like it or pointing into the install folder.
        foreach ($sr in $ShortcutRoots) {
            if (-not (Test-Path -LiteralPath $sr)) { continue }
            foreach ($n in $names) {
                $folder = Join-Path $sr $n
                if ((Test-Path -LiteralPath $folder -PathType Container) -and (Test-LeftoverPathAllowed -Path $folder -OtherPrograms $OtherPrograms)) {
                    & $add 'Folder' $folder '' 'Start Menu folder' 0 'LOW'
                }
                $lnk = Join-Path $sr ($n + '.lnk')
                if (Test-Path -LiteralPath $lnk -PathType Leaf) { & $add 'File' $lnk '' 'Shortcut' 0 'LOW' }
            }
            if ($Program.InstallLocation -and $Program.InstallLocation.Length -ge 6) {
                $sh = $null
                try { $sh = New-Object -ComObject WScript.Shell } catch { $sh = $null }
                if ($sh) {
                    foreach ($f in @(Get-ChildItem -LiteralPath $sr -Filter '*.lnk' -File -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -First 3000)) {
                        try {
                            $target = [string]$sh.CreateShortcut($f.FullName).TargetPath
                            if ($target -and $target.StartsWith($Program.InstallLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
                                & $add 'File' $f.FullName '' ('Shortcut to ' + $target) 0 'LOW'
                            }
                        } catch { }
                    }
                }
            }
        }
        # App Paths entries that point into the install folder.
        if ($Program.InstallLocation -and $Program.InstallLocation.Length -ge 6) {
            foreach ($ak in $AppPathsKeys) {
                if (-not (Test-Path -LiteralPath $ak)) { continue }
                foreach ($c in @(Get-ChildItem -LiteralPath $ak -ErrorAction SilentlyContinue)) {
                    try {
                        $pp = Get-ItemProperty -LiteralPath $c.PSPath -ErrorAction Stop
                        $def = [string]$pp.'(default)'
                        $pth = [string]$pp.Path
                        if (($def -and $def.IndexOf($Program.InstallLocation, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or ($pth -and $pth.IndexOf($Program.InstallLocation, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                            & $add 'RegistryKey' ('Registry::' + $c.Name) '' 'App Paths entry' 0 'CHECK'
                        }
                    } catch { }
                }
            }
        }
        # The program's own uninstall entry, if it is still registered (broken uninstaller / forced removal).
        if ($Program.KeyPath -and (Test-Path -LiteralPath ('Registry::' + $Program.KeyPath))) {
            & $add 'RegistryKey' ('Registry::' + $Program.KeyPath) '' 'The program''s own uninstall entry' 0 'CHECK'
        }
        # Publisher folder, only when nothing is left in it once the items above are gone.
        if ($Program.Publisher) {
            foreach ($root in $useRoots) {
                $pub = Join-Path $root $Program.Publisher
                if (-not (Test-Path -LiteralPath $pub -PathType Container)) { continue }
                if (-not (Test-LeftoverPathAllowed -Path $pub -OtherPrograms $OtherPrograms)) { continue }
                $inside = @($items.ToArray() | Where-Object { $_.Type -eq 'Folder' -and $_.Path.StartsWith($pub, [System.StringComparison]::OrdinalIgnoreCase) }).Count
                $files = @(Get-ChildItem -LiteralPath $pub -Recurse -File -Force -ErrorAction SilentlyContinue)
                $outside = @($files | Where-Object {
                    $fp = $_.FullName
                    @($items.ToArray() | Where-Object { $_.Type -eq 'Folder' -and $fp.StartsWith($_.Path + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0
                }).Count
                if ($outside -eq 0 -and ($inside -gt 0 -or $files.Count -eq 0)) {
                    & $add 'EmptyFolder' $pub '' 'Publisher folder (only removed if it is empty by then)' 0 'LOW'
                }
            }
        }
    }
    return @(Add-LeftoverStatus -Items @($items.ToArray()))
}

function Move-LeftoversToQuarantine {
    # Folders and files are MOVED, registry keys/values are exported first. Returns the session folder and a result per item.
    param($Items, [string]$ProgramName, [string]$QuarantineRoot = $Script:QuarantineDir, $OtherPrograms = @())
    $stamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
    $dir = Join-Path $QuarantineRoot ('{0}-{1}' -f $stamp, (ConvertTo-SafeFileName -Text $ProgramName))
    if ($Script:DryRun) {
        foreach ($i in @($Items)) { Write-Tag INFO ("[DRY RUN] would quarantine {0}: {1}" -f $i.Type, $i.Path) }
        return [pscustomobject]@{ Dir = ''; Moved = 0; Failed = 0; Results = @() }
    }
    New-Item -ItemType Directory -Path (Join-Path $dir 'files') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir 'registry') -Force | Out-Null
    $entries = New-Object System.Collections.Generic.List[object]
    $moved = 0; $failed = 0; $n = 0
    $excl = @(Get-ExcludeList)
    # Empty-folder cleanup goes last so it sees the result of the moves before it.
    $ordered = @(@($Items | Where-Object { $_.Type -ne 'EmptyFolder' }) + @($Items | Where-Object { $_.Type -eq 'EmptyFolder' }))
    foreach ($i in $ordered) {
        $n++
        $e = [ordered]@{ Type = $i.Type; Path = $i.Path; Name = $i.Name; QuarantinePath = ''; Result = 'failed'; Note = '' }
        try {
            if (([string]$i.Status -eq 'Protected') -or (Test-LeftoverExcluded -Path $i.Path -Name $i.Name -Patterns $excl)) { throw 'It is on the exclude list, so it was left alone.' }
            switch ($i.Type) {
                { $_ -in @('Folder', 'File') } {
                    if (-not (Test-LeftoverPathAllowed -Path $i.Path -OtherPrograms $OtherPrograms)) { throw 'This path is protected and was not touched.' }
                    $dest = Join-Path (Join-Path $dir 'files') ('{0:D3}_{1}' -f $n, (ConvertTo-SafeFileName -Text (Split-Path -Leaf $i.Path)))
                    Write-Command ("Move-Item -LiteralPath '{0}' -Destination '{1}'" -f $i.Path, $dest)
                    Move-Item -LiteralPath $i.Path -Destination $dest -ErrorAction Stop
                    $e.QuarantinePath = $dest; $e.Result = 'moved'
                }
                'EmptyFolder' {
                    if (-not (Test-LeftoverPathAllowed -Path $i.Path -OtherPrograms $OtherPrograms)) { throw 'This path is protected and was not touched.' }
                    if (-not (Test-FolderHasNoFiles -Path $i.Path)) { throw 'The folder still contains files, so it was kept.' }
                    Write-Command ("Remove-Item -LiteralPath '{0}' -Recurse -Force   # contains no files" -f $i.Path)
                    Remove-Item -LiteralPath $i.Path -Recurse -Force -ErrorAction Stop
                    $e.Result = 'moved'
                }
                'RegistryKey' {
                    if ((Split-Path -Leaf $i.Path).ToLower() -in $Script:ProtectedLeafNames) { throw 'This key is protected and was not touched.' }
                    $reg = Join-Path (Join-Path $dir 'registry') ('{0:D3}_key.reg' -f $n)
                    $rp = ConvertTo-RegExePath -Path $i.Path
                    Write-Command ('reg.exe export "{0}" "{1}" /y' -f $rp, $reg)
                    $out = & reg.exe export $rp $reg /y 2>&1
                    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $reg) -or (Get-Item -LiteralPath $reg).Length -eq 0) { throw ('Could not back up the key first, so it was kept: ' + (($out | Out-String).Trim())) }
                    Write-Command ("Remove-Item -LiteralPath '{0}' -Recurse -Force" -f $i.Path)
                    Remove-Item -LiteralPath $i.Path -Recurse -Force -ErrorAction Stop
                    $e.QuarantinePath = $reg; $e.Result = 'moved'
                }
                'RunValue' {
                    $reg = Join-Path (Join-Path $dir 'registry') ('{0:D3}_run.reg' -f $n)
                    $rp = ConvertTo-RegExePath -Path $i.Path
                    Write-Command ('reg.exe export "{0}" "{1}" /y' -f $rp, $reg)
                    $out = & reg.exe export $rp $reg /y 2>&1
                    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $reg)) { throw ('Could not back up the startup key first, so it was kept: ' + (($out | Out-String).Trim())) }
                    [void](Remove-RegistryValueSafe -Path $i.Path -Name $i.Name)
                    $e.QuarantinePath = $reg; $e.Result = 'moved'
                }
                default { throw "Unknown item type $($i.Type)" }
            }
            $moved++
            Write-Tag OK ("Quarantined {0}: {1}" -f $i.Type, $i.Path)
        } catch {
            $failed++
            $e.Note = $_.Exception.Message
            Write-Tag FAIL ("{0}: {1}" -f $i.Path, $_.Exception.Message)
        }
        Write-Log -Level $(if ($e.Result -eq 'moved') { 'INFO' } else { 'FAIL' }) -Action 'QUARANTINE' -Target ([string]$i.Path) -Result ([string]$e.Result) -ErrorText ([string]$e.Note)
        $entries.Add([pscustomobject]$e)
    }
    Write-JsonFile -Path (Join-Path $dir 'manifest.json') -Object ([ordered]@{
        Program = $ProgramName; Created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Version = $Script:Version; Entries = @($entries.ToArray())
    })
    return [pscustomobject]@{ Dir = $dir; Moved = $moved; Failed = $failed; Results = @($entries.ToArray()) }
}

function Restore-Quarantine {
    # Puts every quarantined item back. Never overwrites something that already exists at the original path.
    param($Session)
    $ok = 0; $skipped = 0; $failed = 0
    foreach ($e in @($Session.Manifest.Entries)) {
        if ($e.Result -ne 'moved') { continue }
        try {
            if ($e.Type -in @('Folder', 'File')) {
                if (Test-Path -LiteralPath $e.Path) {
                    Write-Tag SKIP ('Already exists, left alone: ' + $e.Path)
                    $skipped++
                } else {
                    $parent = Split-Path -Parent $e.Path
                    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                    Write-Command ("Move-Item -LiteralPath '{0}' -Destination '{1}'" -f $e.QuarantinePath, $e.Path)
                    Move-Item -LiteralPath $e.QuarantinePath -Destination $e.Path -ErrorAction Stop
                    $ok++
                    Write-Tag OK ('Restored ' + $e.Path)
                }
            } elseif ($e.Type -eq 'EmptyFolder') {
                if (-not (Test-Path -LiteralPath $e.Path)) { New-Item -ItemType Directory -Path $e.Path -Force | Out-Null }
                $ok++
                Write-Tag OK ('Re-created empty folder ' + $e.Path)
            } else {
                Write-Command ('reg.exe import "{0}"' -f $e.QuarantinePath)
                $out = & reg.exe import $e.QuarantinePath 2>&1
                if ($LASTEXITCODE -ne 0) { throw (($out | Out-String).Trim()) }
                $ok++
                Write-Tag OK ('Restored ' + $e.Path)
            }
        } catch { $failed++; Write-Tag FAIL ("{0}: {1}" -f $e.Path, $_.Exception.Message) }
    }
    Write-Log -Level INFO -Action 'QUARANTINE_RESTORE' -Target $Session.Id -Result ("ok={0} skipped={1} failed={2}" -f $ok, $skipped, $failed)
    return [pscustomobject]@{ Restored = $ok; Skipped = $skipped; Failed = $failed }
}

function Test-LeftoverPathAllowed {
    # Safety gate: a path that fails this is never shown as a leftover and never touched.
    param([string]$Path, $OtherPrograms = @())
    if (-not $Path) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') } catch { return $false }
    if ($full.Length -le 3) { return $false }
    $leaf = (Split-Path -Leaf $full).ToLower()
    if ($Script:ProtectedLeafNames -contains $leaf) { return $false }
    foreach ($r in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $env:SystemDrive)) {
        if ($r -and ($full.TrimEnd('\', '/') -ieq $r.TrimEnd('\', '/'))) { return $false }
    }
    if ($env:SystemRoot -and $full.StartsWith($env:SystemRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    foreach ($o in @($OtherPrograms)) {
        $ol = ([string]$o.InstallLocation).TrimEnd('\', '/')
        if (-not $ol) { continue }
        if ($ol -ieq $full -or $ol.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $ol.StartsWith($full + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Get-LeftoverNames {
    param($Program)
    $set = @()
    foreach ($n in @($Program.Name, $(if ($Program.InstallLocation) { Split-Path -Leaf $Program.InstallLocation }))) {
        $t = ([string]$n).Trim()
        if ($t.Length -lt 4) { continue }
        if ($Script:ProtectedLeafNames -contains $t.ToLower()) { continue }
        if ($set -notcontains $t) { $set += $t }
    }
    return @($set)
}

# ---------------------------------------------------------------
# v0.11: review status, exclude list, options, forced uninstall by name
# ---------------------------------------------------------------

function Get-UninstallerSettings {
    $d = [pscustomobject]@{ CheckAllByDefault = $false; ForceStopExecutables = $false; OnlyBuiltIn = $false }
    if (Test-Path -LiteralPath $Script:UninstallerSettingsFile) {
        try {
            $s = Read-JsonFile -Path $Script:UninstallerSettingsFile
            foreach ($n in @('CheckAllByDefault', 'ForceStopExecutables', 'OnlyBuiltIn')) {
                if ($null -ne $s.$n) { $d.$n = [bool]$s.$n }
            }
        } catch { Write-Log -Level WARN -Action 'UNINSTALL_SETTINGS' -Target $Script:UninstallerSettingsFile -ErrorText $_.Exception.Message }
    }
    return $d
}

function Set-UninstallerSetting {
    param([ValidateSet('CheckAllByDefault', 'ForceStopExecutables', 'OnlyBuiltIn')][string]$Name, [bool]$Value)
    $s = Get-UninstallerSettings
    $s.$Name = $Value
    if ($Script:DryRun) { Write-Tag INFO ("[DRY RUN] would set {0} = {1}" -f $Name, $Value); return $s }
    Write-JsonFile -Path $Script:UninstallerSettingsFile -Object ([ordered]@{
        CheckAllByDefault = [bool]$s.CheckAllByDefault; ForceStopExecutables = [bool]$s.ForceStopExecutables; OnlyBuiltIn = [bool]$s.OnlyBuiltIn
    })
    Write-Log -Level INFO -Action 'UNINSTALL_SETTING' -Target $Name -Result ([string]$Value)
    return $s
}

function ConvertTo-ExcludeKey {
    # One spelling for folder and registry paths so they can be compared: HKLM:\..., backslashes, no trailing slash.
    param([string]$Text)
    $t = ([string]$Text).Trim().Trim('"')
    $t = $t -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^Registry::', ''
    $t = $t -replace '^HKEY_LOCAL_MACHINE', 'HKLM' -replace '^HKEY_CURRENT_USER', 'HKCU'
    $t = $t -replace '^(HKLM|HKCU)(?=\\)', '$1:'
    $t = $t -replace '/', '\'
    return $t.TrimEnd('\')
}

function Get-ExcludePatternProblem {
    # Returns a plain-words problem, or '' when the pattern is acceptable.
    param([string]$Pattern)
    $t = ConvertTo-ExcludeKey -Text $Pattern
    if ($t.Length -lt 6) { return 'That is too short. Type a full folder or registry path.' }
    if ($t -match '^[\*\?\\:/\.\s]*$') { return 'A pattern made only of wildcards would match almost everything.' }
    if ($t -match '^(HKLM:|HKCU:|[A-Za-z]:)\\?[\*\?]') { return 'A wildcard right after the root would match far too much. Start with a real folder or key name.' }
    return ''
}

function Get-ExcludeList {
    if (-not (Test-Path -LiteralPath $Script:ExcludeFile)) { return @() }
    try {
        $o = Read-JsonFile -Path $Script:ExcludeFile
        return @(@($o.Patterns) | ForEach-Object { [string]$_ } | Where-Object { $_ })
    } catch {
        Write-Log -Level WARN -Action 'EXCLUDE_READ' -Target $Script:ExcludeFile -ErrorText $_.Exception.Message
        return @()
    }
}

function Add-ExcludeEntry {
    param([string]$Pattern)
    $t = ConvertTo-ExcludeKey -Text $Pattern
    $problem = Get-ExcludePatternProblem -Pattern $t
    if ($problem) { throw $problem }
    $cur = @(Get-ExcludeList)
    if (@($cur | Where-Object { $_ -ieq $t }).Count -gt 0) { return $t }
    if ($Script:DryRun) { Write-Tag INFO ("[DRY RUN] would add to the exclude list: {0}" -f $t); return $t }
    Write-JsonFile -Path $Script:ExcludeFile -Object ([ordered]@{ Patterns = @($cur + $t) })
    Write-Log -Level INFO -Action 'EXCLUDE_ADD' -Target $t
    return $t
}

function Remove-ExcludeEntry {
    param([string]$Pattern)
    $t = ConvertTo-ExcludeKey -Text $Pattern
    $cur = @(Get-ExcludeList)
    $keep = @($cur | Where-Object { $_ -ine $t })
    if ($Script:DryRun) { Write-Tag INFO ("[DRY RUN] would remove from the exclude list: {0}" -f $t); return }
    Write-JsonFile -Path $Script:ExcludeFile -Object ([ordered]@{ Patterns = @($keep) })
    Write-Log -Level INFO -Action 'EXCLUDE_REMOVE' -Target $t
}

function ConvertTo-ExcludeRegex {
    # * = any text, ? = one character. A pattern also covers everything underneath it.
    param([string]$Pattern)
    $b = [regex]::Escape((ConvertTo-ExcludeKey -Text $Pattern))
    $b = $b -replace '\\\*', '.*' -replace '\\\?', '.'
    return ('^(?:' + $b + ')(?:\\.*)?$')
}

function Test-LeftoverExcluded {
    param([string]$Path, [string]$Name = '', $Patterns = $null)
    if ($null -eq $Patterns) { $Patterns = @(Get-ExcludeList) }
    if (@($Patterns).Count -eq 0) { return $false }
    $base = ConvertTo-ExcludeKey -Text $Path
    $cands = @($base)
    if ($Name) { $cands += ($base + '\' + $Name) }
    foreach ($pat in @($Patterns)) {
        $re = ConvertTo-ExcludeRegex -Pattern $pat
        foreach ($c in $cands) { if ([regex]::IsMatch($c, $re, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { return $true } }
    }
    return $false
}

function Add-LeftoverStatus {
    # Created = matched to this program, can be selected.  Protected = on the exclude list, never touched.
    # Parent = where the item sits, shown as grey context in the review screen.
    param($Items)
    $pats = @(Get-ExcludeList)
    foreach ($i in @($Items)) {
        $st = 'Created'
        if (Test-LeftoverExcluded -Path $i.Path -Name $i.Name -Patterns $pats) { $st = 'Protected' }
        if ($i.Type -eq 'RunValue') { $parent = ConvertTo-ExcludeKey -Text $i.Path }
        else { $parent = (ConvertTo-ExcludeKey -Text $i.Path) -replace '\\[^\\]+$', '' }
        Add-Member -InputObject $i -NotePropertyName Status -NotePropertyValue $st -Force
        Add-Member -InputObject $i -NotePropertyName Parent -NotePropertyValue $parent -Force
        $i
    }
}

function Open-RegistryKeyInRegedit {
    # Regedit opens at the key it last showed, so we set that value first (a harmless viewer setting).
    param([string]$Path)
    $full = ConvertTo-RegExePath -Path (ConvertTo-ExcludeKey -Text $Path)
    $full = $full -replace '^HKLM(?=\\|$)', 'HKEY_LOCAL_MACHINE' -replace '^HKCU(?=\\|$)', 'HKEY_CURRENT_USER'
    $last = 'Computer\' + $full
    if ($Script:DryRun) { Write-Tag INFO ("[DRY RUN] would open Regedit at {0}" -f $last); return $last }
    $rk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Applets\Regedit'
    if (-not (Test-Path -LiteralPath $rk)) { Write-Command ("New-Item -Path '{0}' -Force" -f $rk); New-Item -Path $rk -Force | Out-Null }
    Write-Command ("Set-ItemProperty -Path '{0}' -Name LastKey -Value '{1}'" -f $rk, $last)
    Set-ItemProperty -LiteralPath $rk -Name 'LastKey' -Value $last -ErrorAction Stop
    Write-Command 'Start-Process regedit.exe'
    Start-Process -FilePath 'regedit.exe'
    return $last
}

function Open-LeftoverFolder {
    param([string]$Path)
    if ($Script:DryRun) { Write-Tag INFO ("[DRY RUN] would show {0} in Explorer" -f $Path); return }
    if (-not (Test-Path -LiteralPath $Path)) { throw 'That item is no longer there.' }
    Write-Command ("Start-Process explorer.exe -ArgumentList '/select,""{0}""'" -f $Path)
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $Path)
}

function Stop-ProgramProcesses {
    # Only processes whose executable sits inside the program's own install folder.
    param($Program)
    if ($Script:DryRun) { return 0 }
    $loc = ([string]$Program.InstallLocation).TrimEnd('\', '/')
    if (-not $loc -or $loc.Length -lt 6 -or -not (Test-LeftoverPathAllowed -Path $loc)) { return 0 }
    $n = 0
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.Id -eq $PID) { continue }
        $exe = ''
        try { $exe = [string]$p.Path } catch { $exe = '' }
        if (-not $exe) { continue }
        if ($exe.StartsWith($loc + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $exe.StartsWith($loc + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Command ("Stop-Process -Id {0} -Force   # {1}" -f $p.Id, $exe)
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $n++ } catch { Write-Tag WARN ("Could not stop {0}: {1}" -f $p.ProcessName, $_.Exception.Message) }
        }
    }
    return $n
}

function Test-ForcedPathAllowed {
    # A folder typed by hand must sit strictly inside a normal install location.
    param([string]$Path)
    if (-not (Test-LeftoverPathAllowed -Path $Path)) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') } catch { return $false }
    foreach ($r in @(Get-DefaultFolderRoots)) {
        $rt = ([string]$r).TrimEnd('\', '/')
        if (-not $rt) { continue }
        if ($full.StartsWith($rt + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($rt + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Find-UninstallMatches {
    # Looks for a built-in uninstaller (installed programs) or an earlier DIVuninstaller record by exact name, wildcard name or folder.
    # Several names can be separated with semicolons. Nothing is changed.
    param([string]$Name = '', [string]$Path = '', $Programs = $null)
    if ($null -eq $Programs) { $Programs = @(Get-InstalledPrograms) }
    $names = @(([string]$Name -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $pp = ([string]$Path).Trim().Trim('"').TrimEnd('\', '/')
    $out = @()
    foreach ($p in @($Programs)) {
        $hit = $false
        foreach ($n in $names) {
            if ($n -match '[\*\?]') { if ($p.Name -like $n) { $hit = $true } }
            elseif ($p.Name -ieq $n) { $hit = $true }
        }
        if ($pp -and $p.InstallLocation) {
            $il = ([string]$p.InstallLocation).TrimEnd('\', '/')
            if ($il -ieq $pp -or $il.StartsWith($pp + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $il.StartsWith($pp + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $hit = $true }
        }
        if ($hit) { $out += [pscustomobject]@{ Source = 'Installed program (has its own uninstaller)'; Name = $p.Name; Version = $p.Version; Program = $p } }
    }
    foreach ($h in @(Get-UninstallHistory)) {
        foreach ($n in $names) {
            $m = $false
            if ($n -match '[\*\?]') { $m = ($h.Name -like $n) } else { $m = ($h.Name -ieq $n) }
            if ($m) { $out += [pscustomobject]@{ Source = 'Earlier DIVuninstaller record'; Name = $h.Name; Version = $h.Version; Program = $null } }
        }
    }
    return @($out)
}

function New-ForcedProgram {
    # A stand-in for a program that has no uninstall entry (removed earlier, partly installed, or never listed).
    param([string]$Name = '', [string]$InstallLocation = '')
    $loc = ([string]$InstallLocation).Trim().Trim('"').TrimEnd('\', '/')
    $nm = ([string]$Name).Trim()
    if (-not $nm -and $loc) { $nm = Split-Path -Leaf $loc }
    if ($nm.Length -lt 4) { throw 'Type the full program name (at least 4 characters).' }
    if ($nm -match '[\*\?;]') { throw 'Wildcards and semicolons are for searching only. Type one exact program name to scan for.' }
    if (Test-ProgramProtected -Name $nm) { throw ("{0} looks like a protected program (system, runtime, driver or security software) and cannot be removed here." -f $nm) }
    if ($loc -and -not (Test-ForcedPathAllowed -Path $loc)) { throw 'That folder is not allowed. It must be inside Program Files, ProgramData or AppData, and not a system or shared folder.' }
    return [pscustomobject]@{
        Name = $nm; Publisher = ''; Version = ''; InstallDate = ''; InstallLocation = $loc; UninstallString = ''; QuietUninstallString = ''
        SizeKB = 0; KeyName = ''; KeyPath = ''; Scope = 'Machine'; Protected = $false
    }
}

# ---------------------------------------------------------------
# v0.12: batch uninstall and the Windows Apps list
# ---------------------------------------------------------------

function Test-BatchProgramsReady {
    # Checks the whole batch BEFORE anything runs. Returns a plain-words problem, or '' when it is fine.
    param($Programs)
    $progs = @($Programs)
    if ($progs.Count -lt 1) { return 'Select at least one program.' }
    $prot = @($progs | Where-Object { $_.Protected } | ForEach-Object { $_.Name })
    if ($prot.Count -gt 0) { return ("These are protected programs and cannot be removed here: {0}. Deselect them and try again." -f ($prot -join ', ')) }
    $bad = @($progs | Where-Object { -not (Split-UninstallCommand -Text $_.UninstallString) } | ForEach-Object { $_.Name })
    if ($bad.Count -gt 0) { return ("The uninstall command could not be read safely for: {0}. Nothing was run. Remove those one at a time (forced uninstall if needed)." -f ($bad -join ', ')) }
    return ''
}

function Invoke-BatchUninstall {
    # ONE restore point for the whole batch, then each program's own uninstaller, one after another.
    # A failure in one program does not stop the others. Nothing is run if any program fails the up-front check.
    param($Programs, [switch]$SkipRestorePoint)
    $progs = @($Programs)
    $problem = Test-BatchProgramsReady -Programs $progs
    if ($problem) { throw $problem }
    $rp = 'Skipped'
    if (-not $SkipRestorePoint -and -not $Script:DryRun) {
        $r = New-DivRestorePoint -Description ('DIVuninstaller batch of {0} programs' -f $progs.Count)
        $rp = $r.Status
        if ($r.Message) { Write-Tag WARN ('Restore point: ' + $r.Message) }
    }
    Write-Log -Level INFO -Action 'BATCH_UNINSTALL' -Target ([string]$progs.Count) -Message (($progs | ForEach-Object { $_.Name }) -join '; ')
    $results = @()
    $n = 0
    foreach ($p in $progs) {
        $n++
        Write-Tag INFO ("Batch {0} of {1}: {2}" -f $n, $progs.Count, $p.Name)
        try {
            $r = Invoke-ProgramUninstall -Program $p -SkipRestorePoint
            if ($r.BackupDir) { Update-UninstallRecord -Dir $r.BackupDir -Values @{ Batch = $true; BatchSize = $progs.Count; RestorePoint = $rp } }
            $results += [pscustomobject]@{ Program = $p; Result = $r; Error = '' }
        } catch {
            Write-Log -Level FAIL -Action 'UNINSTALL' -Target $p.Name -ErrorText $_.Exception.Message
            Write-Tag FAIL ("{0}: {1}" -f $p.Name, $_.Exception.Message)
            $results += [pscustomobject]@{ Program = $p; Result = $null; Error = $_.Exception.Message }
        }
    }
    return [pscustomobject]@{ RestorePoint = $rp; Results = @($results) }
}

function Get-BatchLeftovers {
    # One combined list for every program in the batch that is really gone. Each item remembers which program it belongs to.
    param($Batch, [string]$Mode, $AllPrograms = @())
    if ($Mode -eq 'None') { return @() }
    $keys = @($Batch.Results | ForEach-Object { $_.Program.KeyPath })
    $others = @($AllPrograms | Where-Object { $keys -notcontains $_.KeyPath })
    $seen = @{}
    $out = @()
    foreach ($b in @($Batch.Results)) {
        if (-not $b.Result -or $b.Result.StillInstalled) { continue }
        $found = @(Get-ProgramLeftovers -Program $b.Program -OtherPrograms $others -Mode $Mode)
        Update-UninstallRecord -Dir $b.Result.BackupDir -Values @{ Mode = $Mode; LeftoversFound = $found.Count; LeftoversMoved = 0 }
        foreach ($i in $found) {
            $k = ($i.Type + '|' + $i.Path + '|' + $i.Name).ToLower()
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            Add-Member -InputObject $i -NotePropertyName ProgramName -NotePropertyValue ([string]$b.Program.Name) -Force
            Add-Member -InputObject $i -NotePropertyName RecordDir -NotePropertyValue ([string]$b.Result.BackupDir) -Force
            $out += $i
        }
    }
    return @($out)
}

function Move-BatchLeftovers {
    # Quarantine the chosen items, one quarantine entry per program so each can be restored on its own.
    param($Items, $OtherPrograms = @())
    $moved = 0; $failed = 0; $dirs = @()
    foreach ($g in @(@($Items) | Group-Object -Property ProgramName)) {
        $m = Move-LeftoversToQuarantine -Items @($g.Group) -ProgramName ([string]$g.Name) -OtherPrograms $OtherPrograms
        $moved += $m.Moved; $failed += $m.Failed
        if ($m.Dir) { $dirs += $m.Dir }
        $rec = [string](@($g.Group)[0].RecordDir)
        Update-UninstallRecord -Dir $rec -Values @{ LeftoversMoved = $m.Moved; Quarantine = $m.Dir }
    }
    return [pscustomobject]@{ Moved = $moved; Failed = $failed; Dirs = @($dirs) }
}

function Get-WindowsApps {
    # The current user's Store and built-in apps that Windows says can be removed. Frameworks and system packages are left out.
    $out = @()
    foreach ($p in @(Get-AppxPackage -ErrorAction SilentlyContinue)) {
        if ($p.IsFramework -or $p.NonRemovable) { continue }
        if ([string]$p.SignatureKind -eq 'System') { continue }
        $isRes = $false
        try { $isRes = [bool]$p.IsResourcePackage } catch { $isRes = $false }
        if ($isRes) { continue }
        $pub = ''
        try { $pub = [string]$p.PublisherId } catch { $pub = '' }
        $out += [pscustomobject]@{
            Name = [string]$p.Name; Version = [string]$p.Version; Publisher = $pub
            PackageFullName = [string]$p.PackageFullName; InstallLocation = [string]$p.InstallLocation
            Protected = (Test-PackageProtected -Name ([string]$p.Name))
        }
    }
    return @($out | Sort-Object -Property Name)
}

function Remove-WindowsApps {
    # Removes apps by exact package name through the same guarded function Optional Apps uses.
    # Current user only by default. -AllUsers (needs Administrator) also removes the provisioned copy for new users.
    param($Apps, [switch]$AllUsers, [switch]$SkipRestorePoint)
    $apps = @($Apps)
    if ($apps.Count -lt 1) { throw 'Select at least one app.' }
    $prot = @($apps | Where-Object { $_.Protected -or (Test-PackageProtected -Name $_.Name) } | ForEach-Object { $_.Name })
    if ($prot.Count -gt 0) { throw ("These are protected apps and cannot be removed here: {0}." -f ($prot -join ', ')) }
    if ($AllUsers -and -not (Test-Administrator) -and -not $Script:DryRun) { throw 'Removing for all users needs Administrator. Run DIVoptimizer as Administrator, or remove for the current user only.' }
    $rp = 'Skipped'
    if (-not $SkipRestorePoint -and -not $Script:DryRun) {
        $r = New-DivRestorePoint -Description ('DIVuninstaller Windows Apps ({0})' -f $apps.Count)
        $rp = $r.Status
        if ($r.Message) { Write-Tag WARN ('Restore point: ' + $r.Message) }
    }
    $results = @()
    foreach ($a in $apps) {
        try {
            if ($AllUsers) { $c = Remove-AppPackageExact -Name $a.Name } else { $c = Remove-AppPackageExact -Name $a.Name -CurrentUserOnly }
            Write-Log -Level INFO -Action 'APP_REMOVE' -Target $a.Name -Result ([string]$c)
            if ($c -gt 0) { Write-Tag OK ("Removed {0}" -f $a.Name) } else { Write-Tag SKIP ("{0}: nothing to remove" -f $a.Name) }
            $results += [pscustomobject]@{ Name = $a.Name; Removed = [int]$c; Error = '' }
        } catch {
            Write-Log -Level FAIL -Action 'APP_REMOVE' -Target $a.Name -ErrorText $_.Exception.Message
            Write-Tag FAIL ("{0}: {1}" -f $a.Name, $_.Exception.Message)
            $results += [pscustomobject]@{ Name = $a.Name; Removed = 0; Error = $_.Exception.Message }
        }
    }
    return [pscustomobject]@{ RestorePoint = $rp; Results = @($results) }
}

# ---------------------------------------------------------------
# v0.13: browser extensions (Chrome, Edge, Brave, Firefox)
# Listing is read-only. Removal moves the extension to the DIVuninstaller quarantine; browser databases are never edited.
# ---------------------------------------------------------------

function Get-ChromiumExtensionName {
    param([string]$VersionDir, [string]$Fallback = '')
    $name = ''
    try {
        $mfPath = Join-Path $VersionDir 'manifest.json'
        if (Test-Path -LiteralPath $mfPath) {
            $m = (Get-Content -LiteralPath $mfPath -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
            $name = [string]$m.name
            if ($name -match '^__MSG_(.+)__$') {
                $key = [string]$Matches[1]
                $resolved = ''
                $locs = @([string]$m.default_locale, 'en', 'en_US') | Where-Object { $_ }
                foreach ($loc in $locs) {
                    $lp = Join-Path (Join-Path (Join-Path $VersionDir '_locales') $loc) 'messages.json'
                    if (-not (Test-Path -LiteralPath $lp)) { continue }
                    try {
                        $msgs = (Get-Content -LiteralPath $lp -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
                        foreach ($pr in $msgs.PSObject.Properties) { if ($pr.Name -ieq $key -and $pr.Value.message) { $resolved = [string]$pr.Value.message; break } }
                    } catch { $resolved = '' }
                    if ($resolved) { break }
                }
                if ($resolved) { $name = $resolved } else { $name = '' }
            }
        }
    } catch { $name = '' }
    if (-not $name) { $name = $Fallback }
    return $name
}

function Get-BrowserExtensions {
    # Read-only. Chromium browsers: <profile>\Extensions\<id>\<version>. Firefox: extensions.json in each profile.
    param($ChromiumRoots = $null, [string[]]$FirefoxRoots = $null)
    if ($null -eq $ChromiumRoots) {
        $ChromiumRoots = @()
        if ($env:LOCALAPPDATA) {
            $ChromiumRoots = @(
                @{ Browser = 'Chrome'; Root = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data') },
                @{ Browser = 'Edge'; Root = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data') },
                @{ Browser = 'Brave'; Root = (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data') }
            )
        }
    }
    if ($null -eq $FirefoxRoots) {
        $FirefoxRoots = @()
        if ($env:APPDATA) { $FirefoxRoots = @((Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles')) }
    }
    $out = @()
    foreach ($c in @($ChromiumRoots)) {
        if (-not (Test-Path -LiteralPath $c.Root)) { continue }
        foreach ($prof in @(Get-ChildItem -LiteralPath $c.Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
            $ext = Join-Path $prof.FullName 'Extensions'
            if (-not (Test-Path -LiteralPath $ext)) { continue }
            foreach ($idDir in @(Get-ChildItem -LiteralPath $ext -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Temp' })) {
                $vers = @(Get-ChildItem -LiteralPath $idDir.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object -Property @{ Expression = { try { [version](($_.Name) -replace '_\d+$', '') } catch { [version]'0.0' } } } -Descending)
                if ($vers.Count -eq 0) { continue }
                $out += [pscustomobject]@{
                    Browser = [string]$c.Browser; Profile = [string]$prof.Name; Id = [string]$idDir.Name
                    Name = (Get-ChromiumExtensionName -VersionDir $vers[0].FullName -Fallback $idDir.Name)
                    Version = (([string]$vers[0].Name) -replace '_\d+$', ''); Path = [string]$idDir.FullName; Kind = 'Folder'
                }
            }
        }
    }
    foreach ($fr in @($FirefoxRoots)) {
        if (-not (Test-Path -LiteralPath $fr)) { continue }
        foreach ($prof in @(Get-ChildItem -LiteralPath $fr -Directory -ErrorAction SilentlyContinue)) {
            $ej = Join-Path $prof.FullName 'extensions.json'
            if (-not (Test-Path -LiteralPath $ej)) { continue }
            try {
                $j = (Get-Content -LiteralPath $ej -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
                foreach ($a in @($j.addons)) {
                    if ([string]$a.type -ne 'extension') { continue }
                    if ([string]$a.location -ne 'app-profile') { continue }
                    $nm = ''
                    try { $nm = [string]$a.defaultLocale.name } catch { $nm = '' }
                    if (-not $nm) { $nm = [string]$a.id }
                    $p = ''
                    try { $p = [string]$a.path } catch { $p = '' }
                    $out += [pscustomobject]@{ Browser = 'Firefox'; Profile = [string]$prof.Name; Id = [string]$a.id; Name = $nm; Version = [string]$a.version; Path = $p; Kind = 'File' }
                }
            } catch { Write-Log -Level WARN -Action 'EXT_LIST' -Target $ej -ErrorText $_.Exception.Message }
        }
    }
    return @($out | Sort-Object -Property Browser, Name)
}

function Test-BrowserRunning {
    param([string]$Browser)
    $proc = switch ($Browser) { 'Chrome' { 'chrome' } 'Edge' { 'msedge' } 'Brave' { 'brave' } 'Firefox' { 'firefox' } default { '' } }
    if (-not $proc) { return $false }
    return (@(Get-Process -Name $proc -ErrorAction SilentlyContinue).Count -gt 0)
}

function Test-BrowserExtensionPathAllowed {
    # Only the extension's own folder (Chromium) or .xpi file (Firefox) may be touched, inside the extensions folder of a profile.
    param($Item)
    $p = ([string]$Item.Path).TrimEnd('\', '/')
    if (-not $p) { return $false }
    if ($Item.Kind -eq 'Folder') { return ($p -match '[\\/]Extensions[\\/][^\\/]+$') }
    return (($p -match '[\\/]extensions[\\/][^\\/]+\.xpi$') -and ($p -match '[\\/]Profiles[\\/]'))
}

function Remove-BrowserExtensions {
    # One quarantine entry per extension, so each can be restored on its own. The browser must be closed first.
    param($Items, [string]$QuarantineRoot = $Script:QuarantineDir)
    $items = @($Items)
    if ($items.Count -lt 1) { throw 'Select at least one extension.' }
    $open = @($items | ForEach-Object { $_.Browser } | Sort-Object -Unique | Where-Object { Test-BrowserRunning -Browser $_ })
    if ($open.Count -gt 0) { throw ("Close {0} first (all windows), then try again. A browser that is running would just put its extensions back." -f ($open -join ' and ')) }
    $bad = @($items | Where-Object { -not (Test-BrowserExtensionPathAllowed -Item $_) } | ForEach-Object { $_.Name })
    if ($bad.Count -gt 0) { throw ("These extensions have no folder or file DIVuninstaller can safely move, so nothing was removed: {0}. Remove them from the browser's own extensions page." -f ($bad -join ', ')) }
    $moved = 0; $failed = 0; $dirs = @()
    foreach ($e in $items) {
        $li = [pscustomobject]@{ Type = $(if ($e.Kind -eq 'Folder') { 'Folder' } else { 'File' }); Path = $e.Path; Name = ''; Detail = ('{0} extension' -f $e.Browser); SizeBytes = 0; Risk = 'LOW'; Status = 'Created' }
        $m = Move-LeftoversToQuarantine -Items @($li) -ProgramName ('{0} extension - {1}' -f $e.Browser, $e.Name) -QuarantineRoot $QuarantineRoot
        $moved += $m.Moved; $failed += $m.Failed
        if ($m.Dir) { $dirs += $m.Dir }
        Write-Log -Level INFO -Action 'EXT_REMOVE' -Target ('{0}: {1}' -f $e.Browser, $e.Name) -Result ([string]$m.Moved)
    }
    return [pscustomobject]@{ Moved = $moved; Failed = $failed; Dirs = @($dirs) }
}

# ---------------------------------------------------------------
# v0.14: install monitor (lightweight trace logs)
# Take a snapshot, install a program, take a second snapshot. The difference is saved as a trace log.
# Cleaning up from a log only lists items that were created in that window AND still exist, and moves them to quarantine.
# This is best-effort: anything else that changed on the PC during the window can show up, so you review every item.
# ---------------------------------------------------------------

$Script:TraceDir = Join-Path $Script:DataRoot 'Traces'

function Select-TopLevelPaths {
    # Keeps only paths that are not inside another path in the list.
    param([string[]]$Paths)
    $kept = @()
    foreach ($p in @($Paths | Where-Object { $_ } | Sort-Object -Property Length)) {
        $child = $false
        foreach ($k in $kept) {
            $kk = $k.TrimEnd('\', '/')
            if ($p.StartsWith($kk + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($kk + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $child = $true; break }
        }
        if (-not $child) { $kept += $p }
    }
    return @($kept)
}

function Get-InstallSnapshot {
    # Names only: folders two levels deep, shortcuts, registry keys two levels deep, startup values and services. No file contents.
    param(
        [string[]]$FolderRoots = $null,
        [string[]]$FileRoots = $null,
        [string[]]$RegistryRoots = @('HKCU:\Software', 'HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node'),
        [string[]]$UninstallRoots = $null,
        [string[]]$RunKeys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'),
        [switch]$SkipServices
    )
    if ($null -eq $FolderRoots) { $FolderRoots = Get-DefaultFolderRoots }
    if ($null -eq $FileRoots) { $FileRoots = Get-DefaultShortcutRoots }
    if ($null -eq $UninstallRoots) { $UninstallRoots = $Script:UninstallKeyRoots }
    $folders = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($FolderRoots)) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        foreach ($d1 in @(Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue)) {
            $folders.Add($d1.FullName)
            foreach ($d2 in @(Get-ChildItem -LiteralPath $d1.FullName -Directory -Force -ErrorAction SilentlyContinue)) { $folders.Add($d2.FullName) }
        }
    }
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($FileRoots)) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $r -Filter '*.lnk' -File -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -First 5000)) { $files.Add($f.FullName) }
    }
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($RegistryRoots)) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        foreach ($k1 in @(Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue)) {
            $keys.Add('Registry::' + $k1.Name)
            foreach ($k2 in @(Get-ChildItem -LiteralPath $k1.PSPath -ErrorAction SilentlyContinue)) { $keys.Add('Registry::' + $k2.Name) }
        }
    }
    foreach ($r in @($UninstallRoots)) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        foreach ($k1 in @(Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue)) { $keys.Add('Registry::' + $k1.Name) }
    }
    $runs = New-Object System.Collections.Generic.List[string]
    foreach ($rk in @($RunKeys)) {
        if (-not (Test-Path -LiteralPath $rk)) { continue }
        $props = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($pr in @($props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) { $runs.Add($rk + '|' + $pr.Name) }
    }
    $svc = @()
    if (-not $SkipServices) { $svc = @(Get-Service -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name }) }
    return [pscustomobject]@{
        Taken = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Folders = @($folders.ToArray()); Files = @($files.ToArray())
        RegistryKeys = @($keys.ToArray()); RunValues = @($runs.ToArray()); Services = @($svc)
    }
}

function Compare-InstallSnapshots {
    # Pure comparison. Returns the items created between the two snapshots, shaped like leftover items, plus new service names (information only).
    param($Before, $After)
    $cmp = [System.StringComparer]::OrdinalIgnoreCase
    $mk = { param($arr) $h = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList $cmp; foreach ($x in @($arr)) { [void]$h.Add([string]$x) }; return ,$h }
    $bF = & $mk $Before.Folders; $bFi = & $mk $Before.Files; $bK = & $mk $Before.RegistryKeys; $bR = & $mk $Before.RunValues; $bS = & $mk $Before.Services
    $skipRoots = @($Script:DataRoot, $env:TEMP, $env:TMP) | Where-Object { $_ }
    $isNoise = {
        param([string]$Path)
        foreach ($sr in $skipRoots) { if ($Path.StartsWith(([string]$sr).TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) { return $true } }
        return $false
    }
    $items = @()
    $newDirs = Select-TopLevelPaths -Paths @(@($After.Folders) | Where-Object { -not $bF.Contains([string]$_) })
    foreach ($d in $newDirs) {
        if (& $isNoise $d) { continue }
        if (-not (Test-LeftoverPathAllowed -Path $d)) { continue }
        $risk = 'LOW'
        if ($env:ProgramFiles -and $d.StartsWith($env:ProgramFiles, [System.StringComparison]::OrdinalIgnoreCase)) { $risk = 'CHECK' }
        $items += [pscustomobject]@{ Type = 'Folder'; Path = $d; Name = ''; Detail = 'Created while the program was installed'; SizeBytes = [long]0; Risk = $risk }
    }
    foreach ($f in @(@($After.Files) | Where-Object { -not $bFi.Contains([string]$_) })) {
        $inside = $false
        foreach ($nd in $newDirs) { if ($f.StartsWith($nd.TrimEnd('\', '/') + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $f.StartsWith($nd.TrimEnd('\', '/') + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $inside = $true } }
        if ($inside) { continue }
        $items += [pscustomobject]@{ Type = 'File'; Path = $f; Name = ''; Detail = 'Shortcut created while the program was installed'; SizeBytes = [long]0; Risk = 'LOW' }
    }
    $newKeys = Select-TopLevelPaths -Paths @(@($After.RegistryKeys) | Where-Object { -not $bK.Contains([string]$_) })
    foreach ($k in $newKeys) {
        $kn = $k -replace '^Registry::', ''
        # Keys under Microsoft, Classes and Policies change constantly for reasons that have nothing to do with the install: not tracked.
        if ($kn -match '(?i)\\(Microsoft|Classes|Policies)(\\|$)' -and $kn -notmatch '(?i)\\Uninstall\\') { continue }
        $leaf = ($kn -replace '^.*\\', '').ToLower()
        if ($Script:ProtectedLeafNames -contains $leaf) { continue }
        $detail = 'Registry key created while the program was installed'
        if ($kn -match '(?i)\\Uninstall\\') { $detail = 'The program''s uninstall entry' }
        $risk = 'CHECK'; if ($kn -like 'HKEY_CURRENT_USER*') { $risk = 'LOW' }
        $items += [pscustomobject]@{ Type = 'RegistryKey'; Path = $k; Name = ''; Detail = $detail; SizeBytes = [long]0; Risk = $risk }
    }
    foreach ($rv in @(@($After.RunValues) | Where-Object { -not $bR.Contains([string]$_) })) {
        $parts = ([string]$rv) -split '\|', 2
        if ($parts.Count -ne 2) { continue }
        $items += [pscustomobject]@{ Type = 'RunValue'; Path = $parts[0]; Name = $parts[1]; Detail = 'Starts with Windows (created while the program was installed)'; SizeBytes = [long]0; Risk = 'LOW' }
    }
    $svc = @(@($After.Services) | Where-Object { -not $bS.Contains([string]$_) })
    return [pscustomobject]@{ Items = @($items); Services = @($svc) }
}

function Start-InstallTrace {
    # Saves the "before" snapshot so it survives closing the app.
    param([string]$Name)
    $nm = ([string]$Name).Trim()
    if ($nm.Length -lt 2) { throw 'Type a name for this install (the program you are about to install).' }
    $snap = Get-InstallSnapshot
    $dir = Join-Path $Script:TraceDir 'pending'
    if ($Script:DryRun) { Write-Tag INFO ("[DRY RUN] would save the before-snapshot for {0}" -f $nm); return $snap }
    Write-JsonFile -Path (Join-Path $dir 'before.json') -Object ([ordered]@{ Name = $nm; Started = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Snapshot = $snap })
    Write-Log -Level INFO -Action 'TRACE_START' -Target $nm
    return $snap
}

function Get-PendingTrace {
    $f = Join-Path (Join-Path $Script:TraceDir 'pending') 'before.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return (Read-JsonFile -Path $f) } catch { Write-Log -Level WARN -Action 'TRACE_PENDING' -Target $f -ErrorText $_.Exception.Message; return $null }
}

function Stop-InstallTrace {
    # Throws the saved "before" snapshot away. Only ever deletes the pending folder inside the traces folder.
    $dir = Join-Path $Script:TraceDir 'pending'
    if ($Script:DryRun) { return }
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Log -Level INFO -Action 'TRACE_CANCEL'
}

function Complete-InstallTrace {
    # Takes the "after" snapshot, compares, and saves the trace log. Returns the log folder.
    param($Pending = $null)
    if ($null -eq $Pending) { $Pending = Get-PendingTrace }
    if (-not $Pending) { throw 'There is no install in progress. Start a trace first.' }
    $after = Get-InstallSnapshot
    $diff = Compare-InstallSnapshots -Before $Pending.Snapshot -After $after
    $dir = Join-Path $Script:TraceDir ('{0}-{1}' -f (Get-Date -Format 'yyyy-MM-dd-HHmmss'), (ConvertTo-SafeFileName -Text ([string]$Pending.Name)))
    if ($Script:DryRun) { Write-Tag INFO ("[DRY RUN] would save a trace log with {0} item(s)" -f @($diff.Items).Count); return [pscustomobject]@{ Dir = ''; Count = @($diff.Items).Count; Diff = $diff } }
    Write-JsonFile -Path (Join-Path $dir 'trace.json') -Object ([ordered]@{
        Name = [string]$Pending.Name; Started = [string]$Pending.Started; Finished = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Version = $Script:Version
        Items = @($diff.Items | ForEach-Object { [ordered]@{ Type = $_.Type; Path = $_.Path; Name = $_.Name; Detail = $_.Detail; Risk = $_.Risk } })
        Services = @($diff.Services)
    })
    Stop-InstallTrace
    Write-Log -Level INFO -Action 'TRACE_SAVED' -Target ([string]$Pending.Name) -Result ([string]@($diff.Items).Count)
    return [pscustomobject]@{ Dir = $dir; Count = @($diff.Items).Count; Diff = $diff }
}

function Get-TraceLogs {
    param([string]$Root = $Script:TraceDir)
    $out = @()
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'pending' })) {
        $tj = Join-Path $d.FullName 'trace.json'
        if (-not (Test-Path -LiteralPath $tj)) { continue }
        try {
            $t = Read-JsonFile -Path $tj
            $out += [pscustomobject]@{ Id = $d.Name; Path = $d.FullName; Name = [string]$t.Name; Finished = [string]$t.Finished; Count = @($t.Items).Count; Trace = $t }
        } catch { Write-Log -Level WARN -Action 'TRACE_LIST' -Target $d.FullName -ErrorText $_.Exception.Message }
    }
    return @($out | Sort-Object Id -Descending)
}

function Get-TraceReviewItems {
    # Items from a log that still exist now, with sizes, marked Created or Protected (exclude list).
    param($Log)
    $items = @()
    foreach ($t in @($Log.Trace.Items)) {
        $present = $false
        switch ([string]$t.Type) {
            'RegistryKey' { $present = Test-Path -LiteralPath ([string]$t.Path) }
            'RunValue' { $present = ((Test-Path -LiteralPath ([string]$t.Path)) -and ($null -ne (Get-ItemProperty -LiteralPath ([string]$t.Path) -Name ([string]$t.Name) -ErrorAction SilentlyContinue))) }
            default { $present = Test-Path -LiteralPath ([string]$t.Path) }
        }
        if (-not $present) { continue }
        if ([string]$t.Type -in @('Folder', 'File') -and -not (Test-LeftoverPathAllowed -Path ([string]$t.Path))) { continue }
        $size = [long]0
        if ([string]$t.Type -eq 'Folder') { $size = [long](Get-FolderStats -Path ([string]$t.Path)).Bytes }
        $items += [pscustomobject]@{ Type = [string]$t.Type; Path = [string]$t.Path; Name = [string]$t.Name; Detail = [string]$t.Detail; SizeBytes = $size; Risk = [string]$t.Risk }
    }
    return @(Add-LeftoverStatus -Items @($items))
}

function Remove-TraceLog {
    # Deletes ONLY a trace log folder that sits directly inside the traces folder and holds a trace.json.
    param([string]$Dir, [string]$Root = $Script:TraceDir)
    $full = [System.IO.Path]::GetFullPath($Dir).TrimEnd('\', '/')
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $parent = [System.IO.Path]::GetDirectoryName($full)
    if (-not $parent -or ($parent.TrimEnd('\', '/') -ine $rootFull)) { throw 'That folder is not inside the DIVuninstaller traces folder, so it was not deleted.' }
    if (-not (Test-Path -LiteralPath (Join-Path $full 'trace.json'))) { throw 'That folder has no trace log, so it was not deleted.' }
    Write-Command ("Remove-Item -LiteralPath '{0}' -Recurse -Force" -f $full)
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    Write-Log -Level INFO -Action 'TRACE_DELETE' -Target $full
}

# ---------------------------------------------------------------
# v0.15: custom uninstall editor for trace logs (edit, merge, export, import)
# ---------------------------------------------------------------

function Get-TraceItemKey {
    param($Item)
    return (('{0}|{1}|{2}' -f [string]$Item.Type, [string]$Item.Path, [string]$Item.Name).ToLower())
}

function Test-TraceDirInside {
    # True only for a folder directly inside the traces folder that holds a trace.json.
    param([string]$Dir, [string]$Root = $Script:TraceDir)
    if (-not $Dir) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Dir).TrimEnd('\', '/')
        $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
        $parent = [System.IO.Path]::GetDirectoryName($full)
    } catch { return $false }
    if (-not $parent -or ($parent.TrimEnd('\', '/') -ine $rootFull)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $full 'trace.json'))
}

function Get-TraceItemProblem {
    # Returns a plain-words problem, or '' when the item may be kept in a log. The same rules apply to typed, edited and imported items.
    param($Item)
    $type = [string]$Item.Type
    $path = ([string]$Item.Path).Trim()
    if ($type -notin @('Folder', 'File', 'RegistryKey', 'RunValue')) { return 'Unknown item type.' }
    if (-not $path) { return 'The path is empty.' }
    if ($path -match '[\*\?<>\|]') { return 'Wildcards and special characters are not allowed in a path.' }
    if ($type -in @('Folder', 'File')) {
        if ($path -notmatch '^([A-Za-z]:[\\/]|\\\\)') { return 'Type a full path, for example C:\Program Files\MyApp.' }
        if ($path -match '^[A-Za-z]:[\\/]*$') { return 'A drive root is not allowed.' }
        if ($path -match '(^|[\\/])\.\.([\\/]|$)') { return 'Paths with .. are not allowed.' }
        if (-not (Test-LeftoverPathAllowed -Path $path)) { return 'That path is protected (system, shared or a top-level folder).' }
        return ''
    }
    $k = ConvertTo-ExcludeKey -Text $path
    if ($k -notmatch '^(HKLM:|HKCU:)\\') { return 'Type a registry path that starts with HKLM:\ or HKCU:\.' }
    $parts = @(($k -replace '^(HKLM:|HKCU:)\\', '') -split '\\' | Where-Object { $_ })
    if ($parts.Count -lt 2) { return 'That registry key is too close to the root. Use a key for the program, such as HKCU:\Software\Vendor\Program.' }
    $isRunKey = ($type -eq 'RunValue' -and $k -match '(?i)\\Microsoft\\Windows\\CurrentVersion\\Run(Once)?$')
    if (-not $isRunKey -and $k -match '(?i)\\(Microsoft|Classes|Policies)(\\|$)' -and $k -notmatch '(?i)\\Uninstall\\') { return 'Keys under Microsoft, Classes and Policies are not handled here.' }
    $leaf = ($k -replace '^.*\\', '').ToLower()
    if (-not $isRunKey -and $Script:ProtectedLeafNames -contains $leaf) { return 'That registry key name is protected.' }
    if ($type -eq 'RunValue') {
        if (-not ([string]$Item.Name).Trim()) { return 'A startup value needs the value name.' }
        if ($k -notmatch '(?i)\\Run(Once)?$') { return 'A startup value must be in a Run key.' }
    }
    return ''
}

function Read-TraceData {
    param([string]$Dir)
    $t = Read-JsonFile -Path (Join-Path $Dir 'trace.json')
    $items = @()
    foreach ($i in @($t.Items)) { $items += [ordered]@{ Type = [string]$i.Type; Path = [string]$i.Path; Name = [string]$i.Name; Detail = [string]$i.Detail; Risk = [string]$i.Risk } }
    return [ordered]@{
        Format = 'DIVuninstaller-trace'; Name = [string]$t.Name; Started = [string]$t.Started; Finished = [string]$t.Finished
        Version = [string]$t.Version; Comment = [string]$t.Comment; Imported = [bool]$t.Imported
        Items = @($items); Services = @(@($t.Services) | ForEach-Object { [string]$_ })
    }
}

function Write-TraceData {
    param([string]$Dir, $Data)
    if (-not (Test-TraceDirInside -Dir $Dir)) { throw 'That is not a DIVuninstaller trace log folder.' }
    if ($Script:DryRun) { Write-Tag INFO '[DRY RUN] would save the trace log'; return }
    Write-JsonFile -Path (Join-Path $Dir 'trace.json') -Object $Data
}

function Set-TraceDetails {
    param([string]$Dir, [string]$Name, [string]$Comment = '')
    $nm = ([string]$Name).Trim()
    if ($nm.Length -lt 2) { throw 'The name must be at least 2 characters.' }
    if ($nm.Length -gt 80) { throw 'The name is too long (80 characters at most).' }
    if ($Comment.Length -gt 500) { throw 'The comment is too long (500 characters at most).' }
    $d = Read-TraceData -Dir $Dir
    $d.Name = $nm; $d.Comment = $Comment
    Write-TraceData -Dir $Dir -Data $d
    Write-Log -Level INFO -Action 'TRACE_EDIT' -Target $nm -Message 'details'
}

function Add-TraceItem {
    param([string]$Dir, [string]$Type, [string]$Path, [string]$Name = '')
    $path = ([string]$Path).Trim()
    if ($Type -in @('RegistryKey', 'RunValue')) { $path = ConvertTo-ExcludeKey -Text $path }
    $item = [ordered]@{ Type = $Type; Path = $path; Name = ([string]$Name).Trim(); Detail = 'Added by hand'; Risk = 'CHECK' }
    $problem = Get-TraceItemProblem -Item ([pscustomobject]$item)
    if ($problem) { throw $problem }
    $d = Read-TraceData -Dir $Dir
    $key = Get-TraceItemKey -Item ([pscustomobject]$item)
    if (@($d.Items | Where-Object { (Get-TraceItemKey -Item ([pscustomobject]$_)) -eq $key }).Count -gt 0) { throw 'That item is already in the log.' }
    $d.Items = @($d.Items) + @($item)
    Write-TraceData -Dir $Dir -Data $d
    Write-Log -Level INFO -Action 'TRACE_EDIT' -Target $path -Message 'item added'
}

function Remove-TraceItems {
    # Removes entries from the LOG only. Nothing on the PC is touched.
    param([string]$Dir, $Items)
    $keys = @(@($Items) | ForEach-Object { Get-TraceItemKey -Item $_ })
    if ($keys.Count -eq 0) { throw 'Select at least one item.' }
    $d = Read-TraceData -Dir $Dir
    $before = @($d.Items).Count
    $d.Items = @(@($d.Items) | Where-Object { $keys -notcontains (Get-TraceItemKey -Item ([pscustomobject]$_)) })
    Write-TraceData -Dir $Dir -Data $d
    Write-Log -Level INFO -Action 'TRACE_EDIT' -Target $d.Name -Message ('{0} item(s) removed from the log' -f ($before - @($d.Items).Count))
    return ($before - @($d.Items).Count)
}

function New-TraceLogFolder {
    param([string]$Name)
    return (Join-Path $Script:TraceDir ('{0}-{1}' -f (Get-Date -Format 'yyyy-MM-dd-HHmmss'), (ConvertTo-SafeFileName -Text $Name)))
}

function Merge-TraceLogs {
    # Makes a NEW log from the union of the chosen logs. The originals are kept.
    param($Dirs, [string]$Name)
    $dirs = @($Dirs)
    if ($dirs.Count -lt 2) { throw 'Select at least two logs to merge.' }
    foreach ($x in $dirs) { if (-not (Test-TraceDirInside -Dir $x)) { throw 'One of the selected folders is not a DIVuninstaller trace log.' } }
    $nm = ([string]$Name).Trim()
    if ($nm.Length -lt 2) { throw 'Type a name for the merged log.' }
    $seen = @{}; $items = @(); $svc = @()
    foreach ($x in $dirs) {
        $d = Read-TraceData -Dir $x
        foreach ($i in @($d.Items)) {
            $k = Get-TraceItemKey -Item ([pscustomobject]$i)
            if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $items += $i }
        }
        foreach ($s in @($d.Services)) { if ($svc -notcontains $s) { $svc += $s } }
    }
    $out = New-TraceLogFolder -Name $nm
    if ($Script:DryRun) { Write-Tag INFO ("[DRY RUN] would save a merged log with {0} item(s)" -f $items.Count); return '' }
    $data = [ordered]@{
        Format = 'DIVuninstaller-trace'; Name = $nm; Started = ''; Finished = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Version = $Script:Version
        Comment = ('Merged from {0} logs' -f $dirs.Count); Imported = $false; Items = @($items); Services = @($svc)
    }
    Write-JsonFile -Path (Join-Path $out 'trace.json') -Object $data
    Write-Log -Level INFO -Action 'TRACE_MERGE' -Target $nm -Result ([string]$items.Count)
    return $out
}

function Export-TraceLog {
    # Writes a copy of the log to a .json file you choose. Never overwrites an existing file.
    param([string]$Dir, [string]$Destination)
    if (-not (Test-TraceDirInside -Dir $Dir)) { throw 'That is not a DIVuninstaller trace log folder.' }
    $dest = ([string]$Destination).Trim()
    if (-not $dest) { throw 'Choose where to save the file.' }
    if ($dest -notmatch '\.json$') { throw 'The file name must end in .json.' }
    if (Test-Path -LiteralPath $dest) { throw 'A file with that name already exists. Choose another name.' }
    if ($Script:DryRun) { Write-Tag INFO ("[DRY RUN] would export the log to {0}" -f $dest); return }
    $d = Read-TraceData -Dir $Dir
    Write-JsonFile -Path $dest -Object $d
    Write-Log -Level INFO -Action 'TRACE_EXPORT' -Target $dest
}

function Import-TraceLog {
    # Reads a log file from anywhere, keeps only items that pass the same checks as typed items, and saves a NEW log.
    param([string]$Source)
    $src = ([string]$Source).Trim()
    if (-not $src -or -not (Test-Path -LiteralPath $src -PathType Leaf)) { throw 'That file was not found.' }
    if ((Get-Item -LiteralPath $src).Length -gt 5MB) { throw 'That file is too large to be a trace log (5 MB limit).' }
    try { $t = Read-JsonFile -Path $src } catch { throw 'That file is not valid JSON.' }
    if (-not $t.Name -or $null -eq $t.Items) { throw 'That file is not a DIVuninstaller trace log.' }
    $all = @($t.Items)
    if ($all.Count -gt 20000) { throw 'That log has too many items (20000 limit).' }
    $good = @(); $skipped = 0
    foreach ($i in $all) {
        $it = [ordered]@{ Type = [string]$i.Type; Path = [string]$i.Path; Name = [string]$i.Name; Detail = [string]$i.Detail; Risk = 'CHECK' }
        if ($it.Type -in @('RegistryKey', 'RunValue')) { $it.Path = ConvertTo-ExcludeKey -Text $it.Path }
        if (Get-TraceItemProblem -Item ([pscustomobject]$it)) { $skipped++; continue }
        $good += $it
    }
    if ($good.Count -eq 0) { throw 'None of the items in that file passed the safety checks, so nothing was imported.' }
    $nm = ([string]$t.Name).Trim(); if ($nm.Length -gt 80) { $nm = $nm.Substring(0, 80) }
    $out = New-TraceLogFolder -Name $nm
    if ($Script:DryRun) { Write-Tag INFO ("[DRY RUN] would import {0} item(s)" -f $good.Count); return [pscustomobject]@{ Dir = ''; Imported = $good.Count; Skipped = $skipped } }
    $data = [ordered]@{
        Format = 'DIVuninstaller-trace'; Name = $nm; Started = [string]$t.Started; Finished = [string]$t.Finished; Version = $Script:Version
        Comment = ('Imported from a file. {0} item(s) skipped by the safety checks.' -f $skipped); Imported = $true; Items = @($good); Services = @()
    }
    Write-JsonFile -Path (Join-Path $out 'trace.json') -Object $data
    Write-Log -Level INFO -Action 'TRACE_IMPORT' -Target $nm -Result ('{0} imported, {1} skipped' -f $good.Count, $skipped)
    return [pscustomobject]@{ Dir = $out; Imported = $good.Count; Skipped = $skipped }
}

# ---------------------------------------------------------------
# JUNK CLEANER (v0.16). Moves old temporary files to quarantine. Nothing is selected for you.
# Never touched: Recycle Bin, Downloads, Documents, Desktop, browser history/cookies/passwords, anything outside the folders below.
# ---------------------------------------------------------------

$Script:JunkMinAgeHours = 24
$Script:JunkMaxUnits = 5000
$Script:JunkRootLeafs = @('temp', 'crashdumps', 'minidump', 'reportarchive', 'reportqueue', 'explorer', 'cache', 'code cache', 'gpucache', 'cache2')

function Test-BrowserRunning {
    param([string]$Browser)
    $names = switch ($Browser) { 'Chrome' { @('chrome') } 'Edge' { @('msedge') } 'Brave' { @('brave') } 'Firefox' { @('firefox') } default { @() } }
    foreach ($n in $names) { if (@(Get-Process -Name $n -ErrorAction SilentlyContinue).Count -gt 0) { return $true } }
    return $false
}

function New-JunkRoot {
    param([string]$Path, [string]$Mode = 'Children', [string]$Filter = '*', [bool]$Admin = $false, [string]$Browser = '')
    return [pscustomobject]@{ Path = $Path; Mode = $Mode; Filter = $Filter; Admin = $Admin; Browser = $Browser }
}

function Join-JunkPath {
    param([string]$Base, [string]$Child)
    if (-not $Base) { return '' }
    return (Join-Path $Base $Child)
}

function Get-JunkCategories {
    $win = $env:SystemRoot
    $la = $env:LOCALAPPDATA
    $pd = $env:ProgramData
    $cats = @()
    $cats += [pscustomobject]@{ Key = 'UserTemp'; Name = 'User temp files'; Note = 'Files in your temp folder that have not changed for 24 hours.'
        Roots = @((New-JunkRoot -Path $env:TEMP)) }
    $cats += [pscustomobject]@{ Key = 'WindowsTemp'; Name = 'Windows temp files'; Note = 'Old files in the Windows temp folder. Needs Administrator.'
        Roots = @((New-JunkRoot -Path (Join-JunkPath $win 'Temp') -Admin $true)) }
    $cats += [pscustomobject]@{ Key = 'CrashDumps'; Name = 'Crash dumps'; Note = 'Old .dmp files from crashed programs. Keep them if you are chasing a crash.'
        Roots = @((New-JunkRoot -Path (Join-JunkPath $la 'CrashDumps') -Mode 'Files' -Filter '*.dmp'), (New-JunkRoot -Path (Join-JunkPath $win 'Minidump') -Mode 'Files' -Filter '*.dmp' -Admin $true)) }
    $cats += [pscustomobject]@{ Key = 'ErrorReports'; Name = 'Windows error reports'; Note = 'Old Windows Error Reporting archives and queue. Newer reports are kept.'
        Roots = @((New-JunkRoot -Path (Join-JunkPath $la 'Microsoft\Windows\WER\ReportArchive')), (New-JunkRoot -Path (Join-JunkPath $la 'Microsoft\Windows\WER\ReportQueue')),
                  (New-JunkRoot -Path (Join-JunkPath $pd 'Microsoft\Windows\WER\ReportArchive') -Admin $true), (New-JunkRoot -Path (Join-JunkPath $pd 'Microsoft\Windows\WER\ReportQueue') -Admin $true)) }
    $cats += [pscustomobject]@{ Key = 'Thumbnails'; Name = 'Thumbnail cache'; Note = 'Explorer rebuilds it. Some files may be in use and are skipped.'
        Roots = @((New-JunkRoot -Path (Join-JunkPath $la 'Microsoft\Windows\Explorer') -Mode 'Files' -Filter 'thumbcache_*.db')) }
    $br = @()
    $chromium = @(
        @{ B = 'Chrome'; P = (Join-JunkPath $la 'Google\Chrome\User Data') },
        @{ B = 'Edge'; P = (Join-JunkPath $la 'Microsoft\Edge\User Data') },
        @{ B = 'Brave'; P = (Join-JunkPath $la 'BraveSoftware\Brave-Browser\User Data') }
    )
    foreach ($c in $chromium) {
        if (-not $c.P -or -not (Test-Path -LiteralPath $c.P)) { continue }
        foreach ($prof in @(Get-ChildItem -LiteralPath $c.P -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
            foreach ($sub in @('Cache', 'Code Cache', 'GPUCache')) {
                $br += (New-JunkRoot -Path (Join-Path $prof.FullName $sub) -Mode 'Roots' -Browser $c.B)
            }
        }
    }
    $ffp = Join-JunkPath $la 'Mozilla\Firefox\Profiles'
    if ($ffp -and (Test-Path -LiteralPath $ffp)) {
        foreach ($prof in @(Get-ChildItem -LiteralPath $ffp -Directory -Force -ErrorAction SilentlyContinue)) {
            $br += (New-JunkRoot -Path (Join-Path $prof.FullName 'cache2') -Mode 'Roots' -Browser 'Firefox')
        }
    }
    $cats += [pscustomobject]@{ Key = 'BrowserCache'; Name = 'Browser caches'; Note = 'Cached web files only (Chrome, Edge, Brave, Firefox). History, cookies, passwords and sign-ins are not touched. The browser must be closed. Pages may load a little slower once.'
        Roots = @($br) }
    return @($cats)
}

function Test-JunkRootSane {
    # A root must be a real folder path (not a drive root, not a profile or system root) whose name is one of the known junk folder names.
    param([string]$Path)
    if (-not $Path) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') } catch { return $false }
    if ($full.Length -le 10) { return $false }
    if ($Path -match '(^|[\\/])\.\.([\\/]|$)') { return $false }
    foreach ($r in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $env:SystemDrive)) {
        if ($r -and ($full -ieq $r.TrimEnd('\', '/'))) { return $false }
    }
    $leaf = (Split-Path -Leaf $full).ToLower()
    return ($Script:JunkRootLeafs -contains $leaf)
}

function Test-JunkPathAllowed {
    # The item must be exactly the root (Roots mode) or a direct child of the root (Children and Files mode).
    param([string]$Path, $Root)
    if (-not (Test-JunkRootSane -Path $Root.Path)) { return $false }
    if ($Path -match '(^|[\\/])\.\.([\\/]|$)') { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        $rootFull = [System.IO.Path]::GetFullPath([string]$Root.Path).TrimEnd('\', '/')
        $parent = [System.IO.Path]::GetDirectoryName($full)
    } catch { return $false }
    if ($Root.Mode -eq 'Roots') { return ($full -ieq $rootFull) }
    if (-not $parent) { return $false }
    return ($parent.TrimEnd('\', '/') -ieq $rootFull)
}

function Test-IsReparsePoint {
    param($Item)
    return (([int]$Item.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-JunkNewestTime {
    # Newest write time of a file, or of anything inside a folder.
    param($Item)
    $t = $Item.LastWriteTime
    if ($Item.PSIsContainer) {
        foreach ($f in @(Get-ChildItem -LiteralPath $Item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)) { if ($f.LastWriteTime -gt $t) { $t = $f.LastWriteTime } }
    }
    return $t
}

function Get-JunkUnits {
    param($Category, [int]$MinAgeHours = $Script:JunkMinAgeHours)
    $cutoff = (Get-Date).AddHours(-$MinAgeHours)
    $units = New-Object System.Collections.Generic.List[object]
    $blocked = @(); $recent = 0; $truncated = $false
    $isAdmin = Test-Administrator
    $browsersChecked = @{}
    foreach ($root in @($Category.Roots)) {
        if ($root.Admin -and -not $isAdmin) { $m = 'Needs Administrator: ' + $root.Path; if ($blocked -notcontains $m) { $blocked += $m }; continue }
        if ($root.Browser) {
            if (-not $browsersChecked.ContainsKey($root.Browser)) { $browsersChecked[$root.Browser] = (Test-BrowserRunning -Browser $root.Browser) }
            if ($browsersChecked[$root.Browser]) { $m = ('{0} is running. Close it first.' -f $root.Browser); if ($blocked -notcontains $m) { $blocked += $m }; continue }
        }
        if (-not $root.Path -or -not (Test-Path -LiteralPath $root.Path)) { continue }
        if (-not (Test-JunkRootSane -Path $root.Path)) { $blocked += ('Folder not allowed: ' + $root.Path); continue }
        if ($root.Mode -eq 'Roots') {
            $it = Get-Item -LiteralPath $root.Path -Force -ErrorAction SilentlyContinue
            if (-not $it -or -not $it.PSIsContainer -or (Test-IsReparsePoint -Item $it)) { continue }
            $st = Get-FolderStats -Path $root.Path
            if ($st.Files -eq 0) { continue }
            $units.Add([pscustomobject]@{ Category = $Category.Key; Type = 'Folder'; Path = $it.FullName; Name = $it.Name; Bytes = [long]$st.Bytes; Files = [int]$st.Files; Newest = $it.LastWriteTime; Root = $root })
            continue
        }
        foreach ($c in @(Get-ChildItem -LiteralPath $root.Path -Force -ErrorAction SilentlyContinue)) {
            if (Test-IsReparsePoint -Item $c) { continue }
            if ($c.PSIsContainer) { if ($root.Mode -eq 'Files') { continue } }
            elseif ($c.Name -notlike $root.Filter) { continue }
            if ($units.Count -ge $Script:JunkMaxUnits) { $truncated = $true; break }
            $newest = Get-JunkNewestTime -Item $c
            if ($newest -gt $cutoff) { $recent++; continue }
            $bytes = [long]0; $files = 1
            if ($c.PSIsContainer) { $st = Get-FolderStats -Path $c.FullName; $bytes = [long]$st.Bytes; $files = [int]$st.Files } else { $bytes = [long]$c.Length }
            $units.Add([pscustomobject]@{ Category = $Category.Key; Type = $(if ($c.PSIsContainer) { 'Folder' } else { 'File' }); Path = $c.FullName; Name = $c.Name; Bytes = $bytes; Files = $files; Newest = $newest; Root = $root })
        }
    }
    return [pscustomobject]@{ Units = @($units.ToArray()); RecentSkipped = $recent; Blocked = @($blocked); Truncated = $truncated }
}

function Get-JunkScan {
    # Read-only. One row per category with sizes.
    param($Categories = $null, [int]$MinAgeHours = $Script:JunkMinAgeHours)
    if ($null -eq $Categories) { $Categories = @(Get-JunkCategories) }
    $rows = @(); $k = 0
    foreach ($c in @($Categories)) {
        Write-Busy -Activity 'Looking for junk (read-only)' -Status $c.Name -Percent ([int](100 * $k / [math]::Max(1, @($Categories).Count)))
        $k++
        $u = Get-JunkUnits -Category $c -MinAgeHours $MinAgeHours
        $sum = [long]0; $files = 0
        foreach ($x in @($u.Units)) { $sum += [long]$x.Bytes; $files += [int]$x.Files }
        $rows += [pscustomobject]@{ Category = $c; Key = $c.Key; Name = $c.Name; Note = $c.Note; Units = @($u.Units); Bytes = $sum; Files = $files; RecentSkipped = $u.RecentSkipped; Blocked = @($u.Blocked); Truncated = $u.Truncated }
    }
    Write-Busy -Activity 'Looking for junk (read-only)' -Status 'Done' -Percent 100
    return @($rows)
}

function Move-JunkToQuarantine {
    # Every unit is checked again right before it is moved. -Permanent deletes the quarantine entry afterwards (cannot be undone).
    param($Category, $Units, [switch]$Permanent, [string]$QuarantineRoot = $Script:QuarantineDir, [int]$MinAgeHours = $Script:JunkMinAgeHours)
    $stamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
    $dir = Join-Path $QuarantineRoot ('{0}-{1}' -f $stamp, (ConvertTo-SafeFileName -Text ('Junk cleaner - ' + $Category.Name)))
    if ($Script:DryRun) {
        foreach ($u in @($Units)) { Write-Tag INFO ("[DRY RUN] would quarantine {0}: {1}" -f $u.Type, $u.Path) }
        return [pscustomobject]@{ Dir = ''; Moved = 0; Failed = 0; Bytes = [long]0; Permanent = $false; Results = @() }
    }
    New-Item -ItemType Directory -Path (Join-Path $dir 'files') -Force | Out-Null
    $cutoff = (Get-Date).AddHours(-$MinAgeHours)
    $excl = @(Get-ExcludeList)
    $entries = New-Object System.Collections.Generic.List[object]
    $moved = 0; $failed = 0; $n = 0; $bytes = [long]0
    $browserRun = @{}
    foreach ($u in @($Units)) {
        $n++
        $e = [ordered]@{ Type = $u.Type; Path = $u.Path; Name = ''; QuarantinePath = ''; Result = 'failed'; Note = '' }
        try {
            if (-not (Test-JunkPathAllowed -Path $u.Path -Root $u.Root)) { throw 'This path is not in a junk folder, so it was not touched.' }
            if (Test-LeftoverExcluded -Path $u.Path -Name '' -Patterns $excl) { throw 'It is on the exclude list, so it was left alone.' }
            if ($u.Root.Admin -and -not (Test-Administrator)) { throw 'Needs Administrator.' }
            if ($u.Root.Browser) {
                if (-not $browserRun.ContainsKey($u.Root.Browser)) { $browserRun[$u.Root.Browser] = (Test-BrowserRunning -Browser $u.Root.Browser) }
                if ($browserRun[$u.Root.Browser]) { throw ('{0} is running. Close it first.' -f $u.Root.Browser) }
            }
            $it = Get-Item -LiteralPath $u.Path -Force -ErrorAction Stop
            if (Test-IsReparsePoint -Item $it) { throw 'It is a link, so it was left alone.' }
            if ($u.Root.Mode -ne 'Roots' -and (Get-JunkNewestTime -Item $it) -gt $cutoff) { throw 'It changed in the last 24 hours, so it was kept.' }
            $dest = Join-Path (Join-Path $dir 'files') ('{0:D4}_{1}' -f $n, (ConvertTo-SafeFileName -Text (Split-Path -Leaf $u.Path)))
            if (($n % 25) -eq 1) { Write-Command ("Move-Item -LiteralPath '{0}' -Destination '{1}'" -f $u.Path, $dest) }
            Move-Item -LiteralPath $u.Path -Destination $dest -ErrorAction Stop
            $e.QuarantinePath = $dest; $e.Result = 'moved'
            $moved++; $bytes += [long]$u.Bytes
        } catch {
            $failed++
            $e.Note = $_.Exception.Message
        }
        if (($n % 50) -eq 0) { Write-Busy -Activity ('Moving ' + $Category.Name) -Status ('{0} moved, {1} skipped' -f $moved, $failed) }
        $entries.Add([pscustomobject]$e)
    }
    Write-Log -Level INFO -Action 'JUNK_MOVE' -Target $Category.Name -Result ('{0} moved, {1} skipped' -f $moved, $failed)
    Write-JsonFile -Path (Join-Path $dir 'manifest.json') -Object ([ordered]@{
        Program = ('Junk cleaner: ' + $Category.Name); Created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Version = $Script:Version; Entries = @($entries.ToArray())
    })
    $deleted = $false
    if ($Permanent) {
        if ($moved -gt 0) { Remove-QuarantineFolder -Dir $dir -Root $QuarantineRoot; $deleted = $true }
        else { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    } elseif ($moved -eq 0) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ Dir = $(if ($deleted -or $moved -eq 0) { '' } else { $dir }); Moved = $moved; Failed = $failed; Bytes = $bytes; Permanent = $deleted; Results = @($entries.ToArray()) }
}

function Get-QuarantineList {
    param([string]$Root = $Script:QuarantineDir)
    $out = @()
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        $mf = Join-Path $d.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $mf)) { continue }
        try {
            $m = Read-JsonFile -Path $mf
            $size = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if (-not $size) { $size = 0 }
            $out += [pscustomobject]@{ Id = $d.Name; Path = $d.FullName; Program = [string]$m.Program; Created = [string]$m.Created; Count = @($m.Entries | Where-Object { $_.Result -eq 'moved' }).Count; SizeBytes = [long]$size; Manifest = $m }
        } catch { Write-Log -Level WARN -Action 'QUARANTINE_LIST' -Target $d.FullName -ErrorText $_.Exception.Message }
    }
    return @($out | Sort-Object Id -Descending)
}

function Remove-QuarantineFolder {
    # PERMANENT. Only ever deletes a folder that sits directly inside the quarantine folder.
    param([string]$Dir, [string]$Root = $Script:QuarantineDir)
    $full = [System.IO.Path]::GetFullPath($Dir).TrimEnd('\', '/')
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $parent = [System.IO.Path]::GetDirectoryName($full)
    if (-not $parent -or ($parent.TrimEnd('\', '/') -ine $rootFull)) { throw 'That folder is not inside the DIVuninstaller quarantine, so it was not deleted.' }
    if (-not (Test-Path -LiteralPath (Join-Path $full 'manifest.json'))) { throw 'That folder has no quarantine manifest, so it was not deleted.' }
    Write-Command ("Remove-Item -LiteralPath '{0}' -Recurse -Force" -f $full)
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    Write-Log -Level INFO -Action 'QUARANTINE_DELETE' -Target $full
}

function Update-GuiProgramList {
    param([string]$Filter = '')
    $lb = $Script:GuiProgList
    $lb.Items.Clear()
    $all = @($Script:GuiProgAll)
    switch ([string]$Script:GuiProgSort) {
        'Size'      { $all = @($all | Sort-Object -Property SizeKB -Descending) }
        'Installed' { $all = @($all | Sort-Object -Property @{ Expression = { if ($_.InstallDate -match '^\d{8}$') { $_.InstallDate } else { '00000000' } } } -Descending) }
        'Publisher' { $all = @($all | Sort-Object -Property Publisher, Name) }
        default     { $all = @($all | Sort-Object -Property Name) }
    }
    $shown = 0
    foreach ($p in $all) {
        if ($Filter -and ($p.Name -notlike ('*' + $Filter + '*')) -and ($p.Publisher -notlike ('*' + $Filter + '*'))) { continue }
        $item = New-Object System.Windows.Controls.ListBoxItem
        $sz = ''
        if ($p.SizeKB -gt 0) { $sz = Format-Bytes ([double]$p.SizeKB * 1024) }
        $tag = ''
        if ($p.Protected) { $tag = '   [protected]' }
        $item.Content = ("{0}    {1}    {2}    {3}{4}" -f $p.Name, $p.Version, $p.Publisher, $sz, $tag)
        $item.Tag = $p
        [void]$lb.Items.Add($item)
        $shown++
    }
    Set-GuiStatus ("{0} program(s) shown. Protected programs cannot be uninstalled here." -f $shown)
}

function Get-GuiScanModeKey {
    if ((Get-UninstallerSettings).OnlyBuiltIn) { return 'None' }
    switch -Wildcard ([string]$Script:GuiUninstallMode) {
        'Built-in*' { return 'None' }
        'Safe*'     { return 'Safe' }
        'Advanced*' { return 'Advanced' }
        default     { return 'Moderate' }
    }
}

function Start-GuiLeftoverStage {
    # After an uninstall (or a forced removal): scan at the chosen level and show the result.
    param($Program, [string]$Mode, [string]$RecordDir, $Others)
    if ($Mode -eq 'None') {
        Update-UninstallRecord -Dir $RecordDir -Values @{ Mode = 'Built-in'; LeftoversFound = 0; LeftoversMoved = 0 }
        Show-GuiMessage 'The uninstaller finished. Built-in mode does not scan for leftovers.' 'DIVuninstaller'
        Show-GuiUninstaller
        return
    }
    $left = @(Invoke-GuiWithBusy -Title 'Looking for leftovers' -Detail ("Scan level: {0}. Checking by exact name. Nothing is changed." -f $Mode) -Action { Get-ProgramLeftovers -Program $Program -OtherPrograms $Others -Mode $Mode })
    Update-UninstallRecord -Dir $RecordDir -Values @{ Mode = $Mode; LeftoversFound = $left.Count }
    Show-GuiLeftovers -Program $Program -Items $left -OtherPrograms $Others -RecordDir $RecordDir -Mode $Mode
}

function Show-GuiUninstaller {
    Reset-GuiPage -Title 'DIVuninstaller' -Subtitle 'Uninstall a program with its own uninstaller, then clear what it leaves behind. Nothing is removed without your approval.'
    if (-not $Script:GuiUninstallMode) { $Script:GuiUninstallMode = 'Moderate' }
    if (-not $Script:GuiProgSort) { $Script:GuiProgSort = 'Name' }
    $Script:GuiProgAll = @(Invoke-GuiWithBusy -Title 'Reading installed programs' -Detail 'Reading the list Windows keeps. This does not change anything.' -Action { Get-InstalledPrograms })

    $row = New-Object System.Windows.Controls.WrapPanel
    $box = New-Object System.Windows.Controls.TextBox
    $box.Width = 300; $box.Margin = '0,0,10,8'; $box.Padding = '8,6'
    $box.Background = (Get-GuiBrush '#131D33'); $box.Foreground = (Get-GuiBrush '#E8EEF8'); $box.BorderBrush = (Get-GuiBrush '#25324D')
    $box.ToolTip = 'Type to filter by name or publisher'
    $Script:GuiProgFilter = $box
    Add-GuiChild $row $box
    $sortLbl = New-GuiText -Text 'Sort by' -Size 11 -Color '#8DA0BF' -Margin '6,6,6,0'
    Add-GuiChild $row $sortLbl
    $sortCmb = New-Object System.Windows.Controls.ComboBox
    $sortCmb.Width = 120; $sortCmb.Margin = '0,0,10,8'
    foreach ($v in @('Name', 'Size', 'Installed', 'Publisher')) { [void]$sortCmb.Items.Add($v) }
    $sortCmb.SelectedItem = [string]$Script:GuiProgSort
    Add-GuiChild $row $sortCmb
    Add-GuiChild $Script:GuiContent $row

    $lb = New-Object System.Windows.Controls.ListBox
    $lb.Height = 300
    $lb.SelectionMode = 'Extended'
    $lb.Background = (Get-GuiBrush '#131D33'); $lb.Foreground = (Get-GuiBrush '#E8EEF8')
    $Script:GuiProgList = $lb
    Add-GuiChild $Script:GuiContent $lb

    $det = New-GuiText -Text 'Select a program to see its details. Hold Ctrl or Shift to select several and uninstall them in one go.' -Size 12 -Color '#8DA0BF' -Margin '0,8,0,0'
    $Script:GuiProgDetails = $det
    Add-GuiChild $Script:GuiContent $det
    $lb.Add_SelectionChanged({
        $it = $Script:GuiProgList.SelectedItem
        $cnt = @($Script:GuiProgList.SelectedItems).Count
        if ($cnt -gt 1) { $Script:GuiProgDetails.Text = ('{0} programs selected. UNINSTALL removes them one after another with ONE restore point.' -f $cnt) }
        elseif ($it) { $Script:GuiProgDetails.Text = (Get-ProgramDetailsText -Program $it.Tag) } else { $Script:GuiProgDetails.Text = 'Select a program to see its details.' }
    })
    $box.Add_TextChanged({ Update-GuiProgramList -Filter ([string]$Script:GuiProgFilter.Text) })
    $sortCmb.Add_SelectionChanged({ param($s, $e) $Script:GuiProgSort = [string]$s.SelectedItem; Update-GuiProgramList -Filter ([string]$Script:GuiProgFilter.Text) })
    Update-GuiProgramList -Filter ''

    $modeRow = New-Object System.Windows.Controls.WrapPanel
    $modeRow.Margin = '0,10,0,0'
    Add-GuiChild $modeRow (New-GuiText -Text 'Leftover scan level' -Size 12 -Color '#8DA0BF' -Margin '0,6,10,0')
    $modeCmb = New-Object System.Windows.Controls.ComboBox
    $modeCmb.Width = 200
    foreach ($v in @('Built-in (no scan)', 'Safe', 'Moderate', 'Advanced')) { [void]$modeCmb.Items.Add($v) }
    foreach ($v in @($modeCmb.Items)) { if (([string]$v) -like ($Script:GuiUninstallMode + '*')) { $modeCmb.SelectedItem = $v } }
    if (-not $modeCmb.SelectedItem) { $modeCmb.SelectedItem = 'Moderate' }
    Add-GuiChild $modeRow $modeCmb
    Add-GuiChild $Script:GuiContent $modeRow
    $modeTxt = New-GuiText -Text (Get-ScanModeDescription -Mode (Get-GuiScanModeKey)) -Size 11 -Color '#6F82A3' -Margin '0,4,0,0'
    $Script:GuiModeText = $modeTxt
    Add-GuiChild $Script:GuiContent $modeTxt
    $modeCmb.Add_SelectionChanged({ param($s, $e) $Script:GuiUninstallMode = [string]$s.SelectedItem; $Script:GuiModeText.Text = (Get-ScanModeDescription -Mode (Get-GuiScanModeKey)) })

    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = '0,10,0,0'
    Add-GuiChild $bar (New-GuiButton -Text 'UNINSTALL' -Bg '#238636' -OnClick {
        $multi = @($Script:GuiProgList.SelectedItems)
        if ($multi.Count -gt 1) { Start-GuiBatchUninstall -Selected $multi; return }
        $it = $Script:GuiProgList.SelectedItem
        if (-not $it) { Show-GuiMessage 'Select a program first.'; return }
        $p = $it.Tag
        if ($p.Protected) { Show-GuiMessage ("{0} is a protected program (system, runtime, driver or security software).`n`nUse Windows Settings > Apps if you really want to remove it." -f $p.Name) 'Protected' 'Warning'; return }
        $cmd = Split-UninstallCommand -Text $p.UninstallString
        if (-not $cmd) { Show-GuiMessage ("The uninstall command for {0} could not be read safely, so nothing was run.`n`nIf the uninstaller is missing or broken, use FORCED UNINSTALL." -f $p.Name) 'DIVuninstaller' 'Warning'; return }
        $mode = Get-GuiScanModeKey
        $txt = "Uninstall {0} {1}?`n`nDIVuninstaller will:`n 1. Create a restore point (if Windows allows it)`n 2. Back up the program's registry entry`n 3. Run the program's own uninstaller (it may open its own windows)`n 4. {2}`n`nNothing is deleted without your approval.`n`nCommand that will run:`n{3} {4}" -f $p.Name, $p.Version, $(if ($mode -eq 'None') { 'Stop (Built-in mode: no leftover scan)' } else { 'Scan for leftovers (' + $mode + ') and show them to you' }), $cmd.File, $cmd.Arguments
        if (-not (Confirm-Gui $txt 'Confirm uninstall' 'Warning')) { return }
        try {
            $r = Invoke-GuiWithBusy -Title ('Uninstalling ' + $p.Name) -Detail 'Finish the uninstaller window that opened. DIVuninstaller continues when it closes.' -Action { Invoke-ProgramUninstall -Program $p }
        } catch {
            Write-Log -Level FAIL -Action 'UNINSTALL' -Target $p.Name -ErrorText $_.Exception.Message
            Show-GuiMessage $_.Exception.Message 'Uninstall failed' 'Error'
            return
        }
        if ($r.StillInstalled) {
            Update-UninstallRecord -Dir $r.BackupDir -Values @{ Mode = $mode; LeftoversFound = 0; LeftoversMoved = 0 }
            Show-GuiMessage ("{0} still appears to be installed (the uninstaller returned {1}). It may have been cancelled.`n`nLeftovers are only scanned once the program is gone. If the uninstaller is broken, use FORCED UNINSTALL." -f $p.Name, $r.ExitCode) 'DIVuninstaller' 'Warning'
            Show-GuiUninstaller
            return
        }
        $others = @($Script:GuiProgAll | Where-Object { $_.KeyPath -ne $p.KeyPath })
        Start-GuiLeftoverStage -Program $p -Mode $mode -RecordDir $r.BackupDir -Others $others
    })
    Add-GuiChild $bar (New-GuiButton -Text 'FORCED UNINSTALL' -OnClick {
        $it = $Script:GuiProgList.SelectedItem
        if (-not $it) { Show-GuiMessage 'Select a program first.'; return }
        $p = $it.Tag
        if ($p.Protected) { Show-GuiMessage ("{0} is a protected program and cannot be removed here." -f $p.Name) 'Protected' 'Warning'; return }
        $txt = "Forced uninstall of {0}?`n`nUse this only when the program's own uninstaller is missing or broken.`n`nDIVuninstaller will NOT run the program's uninstaller. It will:`n 1. Create a restore point (if Windows allows it)`n 2. Back up the program's registry entry`n 3. Scan at the Advanced level and show everything it finds, including the program's own uninstall entry`n`nNothing is selected for you, and nothing is deleted until you choose it." -f $p.Name
        if (-not (Confirm-Gui $txt 'Confirm forced uninstall' 'Warning')) { return }
        try {
            $r = Invoke-GuiWithBusy -Title 'Preparing forced uninstall' -Detail 'Creating a restore point and backing up the program entry...' -Action { Invoke-ProgramUninstall -Program $p -SkipUninstaller }
        } catch {
            Write-Log -Level FAIL -Action 'FORCED_UNINSTALL' -Target $p.Name -ErrorText $_.Exception.Message
            Show-GuiMessage $_.Exception.Message 'Forced uninstall failed' 'Error'
            return
        }
        $others = @($Script:GuiProgAll | Where-Object { $_.KeyPath -ne $p.KeyPath })
        Start-GuiLeftoverStage -Program $p -Mode 'Advanced' -RecordDir $r.BackupDir -Others $others
    })
    Add-GuiChild $bar (New-GuiButton -Text 'OPEN FOLDER' -OnClick {
        $it = $Script:GuiProgList.SelectedItem
        if (-not $it) { Show-GuiMessage 'Select a program first.'; return }
        $loc = [string]$it.Tag.InstallLocation
        if ($loc -and (Test-Path -LiteralPath $loc)) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $loc + '"') } else { Show-GuiMessage 'This program does not record an install folder, or the folder is gone.' }
    })
    Add-GuiChild $bar (New-GuiButton -Text 'FORCED BY NAME' -OnClick { Show-GuiForcedByName })
    Add-GuiChild $bar (New-GuiButton -Text 'WINDOWS APPS' -OnClick { Show-GuiWindowsApps })
    Add-GuiChild $bar (New-GuiButton -Text 'INSTALL MONITOR' -OnClick { Show-GuiInstallMonitor })
    Add-GuiChild $bar (New-GuiButton -Text 'BROWSER EXTENSIONS' -OnClick { Show-GuiBrowserExtensions })
    Add-GuiChild $bar (New-GuiButton -Text 'STARTUP MANAGER' -OnClick { Show-GuiStartup })
    Add-GuiChild $bar (New-GuiButton -Text 'LOGS' -OnClick { Show-GuiUninstallLogs })
    Add-GuiChild $bar (New-GuiButton -Text 'QUARANTINE' -OnClick { Show-GuiQuarantine })
    Add-GuiChild $bar (New-GuiButton -Text 'JUNK CLEANER' -OnClick { Show-GuiJunkCleaner })
    Add-GuiChild $bar (New-GuiButton -Text 'EXCLUDE LIST' -OnClick { Show-GuiExcludeList })
    Add-GuiChild $bar (New-GuiButton -Text 'OPTIONS' -OnClick { Show-GuiUninstallerOptions })
    Add-GuiChild $bar (New-GuiButton -Text 'REFRESH' -OnClick { Show-GuiUninstaller })
    Add-GuiChild $Script:GuiContent $bar
    Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Windows components, runtimes, drivers and security software are marked protected. Leftovers are matched by exact name only, so some may be missed rather than risk removing something shared.' -Size 11 -Color '#6F82A3' -Margin '0,10,0,0')
}

function New-GuiLeftoverMenu {
    # Right-click menu for one leftover. The check box carries the item in its Tag.
    param($CheckBox)
    $item = $CheckBox.Tag
    $m = New-Object System.Windows.Controls.ContextMenu
    if ($item.Type -in @('RegistryKey', 'RunValue')) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = 'Open in Regedit'
        $mi.Tag = $CheckBox
        $mi.Add_Click({
            param($s, $e)
            try { [void](Open-RegistryKeyInRegedit -Path $s.Tag.Tag.Path) } catch { Show-GuiMessage $_.Exception.Message 'Regedit' 'Warning' }
        })
        [void]$m.Items.Add($mi)
    } else {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = 'Open containing folder'
        $mi.Tag = $CheckBox
        $mi.Add_Click({
            param($s, $e)
            try { Open-LeftoverFolder -Path $s.Tag.Tag.Path } catch { Show-GuiMessage $_.Exception.Message 'Open folder' 'Warning' }
        })
        [void]$m.Items.Add($mi)
    }
    $ex = New-Object System.Windows.Controls.MenuItem
    $ex.Header = 'Add to exclude list (never touch)'
    $ex.Tag = $CheckBox
    $ex.Add_Click({
        param($s, $e)
        $cb = $s.Tag
        $it = $cb.Tag
        try {
            $pat = [string]$it.Path
            if ($it.Type -eq 'RunValue') { $pat = $pat + '\' + $it.Name }
            [void](Add-ExcludeEntry -Pattern $pat)
            $it.Status = 'Protected'
            $cb.IsChecked = $false
            $cb.IsEnabled = $false
            $cb.FontWeight = 'Normal'
            $cb.Foreground = (Get-GuiBrush '#F85149')
        } catch { Show-GuiMessage $_.Exception.Message 'Exclude list' 'Warning' }
    })
    [void]$m.Items.Add($ex)
    return $m
}

function New-GuiLeftoverCheckBox {
    # Bold = matched to this program (can be selected). Red = on the exclude list (never touched).
    param($Item, [bool]$CheckAll = $false)
    $cb = New-Object System.Windows.Controls.CheckBox
    $sz = ''
    if ($Item.SizeBytes -gt 0) { $sz = '   ' + (Format-Bytes $Item.SizeBytes) }
    $what = $Item.Path
    if ($Item.Name) { $what = $Item.Path + '  ->  ' + $Item.Name }
    $cb.Content = ("{0}   {1}{2}   [{3}]`n{4}" -f $Item.Type, $what, $sz, $Item.Risk, $Item.Detail)
    $cb.Tag = $Item
    $cb.Margin = '12,2,0,2'
    if ($Item.Status -eq 'Protected') {
        $cb.IsEnabled = $false
        $cb.IsChecked = $false
        $cb.Foreground = (Get-GuiBrush '#F85149')
        $cb.ToolTip = 'On your exclude list. It will never be touched.'
    } else {
        $cb.FontWeight = 'Bold'
        $cb.IsChecked = $CheckAll
    }
    $cb.ContextMenu = (New-GuiLeftoverMenu -CheckBox $cb)
    return $cb
}

function Show-GuiLeftovers {
    param($Program, $Items, $OtherPrograms = @(), [string]$RecordDir = '', [string]$Mode = '', [switch]$Batch)
    $settings = Get-UninstallerSettings
    $Script:GuiLeftBatch = [bool]$Batch
    $sub = 'Scan level: {0}. Bold items were matched to this program and can be selected. Grey lines only show where they sit. Red items are on your exclude list and are never touched. Right-click an item for more. Selected items go to quarantine, and registry keys are exported first.' -f $Mode
    Reset-GuiPage -Title ('Leftovers of ' + $Program.Name) -Subtitle $sub
    $Script:GuiLeftChecks = New-Object System.Collections.Generic.List[object]
    $Script:GuiLeftProgram = $Program
    $Script:GuiLeftOthers = $OtherPrograms
    $Script:GuiLeftRecord = $RecordDir
    $items = @($Items)
    if ($items.Count -eq 0) {
        Add-GuiChild $Script:GuiContent (New-GuiText -Text 'No leftovers were found by exact name.' -Size 14 -Margin '0,10,0,10')
        Add-GuiChild $Script:GuiContent (New-GuiButton -Text 'DONE' -Width 160 -OnClick { Show-GuiUninstaller })
        Set-GuiStatus 'Done. Nothing else was changed.'
        return
    }
    $sp = New-Object System.Windows.Controls.StackPanel
    $lastParent = $null
    foreach ($i in @($items | Sort-Object -Property Parent, Path)) {
        if ($i.Parent -ne $lastParent) {
            Add-GuiChild $sp (New-GuiText -Text ('In ' + $i.Parent) -Size 11 -Color '#6F82A3' -Margin '0,8,0,2')
            $lastParent = $i.Parent
        }
        $cb = New-GuiLeftoverCheckBox -Item $i -CheckAll ([bool]$settings.CheckAllByDefault)
        [void]$Script:GuiLeftChecks.Add($cb)
        Add-GuiChild $sp $cb
    }
    Add-GuiChild $Script:GuiContent $sp
    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = '0,12,0,0'
    Add-GuiChild $bar (New-GuiButton -Text 'SELECT ALL LOW-RISK' -Width 190 -OnClick {
        foreach ($c in @($Script:GuiLeftChecks)) { if ($c.IsEnabled) { $c.IsChecked = ($c.Tag.Risk -eq 'LOW') } }
    })
    Add-GuiChild $bar (New-GuiButton -Text 'SELECT ALL' -Width 130 -OnClick {
        foreach ($c in @($Script:GuiLeftChecks)) { if ($c.IsEnabled) { $c.IsChecked = $true } }
    })
    Add-GuiChild $bar (New-GuiButton -Text 'SELECT NONE' -Width 130 -OnClick {
        foreach ($c in @($Script:GuiLeftChecks)) { $c.IsChecked = $false }
    })
    Add-GuiChild $bar (New-GuiButton -Text 'MOVE SELECTED TO QUARANTINE' -Bg '#238636' -Width 260 -OnClick {
        $sel = @($Script:GuiLeftChecks | Where-Object { $_.IsChecked -and $_.IsEnabled } | ForEach-Object { $_.Tag })
        if ($sel.Count -eq 0) { Show-GuiMessage 'Select at least one item, or press SKIP.'; return }
        $list = (@($sel | ForEach-Object { '{0}: {1}' -f $_.Type, $_.Path }) -join "`n")
        if (-not (Confirm-Gui ("Move these {0} item(s) to quarantine?`n`n{1}`n`nRegistry keys are exported first. You can restore everything from the Quarantine page." -f $sel.Count, $list) 'Confirm cleanup' 'Warning')) { return }
        if ($Script:GuiLeftBatch) {
            $r = Invoke-GuiWithBusy -Title 'Moving leftovers to quarantine' -Detail 'Exporting registry keys and moving folders...' -Action { Move-BatchLeftovers -Items $sel -OtherPrograms $Script:GuiLeftOthers }
        } else {
            $r = Invoke-GuiWithBusy -Title 'Moving leftovers to quarantine' -Detail 'Exporting registry keys and moving folders...' -Action { Move-LeftoversToQuarantine -Items $sel -ProgramName $Script:GuiLeftProgram.Name -OtherPrograms $Script:GuiLeftOthers }
            Update-UninstallRecord -Dir $Script:GuiLeftRecord -Values @{ LeftoversMoved = $r.Moved; Quarantine = $r.Dir }
        }
        $msg = ("Moved {0} item(s) to quarantine." -f $r.Moved)
        if ($r.Failed -gt 0) { $msg += ("`n{0} item(s) could not be moved and were left alone. See the PowerShell window and the log." -f $r.Failed) }
        Show-GuiMessage $msg 'DIVuninstaller'
        Show-GuiUninstaller
    })
    Add-GuiChild $bar (New-GuiButton -Text 'SKIP' -Width 120 -OnClick {
        Update-UninstallRecord -Dir $Script:GuiLeftRecord -Values @{ LeftoversMoved = 0 }
        Show-GuiUninstaller
    })
    Add-GuiChild $Script:GuiContent $bar
    $prot = @($items | Where-Object { $_.Status -eq 'Protected' }).Count
    $msg2 = '{0} possible leftover(s). Review each one.' -f $items.Count
    if ($prot -gt 0) { $msg2 += ' {0} on your exclude list.' -f $prot }
    Set-GuiStatus $msg2
}

function Show-GuiExcludeList {
    Reset-GuiPage -Title 'Exclude list' -Subtitle 'Folders and registry keys listed here are shown in red and are never moved, even if you select them. A pattern also covers everything under it. Use * for any text and ? for one character.'
    $list = @(Get-ExcludeList)
    $lb = New-Object System.Windows.Controls.ListBox
    $lb.Height = 240
    $lb.Background = (Get-GuiBrush '#131D33'); $lb.Foreground = (Get-GuiBrush '#E8EEF8')
    foreach ($p in $list) { [void]$lb.Items.Add($p) }
    $Script:GuiExList = $lb
    Add-GuiChild $Script:GuiContent $lb
    if ($list.Count -eq 0) { Add-GuiChild $Script:GuiContent (New-GuiText -Text 'The exclude list is empty.' -Color '#8DA0BF') }
    $row = New-Object System.Windows.Controls.WrapPanel
    $row.Margin = '0,10,0,0'
    $box = New-Object System.Windows.Controls.TextBox
    $box.Width = 460; $box.Margin = '0,0,10,8'; $box.Padding = '8,6'
    $box.Background = (Get-GuiBrush '#131D33'); $box.Foreground = (Get-GuiBrush '#E8EEF8'); $box.BorderBrush = (Get-GuiBrush '#25324D')
    $box.ToolTip = 'Example: C:\Program Files\MyApp   or   HKCU:\Software\MyApp   or   C:\Users\*\AppData\Local\MyApp*'
    $Script:GuiExBox = $box
    Add-GuiChild $row $box
    Add-GuiChild $row (New-GuiButton -Text 'ADD' -Bg '#238636' -Width 90 -OnClick {
        try { [void](Add-ExcludeEntry -Pattern ([string]$Script:GuiExBox.Text)); Show-GuiExcludeList } catch { Show-GuiMessage $_.Exception.Message 'Exclude list' 'Warning' }
    })
    Add-GuiChild $row (New-GuiButton -Text 'REMOVE SELECTED' -Width 170 -OnClick {
        $sel = $Script:GuiExList.SelectedItem
        if (-not $sel) { Show-GuiMessage 'Select an entry first.'; return }
        Remove-ExcludeEntry -Pattern ([string]$sel)
        Show-GuiExcludeList
    })
    Add-GuiChild $row (New-GuiButton -Text 'BACK' -Width 100 -OnClick { Show-GuiUninstaller })
    Add-GuiChild $Script:GuiContent $row
    Add-GuiChild $Script:GuiContent (New-GuiText -Text ('Saved in: ' + $Script:ExcludeFile) -Size 11 -Color '#6F82A3' -Margin '0,6,0,0')
}

function Show-GuiUninstallerOptions {
    Reset-GuiPage -Title 'DIVuninstaller options' -Subtitle 'All three are off unless you turn them on.'
    $s = Get-UninstallerSettings
    $mk = {
        param([string]$Text, [bool]$On)
        $c = New-Object System.Windows.Controls.CheckBox
        $c.Content = $Text; $c.IsChecked = $On; $c.Margin = '0,6,0,6'
        return $c
    }
    $Script:GuiOptCheck = & $mk 'Check all matched leftovers by default (you still review the list and confirm before anything moves)' ([bool]$s.CheckAllByDefault)
    $Script:GuiOptStop = & $mk 'Force-stop programs running from the install folder before uninstalling (unsaved work in them is lost)' ([bool]$s.ForceStopExecutables)
    $Script:GuiOptBuiltIn = & $mk 'Only run the built-in uninstaller (never scan for leftovers)' ([bool]$s.OnlyBuiltIn)
    Add-GuiChild $Script:GuiContent $Script:GuiOptCheck
    Add-GuiChild $Script:GuiContent $Script:GuiOptStop
    Add-GuiChild $Script:GuiContent $Script:GuiOptBuiltIn
    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = '0,12,0,0'
    Add-GuiChild $bar (New-GuiButton -Text 'SAVE' -Bg '#238636' -Width 120 -OnClick {
        [void](Set-UninstallerSetting -Name 'CheckAllByDefault' -Value ([bool]$Script:GuiOptCheck.IsChecked))
        [void](Set-UninstallerSetting -Name 'ForceStopExecutables' -Value ([bool]$Script:GuiOptStop.IsChecked))
        [void](Set-UninstallerSetting -Name 'OnlyBuiltIn' -Value ([bool]$Script:GuiOptBuiltIn.IsChecked))
        Show-GuiMessage 'Options saved.' 'DIVuninstaller'
        Show-GuiUninstaller
    })
    Add-GuiChild $bar (New-GuiButton -Text 'BACK' -Width 100 -OnClick { Show-GuiUninstaller })
    Add-GuiChild $Script:GuiContent $bar
}

function Show-GuiForcedByName {
    Reset-GuiPage -Title 'Forced uninstall by name' -Subtitle 'For a program that is not in the list, was removed earlier, or was only partly installed. Type its exact name, a folder inside Program Files, ProgramData or AppData, or both. DIVuninstaller will NOT run any uninstaller from here.'
    $mkBox = {
        $b = New-Object System.Windows.Controls.TextBox
        $b.Width = 520; $b.Margin = '0,0,0,8'; $b.Padding = '8,6'; $b.HorizontalAlignment = 'Left'
        $b.Background = (Get-GuiBrush '#131D33'); $b.Foreground = (Get-GuiBrush '#E8EEF8'); $b.BorderBrush = (Get-GuiBrush '#25324D')
        return $b
    }
    Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Program name (several names can be separated with ; when searching)' -Size 11 -Color '#8DA0BF')
    $Script:GuiFbName = & $mkBox
    Add-GuiChild $Script:GuiContent $Script:GuiFbName
    Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Install folder (optional)' -Size 11 -Color '#8DA0BF')
    $Script:GuiFbPath = & $mkBox
    Add-GuiChild $Script:GuiContent $Script:GuiFbPath
    $lb = New-Object System.Windows.Controls.ListBox
    $lb.Height = 140
    $lb.Background = (Get-GuiBrush '#131D33'); $lb.Foreground = (Get-GuiBrush '#E8EEF8')
    $Script:GuiFbList = $lb
    Add-GuiChild $Script:GuiContent $lb
    $note = New-GuiText -Text 'Press FIND to look for a built-in uninstaller or an earlier record. If a program is still installed, use UNINSTALL on the main page instead.' -Size 11 -Color '#6F82A3' -Margin '0,6,0,0'
    $Script:GuiFbNote = $note
    Add-GuiChild $Script:GuiContent $note
    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = '0,10,0,0'
    Add-GuiChild $bar (New-GuiButton -Text 'FIND' -Width 110 -OnClick {
        $nm = [string]$Script:GuiFbName.Text
        $pt = [string]$Script:GuiFbPath.Text
        if (-not $nm.Trim() -and -not $pt.Trim()) { Show-GuiMessage 'Type a name, a folder, or both.'; return }
        $Script:GuiFbAll = @(Invoke-GuiWithBusy -Title 'Looking' -Detail 'Reading installed programs and earlier records. Nothing is changed.' -Action { Get-InstalledPrograms })
        $found = @(Find-UninstallMatches -Name $nm -Path $pt -Programs $Script:GuiFbAll)
        $Script:GuiFbList.Items.Clear()
        foreach ($f in $found) {
            $li = New-Object System.Windows.Controls.ListBoxItem
            $li.Content = ('{0}    {1} {2}' -f $f.Source, $f.Name, $f.Version)
            $li.Tag = $f
            [void]$Script:GuiFbList.Items.Add($li)
        }
        if ($found.Count -eq 0) { $Script:GuiFbNote.Text = 'Nothing matched. You can still run the leftover scan by exact name and folder.' }
        else { $Script:GuiFbNote.Text = ('{0} match(es). Select one to scan for it, or leave nothing selected to scan by the name and folder you typed.' -f $found.Count) }
    })
    Add-GuiChild $bar (New-GuiButton -Text 'SCAN FOR LEFTOVERS' -Bg '#238636' -Width 220 -OnClick {
        $nm = [string]$Script:GuiFbName.Text
        $pt = [string]$Script:GuiFbPath.Text
        $prog = $null
        $sel = $Script:GuiFbList.SelectedItem
        if ($sel -and $sel.Tag.Program) { $prog = $sel.Tag.Program }
        elseif ($sel) { try { $prog = New-ForcedProgram -Name $sel.Tag.Name -InstallLocation $pt } catch { Show-GuiMessage $_.Exception.Message 'Forced uninstall' 'Warning'; return } }
        else { try { $prog = New-ForcedProgram -Name $nm -InstallLocation $pt } catch { Show-GuiMessage $_.Exception.Message 'Forced uninstall' 'Warning'; return } }
        if ($prog.Protected) { Show-GuiMessage ("{0} is a protected program and cannot be removed here." -f $prog.Name) 'Protected' 'Warning'; return }
        $txt = "Forced uninstall of {0}?`n`nDIVuninstaller will NOT run any uninstaller. It will:`n 1. Create a restore point (if Windows allows it)`n 2. Back up the program's registry entry, if it has one`n 3. Scan at the Advanced level and show everything it finds`n`nNothing is selected for you, and nothing moves until you choose it." -f $prog.Name
        if (-not (Confirm-Gui $txt 'Confirm forced uninstall' 'Warning')) { return }
        try {
            $r = Invoke-GuiWithBusy -Title 'Preparing forced uninstall' -Detail 'Creating a restore point...' -Action { Invoke-ProgramUninstall -Program $prog -SkipUninstaller }
        } catch {
            Write-Log -Level FAIL -Action 'FORCED_UNINSTALL' -Target $prog.Name -ErrorText $_.Exception.Message
            Show-GuiMessage $_.Exception.Message 'Forced uninstall failed' 'Error'
            return
        }
        $all = @($Script:GuiFbAll)
        if ($all.Count -eq 0) { $all = @(Get-InstalledPrograms) }
        $others = @($all | Where-Object { $_.KeyPath -ne $prog.KeyPath })
        Start-GuiLeftoverStage -Program $prog -Mode 'Advanced' -RecordDir $r.BackupDir -Others $others
    })
    Add-GuiChild $bar (New-GuiButton -Text 'BACK' -Width 100 -OnClick { Show-GuiUninstaller })
    Add-GuiChild $Script:GuiContent $bar
}

function Start-GuiBatchUninstall {
    param($Selected)
    $progs = @($Selected | ForEach-Object { $_.Tag })
    $problem = Test-BatchProgramsReady -Programs $progs
    if ($problem) { Show-GuiMessage $problem 'Batch uninstall' 'Warning'; return }
    $mode = Get-GuiScanModeKey
    $names = (@($progs | ForEach-Object { ' - {0} {1}' -f $_.Name, $_.Version }) -join "`n")
    $how = 'Scan for leftovers ({0}) and show one combined list' -f $mode
    if ($mode -eq 'None') { $how = 'Stop (Built-in mode: no leftover scan)' }
    $txt = "Uninstall these {0} programs?`n`n{1}`n`nDIVuninstaller will:`n 1. Create ONE restore point (if Windows allows it)`n 2. Run each program's own uninstaller, one after another (each may open its own window; finish each one)`n 3. {2}`n`nNothing is deleted without your approval." -f $progs.Count, $names, $how
    if (-not (Confirm-Gui $txt 'Confirm batch uninstall' 'Warning')) { return }
    try {
        $b = Invoke-GuiWithBusy -Title ('Uninstalling {0} programs' -f $progs.Count) -Detail 'Finish each uninstaller window as it opens. DIVuninstaller continues when it closes.' -Action { Invoke-BatchUninstall -Programs $progs }
    } catch {
        Write-Log -Level FAIL -Action 'BATCH_UNINSTALL' -ErrorText $_.Exception.Message
        Show-GuiMessage $_.Exception.Message 'Batch uninstall failed' 'Error'
        return
    }
    $gone = @($b.Results | Where-Object { $_.Result -and -not $_.Result.StillInstalled }).Count
    $still = @($b.Results | Where-Object { $_.Result -and $_.Result.StillInstalled } | ForEach-Object { $_.Program.Name })
    $err = @($b.Results | Where-Object { $_.Error } | ForEach-Object { '{0}: {1}' -f $_.Program.Name, $_.Error })
    $sum = "{0} of {1} program(s) are gone." -f $gone, $progs.Count
    if ($still.Count -gt 0) { $sum += "`n`nStill installed (cancelled or failed): " + ($still -join ', ') }
    if ($err.Count -gt 0) { $sum += "`n`nCould not run:`n" + ($err -join "`n") }
    if ($mode -eq 'None' -or $gone -eq 0) {
        foreach ($r in @($b.Results)) { if ($r.Result) { Update-UninstallRecord -Dir $r.Result.BackupDir -Values @{ Mode = $(if ($mode -eq 'None') { 'Built-in' } else { $mode }); LeftoversFound = 0; LeftoversMoved = 0 } } }
        Show-GuiMessage $sum 'Batch uninstall'
        Show-GuiUninstaller
        return
    }
    $all = @($Script:GuiProgAll)
    $left = @(Invoke-GuiWithBusy -Title 'Looking for leftovers' -Detail ("Scan level: {0}. Checking by exact name. Nothing is changed." -f $mode) -Action { Get-BatchLeftovers -Batch $b -Mode $mode -AllPrograms $all })
    Show-GuiMessage $sum 'Batch uninstall'
    $keys = @($progs | ForEach-Object { $_.KeyPath })
    $others = @($all | Where-Object { $keys -notcontains $_.KeyPath })
    $label = [pscustomobject]@{ Name = ('{0} programs' -f $progs.Count) }
    Show-GuiLeftovers -Program $label -Items $left -OtherPrograms $others -RecordDir '' -Mode $mode -Batch
}

function Show-GuiWindowsApps {
    Reset-GuiPage -Title 'Windows Apps' -Subtitle 'Store and built-in apps for your account. Hold Ctrl or Shift to select several. System apps, frameworks and the apps Windows needs are not listed or are marked protected.'
    $Script:GuiAppsAll = @(Invoke-GuiWithBusy -Title 'Reading Windows apps' -Detail 'Asking Windows for the app list. This does not change anything.' -Action { Get-WindowsApps })
    $box = New-Object System.Windows.Controls.TextBox
    $box.Width = 300; $box.Margin = '0,0,10,8'; $box.Padding = '8,6'; $box.HorizontalAlignment = 'Left'
    $box.Background = (Get-GuiBrush '#131D33'); $box.Foreground = (Get-GuiBrush '#E8EEF8'); $box.BorderBrush = (Get-GuiBrush '#25324D')
    $box.ToolTip = 'Type to filter by name'
    $Script:GuiAppsFilter = $box
    Add-GuiChild $Script:GuiContent $box
    $lb = New-Object System.Windows.Controls.ListBox
    $lb.Height = 320
    $lb.SelectionMode = 'Extended'
    $lb.Background = (Get-GuiBrush '#131D33'); $lb.Foreground = (Get-GuiBrush '#E8EEF8')
    $Script:GuiAppsList = $lb
    Add-GuiChild $Script:GuiContent $lb
    $fill = {
        $f = ([string]$Script:GuiAppsFilter.Text).Trim()
        $Script:GuiAppsList.Items.Clear()
        foreach ($a in @($Script:GuiAppsAll)) {
            if ($f -and $a.Name -notlike ('*' + $f + '*')) { continue }
            $li = New-Object System.Windows.Controls.ListBoxItem
            $tag = ''
            if ($a.Protected) { $tag = '   [protected]' }
            $li.Content = ('{0}    {1}{2}' -f $a.Name, $a.Version, $tag)
            $li.Tag = $a
            [void]$Script:GuiAppsList.Items.Add($li)
        }
    }
    $Script:GuiAppsFill = $fill
    & $fill
    $box.Add_TextChanged({ & $Script:GuiAppsFill })
    Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Removing an app cannot be undone by DIVuninstaller. Most can be reinstalled from the Microsoft Store. A restore point is made first, but Windows restore points do not bring Store apps back.' -Size 11 -Color '#6F82A3' -Margin '0,8,0,0')
    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = '0,10,0,0'
    Add-GuiChild $bar (New-GuiButton -Text 'REMOVE FOR ME' -Bg '#238636' -Width 170 -OnClick {
        $sel = @($Script:GuiAppsList.SelectedItems | ForEach-Object { $_.Tag })
        if ($sel.Count -eq 0) { Show-GuiMessage 'Select at least one app first.'; return }
        if (@($sel | Where-Object { $_.Protected }).Count -gt 0) { Show-GuiMessage 'One or more selected apps are protected and cannot be removed here. Deselect them.' 'Protected' 'Warning'; return }
        $names = (@($sel | ForEach-Object { ' - ' + $_.Name }) -join "`n")
        if (-not (Confirm-Gui ("Remove these {0} app(s) for your account?`n`n{1}`n`nA restore point is made first. Removal cannot be undone here; reinstall from the Microsoft Store if needed." -f $sel.Count, $names) 'Confirm removal' 'Warning')) { return }
        try {
            $r = Invoke-GuiWithBusy -Title 'Removing apps' -Detail 'Creating a restore point and removing the selected apps...' -Action { Remove-WindowsApps -Apps $sel }
            $ok = @($r.Results | Where-Object { $_.Removed -gt 0 }).Count
            $bad = @($r.Results | Where-Object { $_.Error } | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Error })
            $m = "Removed {0} of {1}." -f $ok, $sel.Count
            if ($bad.Count -gt 0) { $m += "`n`nCould not remove:`n" + ($bad -join "`n") }
            Show-GuiMessage $m 'Windows Apps'
        } catch { Show-GuiMessage $_.Exception.Message 'Windows Apps' 'Error' }
        Show-GuiWindowsApps
    })
    Add-GuiChild $bar (New-GuiButton -Text 'REMOVE FOR ALL USERS' -Width 220 -OnClick {
        $sel = @($Script:GuiAppsList.SelectedItems | ForEach-Object { $_.Tag })
        if ($sel.Count -eq 0) { Show-GuiMessage 'Select at least one app first.'; return }
        if (@($sel | Where-Object { $_.Protected }).Count -gt 0) { Show-GuiMessage 'One or more selected apps are protected and cannot be removed here. Deselect them.' 'Protected' 'Warning'; return }
        $names = (@($sel | ForEach-Object { ' - ' + $_.Name }) -join "`n")
        if (-not (Confirm-Gui ("Remove these {0} app(s) for ALL users, including new accounts?`n`n{1}`n`nThis needs Administrator. It cannot be undone here." -f $sel.Count, $names) 'Confirm removal for all users' 'Warning')) { return }
        try {
            $r = Invoke-GuiWithBusy -Title 'Removing apps' -Detail 'Creating a restore point and removing the selected apps for all users...' -Action { Remove-WindowsApps -Apps $sel -AllUsers }
            $ok = @($r.Results | Where-Object { $_.Removed -gt 0 }).Count
            $bad = @($r.Results | Where-Object { $_.Error } | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Error })
            $m = "Removed {0} of {1}." -f $ok, $sel.Count
            if ($bad.Count -gt 0) { $m += "`n`nCould not remove:`n" + ($bad -join "`n") }
            Show-GuiMessage $m 'Windows Apps'
        } catch { Show-GuiMessage $_.Exception.Message 'Windows Apps' 'Error' }
        Show-GuiWindowsApps
    })
    Add-GuiChild $bar (New-GuiButton -Text 'REFRESH' -Width 110 -OnClick { Show-GuiWindowsApps })
    Add-GuiChild $bar (New-GuiButton -Text 'BACK' -Width 100 -OnClick { Show-GuiUninstaller })
    Add-GuiChild $Script:GuiContent $bar
}

function Show-GuiBrowserExtensions {
    Reset-GuiPage -Title 'Browser extensions' -Subtitle 'Extensions found for Chrome, Edge, Brave and Firefox on this account. Hold Ctrl or Shift to select several. Removal moves the extension to quarantine, so you can restore it.'
    $Script:GuiExtAll = @(Invoke-GuiWithBusy -Title 'Reading browser extensions' -Detail 'Reading the browsers'' extension folders. This does not change anything.' -Action { Get-BrowserExtensions })
    $box = New-Object System.Windows.Controls.TextBox
    $box.Width = 300; $box.Margin = '0,0,10,8'; $box.Padding = '8,6'; $box.HorizontalAlignment = 'Left'
    $box.Background = (Get-GuiBrush '#131D33'); $box.Foreground = (Get-GuiBrush '#E8EEF8'); $box.BorderBrush = (Get-GuiBrush '#25324D')
    $box.ToolTip = 'Type to filter by name or browser'
    $Script:GuiExtFilter = $box
    Add-GuiChild $Script:GuiContent $box
    $lb = New-Object System.Windows.Controls.ListBox
    $lb.Height = 320
    $lb.SelectionMode = 'Extended'
    $lb.Background = (Get-GuiBrush '#131D33'); $lb.Foreground = (Get-GuiBrush '#E8EEF8')
    $Script:GuiExtList = $lb
    Add-GuiChild $Script:GuiContent $lb
    $fill = {
        $f = ([string]$Script:GuiExtFilter.Text).Trim()
        $Script:GuiExtList.Items.Clear()
        foreach ($x in @($Script:GuiExtAll)) {
            if ($f -and ($x.Name -notlike ('*' + $f + '*')) -and ($x.Browser -notlike ('*' + $f + '*'))) { continue }
            $li = New-Object System.Windows.Controls.ListBoxItem
            $li.Content = ('{0}    {1}    {2}    [{3}, {4}]' -f $x.Browser, $x.Name, $x.Version, $x.Profile, $x.Id)
            $li.Tag = $x
            [void]$Script:GuiExtList.Items.Add($li)
        }
    }
    $Script:GuiExtFill = $fill
    & $fill
    $box.Add_TextChanged({ & $Script:GuiExtFill })
    if (@($Script:GuiExtAll).Count -eq 0) { Add-GuiChild $Script:GuiContent (New-GuiText -Text 'No extensions were found.' -Color '#8DA0BF') }
    Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Close the browser first. If the extension was installed by your account sync or an organization policy, the browser may add it back; remove it from the browser''s own extensions page in that case. Firefox keeps a small list of its own and drops the missing entry the next time it starts.' -Size 11 -Color '#6F82A3' -Margin '0,8,0,0')
    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = '0,10,0,0'
    Add-GuiChild $bar (New-GuiButton -Text 'MOVE TO QUARANTINE' -Bg '#238636' -Width 210 -OnClick {
        $sel = @($Script:GuiExtList.SelectedItems | ForEach-Object { $_.Tag })
        if ($sel.Count -eq 0) { Show-GuiMessage 'Select at least one extension first.'; return }
        $names = (@($sel | ForEach-Object { ' - {0}: {1}' -f $_.Browser, $_.Name }) -join "`n")
        if (-not (Confirm-Gui ("Move these {0} extension(s) to quarantine?`n`n{1}`n`nYou can restore them from the Quarantine page." -f $sel.Count, $names) 'Confirm removal' 'Warning')) { return }
        try {
            $r = Invoke-GuiWithBusy -Title 'Removing extensions' -Detail 'Moving the selected extensions to quarantine...' -Action { Remove-BrowserExtensions -Items $sel }
            $m = "Moved {0} to quarantine." -f $r.Moved
            if ($r.Failed -gt 0) { $m += ("`n{0} could not be moved and were left alone. See the PowerShell window." -f $r.Failed) }
            Show-GuiMessage $m 'Browser extensions'
        } catch { Show-GuiMessage $_.Exception.Message 'Browser extensions' 'Warning' }
        Show-GuiBrowserExtensions
    })
    Add-GuiChild $bar (New-GuiButton -Text 'QUARANTINE' -Width 140 -OnClick { Show-GuiQuarantine })
    Add-GuiChild $bar (New-GuiButton -Text 'REFRESH' -Width 110 -OnClick { Show-GuiBrowserExtensions })
    Add-GuiChild $bar (New-GuiButton -Text 'BACK' -Width 100 -OnClick { Show-GuiUninstaller })
    Add-GuiChild $Script:GuiContent $bar
}

function Show-GuiInstallMonitor {
    Reset-GuiPage -Title 'Install monitor' -Subtitle 'Records what a program adds to your PC while it installs, so it can be cleaned up later from that record. It is best-effort: other changes made during the same time can show up, so you review every item and nothing is deleted (items go to quarantine).'
    $pending = Get-PendingTrace
    if ($pending) {
        Add-GuiChild $Script:GuiContent (New-GuiText -Text ('A trace is in progress for: {0}   (started {1})' -f $pending.Name, $pending.Started) -Size 14 -Bold -Margin '0,6,0,2')
        Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Install the program now. Open it once so it creates its settings, then close it and press FINISH TRACE. Do not install anything else in between.' -Size 12 -Color '#8DA0BF' -Margin '0,0,0,8')
        $row = New-Object System.Windows.Controls.WrapPanel
        Add-GuiChild $row (New-GuiButton -Text 'FINISH TRACE' -Bg '#238636' -Width 170 -OnClick {
            try {
                $r = Invoke-GuiWithBusy -Title 'Finishing the trace' -Detail 'Taking the second snapshot and comparing. This can take a minute.' -Action { Complete-InstallTrace }
                $m = 'Saved. {0} item(s) were created during the install.' -f $r.Count
                if (@($r.Diff.Services).Count -gt 0) { $m += ("`n`nNew Windows services appeared ({0}). Services are listed in the log only and are never removed by DIVuninstaller." -f (@($r.Diff.Services) -join ', ')) }
                Show-GuiMessage $m 'Install monitor'
            } catch { Show-GuiMessage $_.Exception.Message 'Install monitor' 'Error' }
            Show-GuiInstallMonitor
        })
        Add-GuiChild $row (New-GuiButton -Text 'CANCEL TRACE' -Width 150 -OnClick {
            if (Confirm-Gui 'Throw away the saved starting snapshot? Nothing on your PC changes.' 'Cancel trace' 'Question') { Stop-InstallTrace; Show-GuiInstallMonitor }
        })
        Add-GuiChild $Script:GuiContent $row
    } else {
        Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Program you are about to install' -Size 11 -Color '#8DA0BF' -Margin '0,6,0,2')
        $box = New-Object System.Windows.Controls.TextBox
        $box.Width = 420; $box.Margin = '0,0,0,8'; $box.Padding = '8,6'; $box.HorizontalAlignment = 'Left'
        $box.Background = (Get-GuiBrush '#131D33'); $box.Foreground = (Get-GuiBrush '#E8EEF8'); $box.BorderBrush = (Get-GuiBrush '#25324D')
        $Script:GuiTraceName = $box
        Add-GuiChild $Script:GuiContent $box
        Add-GuiChild $Script:GuiContent (New-GuiButton -Text 'START TRACE' -Bg '#238636' -Width 170 -OnClick {
            $nm = ([string]$Script:GuiTraceName.Text).Trim()
            if ($nm.Length -lt 2) { Show-GuiMessage 'Type the name of the program you are about to install.'; return }
            if (-not (Confirm-Gui "Start a trace for '$nm'?`n`nDIVuninstaller will take a snapshot of folders, shortcuts, registry key names and startup entries (names only, no file contents). This can take a minute.`n`nClose other installers first, then install the program when it finishes." 'Start trace' 'Question')) { return }
            try { [void](Invoke-GuiWithBusy -Title 'Taking the first snapshot' -Detail 'Reading folder and registry key names. Nothing is changed.' -Action { Start-InstallTrace -Name $nm }) } catch { Show-GuiMessage $_.Exception.Message 'Install monitor' 'Error'; return }
            Show-GuiInstallMonitor
        })
    }
    Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Saved traces' -Size 14 -Bold -Margin '0,14,0,4')
    $lb = New-Object System.Windows.Controls.ListBox
    $lb.Height = 200
    $lb.SelectionMode = 'Extended'
    $lb.Background = (Get-GuiBrush '#131D33'); $lb.Foreground = (Get-GuiBrush '#E8EEF8')
    foreach ($l in @(Get-TraceLogs)) {
        $li = New-Object System.Windows.Controls.ListBoxItem
        $li.Content = ('{0}    {1}    {2} item(s)' -f $l.Name, $l.Finished, $l.Count)
        $li.Tag = $l
        [void]$lb.Items.Add($li)
    }
    $Script:GuiTraceList = $lb
    Add-GuiChild $Script:GuiContent $lb
    if ($lb.Items.Count -eq 0) { Add-GuiChild $Script:GuiContent (New-GuiText -Text 'No traces yet.' -Color '#8DA0BF') }
    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = '0,10,0,0'
    Add-GuiChild $bar (New-GuiButton -Text 'CLEAN UP FROM LOG' -Bg '#238636' -Width 210 -OnClick {
        $it = $Script:GuiTraceList.SelectedItem
        if (-not $it) { Show-GuiMessage 'Select a trace first.'; return }
        $log = $it.Tag
        $all = @(Invoke-GuiWithBusy -Title 'Checking' -Detail 'Reading installed programs. Nothing is changed.' -Action { Get-InstalledPrograms })
        $still = @($all | Where-Object { $_.Name -ieq $log.Name })
        if ($still.Count -gt 0) {
            if (-not (Confirm-Gui ("{0} is still listed as installed.`n`nUse UNINSTALL on the main page first so its own uninstaller runs, then come back here for what it leaves behind.`n`nClean up from the log anyway? (Items still go to quarantine and can be restored.)" -f $log.Name) 'Still installed' 'Warning')) { return }
        }
        $items = @(Get-TraceReviewItems -Log $log)
        if ($items.Count -eq 0) { Show-GuiMessage 'Everything in this log is already gone.' 'Install monitor'; return }
        $others = @($all | Where-Object { $_.Name -ine $log.Name })
        Show-GuiLeftovers -Program ([pscustomobject]@{ Name = $log.Name }) -Items $items -OtherPrograms $others -RecordDir '' -Mode 'Trace log'
    })
    Add-GuiChild $bar (New-GuiButton -Text 'EDIT LOG' -Width 110 -OnClick {
        $it = $Script:GuiTraceList.SelectedItem
        if (-not $it) { Show-GuiMessage 'Select a trace first.'; return }
        Show-GuiTraceEditor -Dir $it.Tag.Path
    })
    Add-GuiChild $bar (New-GuiButton -Text 'MERGE SELECTED' -Width 160 -OnClick {
        $sel = @($Script:GuiTraceList.SelectedItems | ForEach-Object { $_.Tag })
        if ($sel.Count -lt 2) { Show-GuiMessage 'Hold Ctrl or Shift and select at least two traces to merge.'; return }
        $nm = ('Merged: ' + (($sel | ForEach-Object { $_.Name }) -join ' + '))
        if ($nm.Length -gt 80) { $nm = $nm.Substring(0, 80) }
        if (-not (Confirm-Gui ("Merge these {0} logs into a new log?`n`n{1}`n`nThe originals are kept." -f $sel.Count, (($sel | ForEach-Object { ' - ' + $_.Name }) -join "`n")) 'Merge logs' 'Question')) { return }
        try { [void](Merge-TraceLogs -Dirs @($sel | ForEach-Object { $_.Path }) -Name $nm); Show-GuiInstallMonitor } catch { Show-GuiMessage $_.Exception.Message 'Merge logs' 'Warning' }
    })
    Add-GuiChild $bar (New-GuiButton -Text 'EXPORT' -Width 100 -OnClick {
        $it = $Script:GuiTraceList.SelectedItem
        if (-not $it) { Show-GuiMessage 'Select a trace first.'; return }
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'DIVuninstaller trace log (*.json)|*.json'
        $dlg.FileName = ((ConvertTo-SafeFileName -Text $it.Tag.Name) + '.json')
        if ($dlg.ShowDialog()) {
            try { Export-TraceLog -Dir $it.Tag.Path -Destination $dlg.FileName; Show-GuiMessage ('Saved to ' + $dlg.FileName) 'Export' } catch { Show-GuiMessage $_.Exception.Message 'Export' 'Warning' }
        }
    })
    Add-GuiChild $bar (New-GuiButton -Text 'IMPORT' -Width 100 -OnClick {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'DIVuninstaller trace log (*.json)|*.json'
        if ($dlg.ShowDialog()) {
            try {
                $r = Import-TraceLog -Source $dlg.FileName
                Show-GuiMessage ("Imported {0} item(s). {1} skipped by the safety checks.`n`nReview the log with EDIT LOG before cleaning up." -f $r.Imported, $r.Skipped) 'Import'
                Show-GuiInstallMonitor
            } catch { Show-GuiMessage $_.Exception.Message 'Import' 'Warning' }
        }
    })
    Add-GuiChild $bar (New-GuiButton -Text 'DELETE LOG' -Width 130 -OnClick {
        $it = $Script:GuiTraceList.SelectedItem
        if (-not $it) { Show-GuiMessage 'Select a trace first.'; return }
        if (Confirm-Gui ("Delete this trace log?`n`n{0}`n`nThis only removes the record. The program and its files are not touched." -f $it.Tag.Name) 'Delete log' 'Question') {
            try { Remove-TraceLog -Dir $it.Tag.Path; Show-GuiInstallMonitor } catch { Show-GuiMessage $_.Exception.Message 'Failed' 'Error' }
        }
    })
    Add-GuiChild $bar (New-GuiButton -Text 'BACK' -Width 100 -OnClick { Show-GuiUninstaller })
    Add-GuiChild $Script:GuiContent $bar
}

function Show-GuiTraceEditor {
    param([string]$Dir)
    $d = Read-TraceData -Dir $Dir
    $Script:GuiTeDir = $Dir
    Reset-GuiPage -Title ('Edit log: ' + $d.Name) -Subtitle 'Change what a trace log will undo. Editing a log only changes the log. Nothing on your PC is touched until you use CLEAN UP FROM LOG, which still shows every item for review.'
    $mk = {
        $b = New-Object System.Windows.Controls.TextBox
        $b.Width = 520; $b.Margin = '0,0,0,8'; $b.Padding = '8,6'; $b.HorizontalAlignment = 'Left'
        $b.Background = (Get-GuiBrush '#131D33'); $b.Foreground = (Get-GuiBrush '#E8EEF8'); $b.BorderBrush = (Get-GuiBrush '#25324D')
        return $b
    }
    Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Name' -Size 11 -Color '#8DA0BF')
    $Script:GuiTeName = & $mk; $Script:GuiTeName.Text = [string]$d.Name
    Add-GuiChild $Script:GuiContent $Script:GuiTeName
    Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Comment' -Size 11 -Color '#8DA0BF')
    $Script:GuiTeComment = & $mk; $Script:GuiTeComment.Text = [string]$d.Comment
    Add-GuiChild $Script:GuiContent $Script:GuiTeComment
    Add-GuiChild $Script:GuiContent (New-GuiButton -Text 'SAVE NAME AND COMMENT' -Width 230 -OnClick {
        try { Set-TraceDetails -Dir $Script:GuiTeDir -Name ([string]$Script:GuiTeName.Text) -Comment ([string]$Script:GuiTeComment.Text); Show-GuiTraceEditor -Dir $Script:GuiTeDir } catch { Show-GuiMessage $_.Exception.Message 'Edit log' 'Warning' }
    })
    Add-GuiChild $Script:GuiContent (New-GuiText -Text ('Items in this log ({0}). Hold Ctrl or Shift to select several.' -f @($d.Items).Count) -Size 14 -Bold -Margin '0,12,0,4')
    $lb = New-Object System.Windows.Controls.ListBox
    $lb.Height = 220
    $lb.SelectionMode = 'Extended'
    $lb.Background = (Get-GuiBrush '#131D33'); $lb.Foreground = (Get-GuiBrush '#E8EEF8')
    foreach ($i in @($d.Items)) {
        $li = New-Object System.Windows.Controls.ListBoxItem
        $what = $i.Path; if ($i.Name) { $what = $i.Path + '  ->  ' + $i.Name }
        $li.Content = ('{0}   {1}' -f $i.Type, $what)
        $li.Tag = [pscustomobject]$i
        [void]$lb.Items.Add($li)
    }
    $Script:GuiTeList = $lb
    Add-GuiChild $Script:GuiContent $lb
    Add-GuiChild $Script:GuiContent (New-GuiButton -Text 'REMOVE SELECTED FROM LOG' -Width 250 -OnClick {
        $sel = @($Script:GuiTeList.SelectedItems | ForEach-Object { $_.Tag })
        if ($sel.Count -eq 0) { Show-GuiMessage 'Select at least one item first.'; return }
        if (-not (Confirm-Gui ("Remove {0} item(s) from this log?`n`nOnly the log changes. Files and registry keys on your PC are not touched." -f $sel.Count) 'Edit log' 'Question')) { return }
        try { [void](Remove-TraceItems -Dir $Script:GuiTeDir -Items $sel); Show-GuiTraceEditor -Dir $Script:GuiTeDir } catch { Show-GuiMessage $_.Exception.Message 'Edit log' 'Warning' }
    })
    Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Add an item by hand' -Size 14 -Bold -Margin '0,12,0,4')
    $row = New-Object System.Windows.Controls.WrapPanel
    $cmb = New-Object System.Windows.Controls.ComboBox
    $cmb.Width = 140; $cmb.Margin = '0,0,10,8'
    foreach ($v in @('Folder', 'File', 'RegistryKey', 'RunValue')) { [void]$cmb.Items.Add($v) }
    $cmb.SelectedItem = 'Folder'
    $Script:GuiTeType = $cmb
    Add-GuiChild $row $cmb
    $pb = & $mk; $pb.Width = 360; $pb.Margin = '0,0,10,8'; $pb.ToolTip = 'Full path, e.g. C:\Program Files\MyApp or HKCU:\Software\Vendor\Program'
    $Script:GuiTePath = $pb
    Add-GuiChild $row $pb
    $nb = & $mk; $nb.Width = 160; $nb.Margin = '0,0,10,8'; $nb.ToolTip = 'Only for a startup value: the value name'
    $Script:GuiTeValName = $nb
    Add-GuiChild $row $nb
    Add-GuiChild $row (New-GuiButton -Text 'ADD' -Bg '#238636' -Width 90 -OnClick {
        try { Add-TraceItem -Dir $Script:GuiTeDir -Type ([string]$Script:GuiTeType.SelectedItem) -Path ([string]$Script:GuiTePath.Text) -Name ([string]$Script:GuiTeValName.Text); Show-GuiTraceEditor -Dir $Script:GuiTeDir } catch { Show-GuiMessage $_.Exception.Message 'Edit log' 'Warning' }
    })
    Add-GuiChild $Script:GuiContent $row
    Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Protected paths, system folders and keys under Microsoft, Classes and Policies are refused.' -Size 11 -Color '#6F82A3')
    Add-GuiChild $Script:GuiContent (New-GuiButton -Text 'BACK' -Width 100 -OnClick { Show-GuiInstallMonitor })
}

function Invoke-GuiJunkRun {
    param([bool]$Permanent)
    $rows = @($Script:GuiJunkChecks | Where-Object { $_.IsChecked -and $_.IsEnabled } | ForEach-Object { $_.Tag })
    if ($rows.Count -eq 0) { Show-GuiMessage 'Tick at least one category first.'; return }
    $total = [long]0; foreach ($r in $rows) { $total += [long]$r.Bytes }
    $names = ($rows | ForEach-Object { '  ' + $_.Name + '  (' + (Format-Bytes $_.Bytes) + ')' }) -join "`n"
    if ($Permanent) {
        $txt = "PERMANENTLY delete these?`n`n{0}`n`nTotal: {1}`n`nThis cannot be undone. Nothing is moved to quarantine." -f $names, (Format-Bytes $total)
        if (-not (Confirm-Gui $txt 'Delete permanently' 'Warning')) { return }
    } else {
        $txt = "Move these to quarantine?`n`n{0}`n`nTotal: {1}`n`nThey can be restored from the Quarantine page. Disk space is only freed when you delete the quarantine entry." -f $names, (Format-Bytes $total)
        if (-not (Confirm-Gui $txt 'Move to quarantine' 'Question')) { return }
    }
    $perm = $Permanent
    $moved = 0; $failed = 0; $bytes = [long]0
    foreach ($r in $rows) {
        $row = $r
        try {
            $res = Invoke-GuiWithBusy -Title ('Cleaning ' + $row.Name) -Detail 'Checking each item again before it is moved...' -Action { Move-JunkToQuarantine -Category $row.Category -Units $row.Units -Permanent:$perm }
            $moved += $res.Moved; $failed += $res.Failed; $bytes += $res.Bytes
        } catch {
            Write-Log -Level FAIL -Action 'JUNK_MOVE' -Target $row.Name -ErrorText $_.Exception.Message
            Show-GuiMessage $_.Exception.Message 'Junk cleaner' 'Error'
        }
    }
    $what = 'moved to quarantine'; if ($Permanent) { $what = 'deleted' }
    Show-GuiMessage ("{0} item(s) {1} ({2}). {3} skipped (in use, changed recently, or protected)." -f $moved, $what, (Format-Bytes $bytes), $failed) 'Junk cleaner'
    Show-GuiJunkCleaner
}

function Show-GuiJunkCleaner {
    Reset-GuiPage -Title 'Junk cleaner' -Subtitle 'Old temporary files, crash dumps, error reports, thumbnail and browser caches. Nothing is ticked for you. Items go to quarantine first.'
    $rows = @(Invoke-GuiWithBusy -Title 'Looking for junk' -Detail 'Reading folder sizes. This does not change anything.' -Action { Get-JunkScan })
    $Script:GuiJunkChecks = @()
    foreach ($r in $rows) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Margin = '0,8,0,0'
        $cb.Foreground = (Get-GuiBrush '#E8EEF8')
        $cb.Content = ('{0}    {1}    {2:N0} file(s)' -f $r.Name, (Format-Bytes $r.Bytes), $r.Files)
        $cb.Tag = $r
        $cb.IsChecked = $false
        if ($r.Units.Count -eq 0) { $cb.IsEnabled = $false }
        $Script:GuiJunkChecks += $cb
        Add-GuiChild $Script:GuiContent $cb
        $note = $r.Note
        if ($r.RecentSkipped -gt 0) { $note += ('  {0} newer item(s) are kept.' -f $r.RecentSkipped) }
        if ($r.Truncated) { $note += '  Only the first 5000 items are listed; run it again afterwards.' }
        Add-GuiChild $Script:GuiContent (New-GuiText -Text $note -Size 11 -Color '#8DA0BF' -Margin '24,0,0,0')
        foreach ($b in @($r.Blocked)) { Add-GuiChild $Script:GuiContent (New-GuiText -Text $b -Size 11 -Color '#F0B35A' -Margin '24,0,0,0') }
    }
    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = '0,14,0,0'
    Add-GuiChild $bar (New-GuiButton -Text 'MOVE TO QUARANTINE' -Bg '#238636' -Width 200 -OnClick { Invoke-GuiJunkRun -Permanent $false })
    Add-GuiChild $bar (New-GuiButton -Text 'DELETE PERMANENTLY' -Width 200 -OnClick { Invoke-GuiJunkRun -Permanent $true })
    Add-GuiChild $bar (New-GuiButton -Text 'RESCAN' -Width 110 -OnClick { Show-GuiJunkCleaner })
    Add-GuiChild $bar (New-GuiButton -Text 'QUARANTINE' -Width 130 -OnClick { Show-GuiQuarantine })
    Add-GuiChild $bar (New-GuiButton -Text 'BACK' -Width 100 -OnClick { Show-GuiUninstaller })
    Add-GuiChild $Script:GuiContent $bar
    Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Never touched: Recycle Bin, Downloads, Documents, Desktop, browser history, cookies and passwords. Files changed in the last 24 hours and files in use are skipped. Windows Update, delivery and other system caches stay in the Cleanup page.' -Size 11 -Color '#6F82A3' -Margin '0,10,0,0')
}

function Show-GuiUninstallLogs {
    Reset-GuiPage -Title 'Uninstall logs' -Subtitle ('Folder: ' + $Script:UninstalledDir)
    $hist = @(Get-UninstallHistory)
    $lb = New-Object System.Windows.Controls.ListBox
    $lb.Height = 300
    $lb.Background = (Get-GuiBrush '#131D33'); $lb.Foreground = (Get-GuiBrush '#E8EEF8')
    foreach ($h in $hist) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $how = $h.Mode
        if ($h.Forced) { $how = 'Forced' }
        if (-not $how) { $how = 'not finished' }
        $item.Content = ("{0}    {1}    {2}    leftovers moved: {3}" -f $h.Started, $h.Name, $how, $(if ($h.LeftoversMoved) { $h.LeftoversMoved } else { '0' }))
        $item.Tag = $h
        [void]$lb.Items.Add($item)
    }
    $Script:GuiLogList = $lb
    Add-GuiChild $Script:GuiContent $lb
    if ($hist.Count -eq 0) { Add-GuiChild $Script:GuiContent (New-GuiText -Text 'Nothing has been uninstalled with DIVuninstaller yet.' -Color '#8DA0BF') }
    $det = New-GuiText -Text '' -Size 12 -Color '#8DA0BF' -Margin '0,8,0,0'
    $Script:GuiLogDetails = $det
    Add-GuiChild $Script:GuiContent $det
    $lb.Add_SelectionChanged({
        $it = $Script:GuiLogList.SelectedItem
        if (-not $it) { return }
        $h = $it.Tag
        $q = $h.Quarantine; if (-not $q) { $q = 'none' }
        $Script:GuiLogDetails.Text = ("{0} {1}`nStarted: {2}   Exit code: {3}   Scan level: {4}`nLeftovers found: {5}   moved: {6}`nQuarantine: {7}`nRecord and registry backup: {8}" -f $h.Name, $h.Version, $h.Started, $h.ExitCode, $h.Mode, $h.LeftoversFound, $h.LeftoversMoved, $q, $h.Path)
    })
    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = '0,10,0,0'
    Add-GuiChild $bar (New-GuiButton -Text 'OPEN FOLDER' -OnClick {
        $it = $Script:GuiLogList.SelectedItem
        $target = $Script:UninstalledDir
        if ($it) { $target = $it.Tag.Path }
        if (Test-Path -LiteralPath $target) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $target + '"') } else { Show-GuiMessage 'There is nothing to open yet.' }
    })
    Add-GuiChild $bar (New-GuiButton -Text 'BACK' -OnClick { Show-GuiUninstaller })
    Add-GuiChild $Script:GuiContent $bar
}

function Read-UninstallScanMode {
    if ((Get-UninstallerSettings).OnlyBuiltIn) { Write-Host '   Option set: only run the built-in uninstaller (no leftover scan).' -ForegroundColor DarkGray; return 'None' }
    Write-Host '   Leftover scan level:  [N] built-in (no scan)   [S] safe   [M] moderate   [A] advanced' -ForegroundColor DarkGray
    $c = (Read-Host '   Level (Enter = M)').Trim()
    switch -Regex ($c) {
        '^[Nn]' { return 'None' }
        '^[Ss]' { return 'Safe' }
        '^[Aa]' { return 'Advanced' }
        default { return 'Moderate' }
    }
}

function Invoke-ConsoleLeftoverStage {
    param($Program, [string]$Mode, [string]$RecordDir, $Others)
    if ($Mode -eq 'None') {
        Update-UninstallRecord -Dir $RecordDir -Values @{ Mode = 'Built-in'; LeftoversFound = 0; LeftoversMoved = 0 }
        Write-Tag INFO 'Built-in mode: no leftover scan.'
        Wait-Enter
        return
    }
    Write-Tag INFO ("Looking for leftovers ({0}), by exact name..." -f $Mode)
    $left = @(Get-ProgramLeftovers -Program $Program -OtherPrograms $Others -Mode $Mode)
    Update-UninstallRecord -Dir $RecordDir -Values @{ Mode = $Mode; LeftoversFound = $left.Count }
    if ($left.Count -eq 0) { Write-Tag INFO 'No leftovers were found.'; Wait-Enter; return }
    Invoke-ConsoleLeftoverReview -Items $left -Program $Program -RecordDir $RecordDir -Others $Others
}

function Invoke-ConsoleLeftoverReview {
    param($Items, $Program, [string]$RecordDir, $Others, [switch]$Batch)
    $left = @($Items)
    $settings = Get-UninstallerSettings
    $sel = @()
    while ($true) {
        Write-Host ''
        Show-LeftoverList -Items $left
        Write-Host ''
        Write-Host '   Nothing is selected unless you turned on "check all". Items are moved to quarantine; registry keys are exported first.' -ForegroundColor DarkGray
        Write-Host '   Red [PROTECTED] items are on your exclude list and are never touched.' -ForegroundColor DarkGray
        Write-Host '   X<numbers> add to exclude list   |   R<number> open in Regedit   |   F<number> show in Explorer' -ForegroundColor DarkGray
        $defHint = 'Enter = none'
        if ($settings.CheckAllByDefault) { $defHint = 'Enter = all matched' }
        $pick = (Read-Host ("   Numbers to quarantine (e.g. 1,3), L = all low-risk, A = all, {0}" -f $defHint)).Trim()
        if ($pick -match '^[Xx]\s*(.+)$') {
            foreach ($tok in ([string]$Matches[1] -split '[,\s]+')) {
                if ($tok -match '^\d+$') {
                    $k = [int]$tok
                    if ($k -ge 1 -and $k -le $left.Count) {
                        $it = $left[$k - 1]
                        $pat = [string]$it.Path
                        if ($it.Type -eq 'RunValue') { $pat = $pat + '\' + $it.Name }
                        try { [void](Add-ExcludeEntry -Pattern $pat); $it.Status = 'Protected'; Write-Tag OK ('Added to the exclude list: ' + $pat) } catch { Write-Tag WARN $_.Exception.Message }
                    }
                }
            }
            continue
        }
        if ($pick -match '^[Rr]\s*(\d+)$') {
            $k = [int]$Matches[1]
            if ($k -ge 1 -and $k -le $left.Count) { try { [void](Open-RegistryKeyInRegedit -Path $left[$k - 1].Path) } catch { Write-Tag WARN $_.Exception.Message } }
            continue
        }
        if ($pick -match '^[Ff]\s*(\d+)$') {
            $k = [int]$Matches[1]
            if ($k -ge 1 -and $k -le $left.Count) { try { Open-LeftoverFolder -Path $left[$k - 1].Path } catch { Write-Tag WARN $_.Exception.Message } }
            continue
        }
        if ($pick -match '^[Aa]$') { $sel = @($left | Where-Object { $_.Status -ne 'Protected' }) }
        elseif ($pick -match '^[Ll]$') { $sel = @($left | Where-Object { $_.Risk -eq 'LOW' -and $_.Status -ne 'Protected' }) }
        elseif (-not $pick -and $settings.CheckAllByDefault) { $sel = @($left | Where-Object { $_.Status -ne 'Protected' }) }
        elseif ($pick) {
            foreach ($tok in ($pick -split '[,\s]+')) {
                if ($tok -match '^\d+$') {
                    $k = [int]$tok
                    if ($k -ge 1 -and $k -le $left.Count -and $left[$k - 1].Status -ne 'Protected') { $sel += $left[$k - 1] }
                }
            }
        }
        break
    }
    if ($sel.Count -eq 0) { Update-UninstallRecord -Dir $RecordDir -Values @{ LeftoversMoved = 0 }; Write-Tag INFO 'Nothing was moved.'; Wait-Enter; return }
    if (Read-YesNo -Prompt ("Move {0} item(s) to quarantine?" -f $sel.Count)) {
        if ($Batch) { $m = Move-BatchLeftovers -Items $sel -OtherPrograms $Others }
        else {
            $m = Move-LeftoversToQuarantine -Items $sel -ProgramName $Program.Name -OtherPrograms $Others
            Update-UninstallRecord -Dir $RecordDir -Values @{ LeftoversMoved = $m.Moved; Quarantine = $m.Dir }
        }
        Write-KV 'Moved' $m.Moved 'Green'
        Write-KV 'Left alone' $m.Failed $(if ($m.Failed -gt 0) { 'Yellow' } else { 'Gray' })
    }
    Wait-Enter
}

function Invoke-ConsoleExcludeList {
    while ($true) {
        Clear-Host
        Show-Header 'DIVUNINSTALLER (Exclude list)'
        Write-Host '   Listed folders and registry keys are never moved. A pattern covers everything under it. * = any text, ? = one character.' -ForegroundColor DarkGray
        $list = @(Get-ExcludeList)
        if ($list.Count -eq 0) { Write-Tag INFO 'The exclude list is empty.' }
        $i = 0
        foreach ($p in $list) { $i++; Write-Host ('  {0,3}  {1}' -f $i, $p) }
        Write-Host ''
        $c = (Read-Host '   A <path> add   |   D <number> remove   |   B back').Trim()
        if ($c -match '^[Bb]$' -or -not $c) { return }
        if ($c -match '^[Aa]\s+(.+)$') {
            try { [void](Add-ExcludeEntry -Pattern ([string]$Matches[1])); Write-Tag OK 'Added.' } catch { Write-Tag WARN $_.Exception.Message }
            continue
        }
        if ($c -match '^[Dd]\s*(\d+)$') {
            $k = [int]$Matches[1]
            if ($k -ge 1 -and $k -le $list.Count) { Remove-ExcludeEntry -Pattern $list[$k - 1]; Write-Tag OK 'Removed.' } else { Write-Tag WARN 'No such number.' }
            continue
        }
    }
}

function Invoke-ConsoleUninstallerOptions {
    while ($true) {
        Clear-Host
        Show-Header 'DIVUNINSTALLER (Options)'
        $s = Get-UninstallerSettings
        Write-Host ('  1  Check all matched leftovers by default ........ {0}' -f $(if ($s.CheckAllByDefault) { 'ON' } else { 'off' }))
        Write-Host ('  2  Force-stop programs in the install folder ..... {0}' -f $(if ($s.ForceStopExecutables) { 'ON' } else { 'off' }))
        Write-Host ('  3  Only run the built-in uninstaller (no scan) ... {0}' -f $(if ($s.OnlyBuiltIn) { 'ON' } else { 'off' }))
        Write-Host ''
        $c = (Read-Host '   Number to switch on/off, B = back').Trim()
        switch ($c) {
            '1' { [void](Set-UninstallerSetting -Name 'CheckAllByDefault' -Value (-not $s.CheckAllByDefault)) }
            '2' { [void](Set-UninstallerSetting -Name 'ForceStopExecutables' -Value (-not $s.ForceStopExecutables)) }
            '3' { [void](Set-UninstallerSetting -Name 'OnlyBuiltIn' -Value (-not $s.OnlyBuiltIn)) }
            default { if ($c -match '^[Bb]$' -or -not $c) { return } }
        }
    }
}

function Invoke-ConsoleForcedByName {
    Clear-Host
    Show-Header 'DIVUNINSTALLER (Forced uninstall by name)'
    Write-Host '   For a program that is not listed, was removed earlier, or was only partly installed.' -ForegroundColor DarkGray
    Write-Host '   No uninstaller is run from here. It scans for leftovers by exact name and folder.' -ForegroundColor DarkGray
    $nm = (Read-Host '   Program name (several can be separated with ; when searching)').Trim()
    $pt = (Read-Host '   Install folder (optional, inside Program Files / ProgramData / AppData)').Trim()
    if (-not $nm -and -not $pt) { return }
    $all = @(Get-InstalledPrograms)
    $found = @(Find-UninstallMatches -Name $nm -Path $pt -Programs $all)
    $prog = $null
    if ($found.Count -gt 0) {
        $i = 0
        foreach ($f in $found) { $i++; Write-Host ('  {0,3}  {1}: {2} {3}' -f $i, $f.Source, $f.Name, $f.Version) }
        Write-Host '   A program that is still installed has its own uninstaller. Use the normal UNINSTALL for it.' -ForegroundColor DarkGray
        $k = (Read-Host '   Number to scan for (Enter = scan by what you typed)').Trim()
        if ($k -match '^\d+$' -and [int]$k -ge 1 -and [int]$k -le $found.Count) {
            $sel = $found[[int]$k - 1]
            if ($sel.Program) { $prog = $sel.Program } else { try { $prog = New-ForcedProgram -Name $sel.Name -InstallLocation $pt } catch { Write-Tag WARN $_.Exception.Message; Wait-Enter; return } }
        }
    } else { Write-Tag INFO 'Nothing matched. The leftover scan can still run by name and folder.' }
    if (-not $prog) { try { $prog = New-ForcedProgram -Name $nm -InstallLocation $pt } catch { Write-Tag WARN $_.Exception.Message; Wait-Enter; return } }
    if ($prog.Protected) { Write-Tag WARN ("{0} is protected and cannot be removed here." -f $prog.Name); Wait-Enter; return }
    Write-KV 'Scanning for' $prog.Name
    if (-not (Read-YesNo -Prompt 'Make a restore point and scan at the Advanced level?')) { return }
    try { $r = Invoke-ProgramUninstall -Program $prog -SkipUninstaller } catch { Write-Tag FAIL $_.Exception.Message; Wait-Enter; return }
    $others = @($all | Where-Object { $_.KeyPath -ne $prog.KeyPath })
    Invoke-ConsoleLeftoverStage -Program $prog -Mode 'Advanced' -RecordDir $r.BackupDir -Others $others
}

function Invoke-ConsoleBatchUninstall {
    param($Programs, $All)
    $progs = @($Programs)
    $problem = Test-BatchProgramsReady -Programs $progs
    if ($problem) { Write-Tag WARN $problem; Wait-Enter; return }
    Write-Host ''
    foreach ($p in $progs) { Write-KV 'Program' ($p.Name + ' ' + $p.Version) }
    $mode = Read-UninstallScanMode
    Write-Host ('   ' + (Get-ScanModeDescription -Mode $mode)) -ForegroundColor DarkGray
    Write-Host ('   Steps: ONE restore point, then each program''s own uninstaller one after another, then one combined leftover list.') -ForegroundColor DarkGray
    if (-not (Read-YesNo -Prompt ("Uninstall these {0} programs now?" -f $progs.Count))) { return }
    try { $b = Invoke-BatchUninstall -Programs $progs } catch { Write-Tag FAIL $_.Exception.Message; Wait-Enter; return }
    $gone = @($b.Results | Where-Object { $_.Result -and -not $_.Result.StillInstalled }).Count
    Write-KV 'Gone' ('{0} of {1}' -f $gone, $progs.Count) $(if ($gone -eq $progs.Count) { 'Green' } else { 'Yellow' })
    foreach ($r in @($b.Results | Where-Object { $_.Result -and $_.Result.StillInstalled })) { Write-Tag WARN ("{0} still appears to be installed (cancelled or failed)." -f $r.Program.Name) }
    if ($mode -eq 'None' -or $gone -eq 0) {
        foreach ($r in @($b.Results)) { if ($r.Result) { Update-UninstallRecord -Dir $r.Result.BackupDir -Values @{ Mode = $(if ($mode -eq 'None') { 'Built-in' } else { $mode }); LeftoversFound = 0; LeftoversMoved = 0 } } }
        Wait-Enter
        return
    }
    $left = @(Get-BatchLeftovers -Batch $b -Mode $mode -AllPrograms $All)
    if ($left.Count -eq 0) { Write-Tag INFO 'No leftovers were found.'; Wait-Enter; return }
    $keys = @($progs | ForEach-Object { $_.KeyPath })
    $others = @($All | Where-Object { $keys -notcontains $_.KeyPath })
    Invoke-ConsoleLeftoverReview -Items $left -Program ([pscustomobject]@{ Name = ('{0} programs' -f $progs.Count) }) -RecordDir '' -Others $others -Batch
}

function Invoke-ConsoleWindowsApps {
    Clear-Host
    Show-Header 'DIVUNINSTALLER (Windows Apps)'
    Write-Host '   Store and built-in apps for your account. Protected apps cannot be removed here.' -ForegroundColor DarkGray
    $filter = (Read-Host '   Filter by name (Enter = all)').Trim()
    Write-Busy -Activity 'Reading Windows apps' -Status 'Asking Windows for the list...' -Percent 30
    $apps = @(Get-WindowsApps | Where-Object { (-not $filter) -or ($_.Name -like ('*' + $filter + '*')) } | Select-Object -First 80)
    Write-Busy -Activity 'Reading Windows apps' -Status 'Done' -Percent 100
    if ($apps.Count -eq 0) { Write-Tag INFO 'No apps matched.'; Wait-Enter; return }
    $i = 0
    foreach ($a in $apps) { $i++; Write-Host ('  {0,3}  {1}  {2}{3}' -f $i, $a.Name, $a.Version, $(if ($a.Protected) { '  [protected]' } else { '' })) }
    Write-Host ''
    $pick = (Read-Host '   Numbers to remove (e.g. 2,5), Enter = none').Trim()
    if (-not $pick) { return }
    $sel = @()
    foreach ($tok in ($pick -split '[,\s]+')) { if ($tok -match '^\d+$') { $k = [int]$tok; if ($k -ge 1 -and $k -le $apps.Count) { $sel += $apps[$k - 1] } } }
    if ($sel.Count -eq 0) { return }
    if (@($sel | Where-Object { $_.Protected }).Count -gt 0) { Write-Tag WARN 'One or more picks are protected. Nothing was removed.'; Wait-Enter; return }
    $scope = (Read-Host '   For [M]e only (default) or [A]ll users (needs Administrator)').Trim()
    Write-Host '   Removal cannot be undone here; reinstall from the Microsoft Store if needed. A restore point is made first.' -ForegroundColor Yellow
    if (-not (Read-YesNo -Prompt ("Remove {0} app(s)?" -f $sel.Count))) { return }
    try {
        if ($scope -match '^[Aa]') { $r = Remove-WindowsApps -Apps $sel -AllUsers } else { $r = Remove-WindowsApps -Apps $sel }
        Write-KV 'Removed' (@($r.Results | Where-Object { $_.Removed -gt 0 }).Count) 'Green'
    } catch { Write-Tag FAIL $_.Exception.Message }
    Wait-Enter
}

function Invoke-ConsoleBrowserExtensions {
    Clear-Host
    Show-Header 'DIVUNINSTALLER (Browser extensions)'
    Write-Host '   Chrome, Edge, Brave and Firefox. Removal moves the extension to quarantine (restore from the quarantine page).' -ForegroundColor DarkGray
    $filter = (Read-Host '   Filter by name or browser (Enter = all)').Trim()
    $all = @(Get-BrowserExtensions | Where-Object { (-not $filter) -or ($_.Name -like ('*' + $filter + '*')) -or ($_.Browser -like ('*' + $filter + '*')) } | Select-Object -First 100)
    if ($all.Count -eq 0) { Write-Tag INFO 'No extensions found.'; Wait-Enter; return }
    $i = 0
    foreach ($x in $all) { $i++; Write-Host ('  {0,3}  {1}  {2}  {3}  [{4}]' -f $i, $x.Browser, $x.Name, $x.Version, $x.Profile) }
    Write-Host ''
    $pick = (Read-Host '   Numbers to move to quarantine (e.g. 2,5), Enter = none').Trim()
    if (-not $pick) { return }
    $sel = @()
    foreach ($tok in ($pick -split '[,\s]+')) { if ($tok -match '^\d+$') { $k = [int]$tok; if ($k -ge 1 -and $k -le $all.Count) { $sel += $all[$k - 1] } } }
    if ($sel.Count -eq 0) { return }
    if (-not (Read-YesNo -Prompt ("Move {0} extension(s) to quarantine? Close the browser first." -f $sel.Count))) { return }
    try { $r = Remove-BrowserExtensions -Items $sel; Write-KV 'Moved' $r.Moved 'Green'; Write-KV 'Left alone' $r.Failed $(if ($r.Failed -gt 0) { 'Yellow' } else { 'Gray' }) } catch { Write-Tag WARN $_.Exception.Message }
    Wait-Enter
}

function Invoke-ConsoleInstallMonitor {
    while ($true) {
        Clear-Host
        Show-Header 'DIVUNINSTALLER (Install monitor)'
        Write-Host '   Records what a program adds while it installs, so it can be cleaned up later. Best-effort: you review every item; items go to quarantine.' -ForegroundColor DarkGray
        $pending = Get-PendingTrace
        if ($pending) { Write-Tag INFO ("A trace is in progress for '{0}' (started {1}). Install it, open it once, then choose F." -f $pending.Name, $pending.Started) }
        $logs = @(Get-TraceLogs)
        $i = 0
        foreach ($l in $logs) { $i++; Write-Host ('  {0,3}  {1}   {2}   {3} item(s)' -f $i, $l.Name, $l.Finished, $l.Count) }
        Write-Host ''
        if ($pending) { Write-Host '   F finish trace   |   X cancel trace   |   C <n> clean up   |   E <n> edit   |   M <n,n> merge   |   P <n> <file> export   |   I <file> import   |   D <n> delete   |   B back' -ForegroundColor DarkGray }
        else { Write-Host '   S start a trace   |   C <n> clean up   |   E <n> edit   |   M <n,n> merge   |   P <n> <file> export   |   I <file> import   |   D <n> delete   |   B back' -ForegroundColor DarkGray }
        $c = (Read-Host '   Choice').Trim()
        if ($c -match '^[Bb]$' -or -not $c) { return }
        if ($c -match '^[Ss]$' -and -not $pending) {
            $nm = (Read-Host '   Name of the program you are about to install').Trim()
            if ($nm.Length -lt 2) { continue }
            try { Write-Tag INFO 'Taking the first snapshot (names only; this can take a minute)...'; [void](Start-InstallTrace -Name $nm); Write-Tag OK 'Ready. Install the program now, then come back and choose F.'; Wait-Enter } catch { Write-Tag FAIL $_.Exception.Message; Wait-Enter }
            continue
        }
        if ($c -match '^[Ff]$' -and $pending) {
            try { Write-Tag INFO 'Taking the second snapshot...'; $r = Complete-InstallTrace; Write-Tag OK ("Saved. {0} item(s) were created during the install." -f $r.Count); if (@($r.Diff.Services).Count -gt 0) { Write-Tag INFO ("New services (listed only, never removed): {0}" -f (@($r.Diff.Services) -join ', ')) } } catch { Write-Tag FAIL $_.Exception.Message }
            Wait-Enter
            continue
        }
        if ($c -match '^[Xx]$' -and $pending) { if (Read-YesNo -Prompt 'Throw away the saved starting snapshot?') { Stop-InstallTrace }; continue }
        if ($c -match '^[Ee]\s*(\d+)$') { $n = [int]$Matches[1]; if ($n -ge 1 -and $n -le $logs.Count) { Invoke-ConsoleTraceEditor -Dir $logs[$n - 1].Path } else { Write-Tag WARN 'No such number.'; Wait-Enter }; continue }
        if ($c -match '^[Mm]\s*(.+)$') {
            $sel = @()
            foreach ($tok in ([string]$Matches[1] -split '[,\s]+')) { if ($tok -match '^\d+$') { $k = [int]$tok; if ($k -ge 1 -and $k -le $logs.Count -and ($sel -notcontains $logs[$k - 1].Path)) { $sel += $logs[$k - 1].Path } } }
            try { [void](Merge-TraceLogs -Dirs $sel -Name ('Merged log ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))); Write-Tag OK 'Merged into a new log (rename it with E <n> then N).' } catch { Write-Tag WARN $_.Exception.Message }
            Wait-Enter
            continue
        }
        if ($c -match '^[Pp]\s*(\d+)\s+(.+)$') {
            $n = [int]$Matches[1]; $file = ([string]$Matches[2]).Trim().Trim('"')
            if ($n -ge 1 -and $n -le $logs.Count) { try { Export-TraceLog -Dir $logs[$n - 1].Path -Destination $file; Write-Tag OK ('Saved to ' + $file) } catch { Write-Tag WARN $_.Exception.Message } } else { Write-Tag WARN 'No such number.' }
            Wait-Enter
            continue
        }
        if ($c -match '^[Ii]\s+(.+)$') {
            try { $r = Import-TraceLog -Source (([string]$Matches[1]).Trim().Trim('"')); Write-Tag OK ("Imported {0} item(s); {1} skipped by the safety checks. Review it with E <n> before cleaning up." -f $r.Imported, $r.Skipped) } catch { Write-Tag WARN $_.Exception.Message }
            Wait-Enter
            continue
        }
        if ($c -match '^([CcDd])\s*(\d+)$') {
            $verb = [string]$Matches[1]; $n = [int]$Matches[2]
            if ($n -lt 1 -or $n -gt $logs.Count) { Write-Tag WARN 'No such number.'; Wait-Enter; continue }
            $log = $logs[$n - 1]
            if ($verb -match '^[Dd]$') {
                if (Read-YesNo -Prompt ("Delete the trace log for '{0}'? (The program is not touched.)" -f $log.Name)) { try { Remove-TraceLog -Dir $log.Path; Write-Tag OK 'Deleted.' } catch { Write-Tag FAIL $_.Exception.Message }; Wait-Enter }
                continue
            }
            $all = @(Get-InstalledPrograms)
            if (@($all | Where-Object { $_.Name -ieq $log.Name }).Count -gt 0) {
                Write-Tag WARN ("{0} is still listed as installed. Uninstall it first from the main list so its own uninstaller runs." -f $log.Name)
                if (-not (Read-YesNo -Prompt 'Clean up from the log anyway?')) { continue }
            }
            $items = @(Get-TraceReviewItems -Log $log)
            if ($items.Count -eq 0) { Write-Tag INFO 'Everything in this log is already gone.'; Wait-Enter; continue }
            $others = @($all | Where-Object { $_.Name -ine $log.Name })
            Invoke-ConsoleLeftoverReview -Items $items -Program ([pscustomobject]@{ Name = $log.Name }) -RecordDir '' -Others $others
        }
    }
}

function Invoke-ConsoleTraceEditor {
    param([string]$Dir)
    while ($true) {
        Clear-Host
        Show-Header 'DIVUNINSTALLER (Edit trace log)'
        $d = Read-TraceData -Dir $Dir
        Write-KV 'Name' $d.Name
        if ($d.Comment) { Write-KV 'Comment' $d.Comment }
        $i = 0
        foreach ($x in @($d.Items)) { $i++; $what = $x.Path; if ($x.Name) { $what = $x.Path + ' -> ' + $x.Name }; Write-Host ('  {0,3}  {1}: {2}' -f $i, $x.Type, $what) }
        Write-Host ''
        Write-Host '   R <numbers> remove from log   |   A add item   |   N rename / comment   |   B back   (only the log changes)' -ForegroundColor DarkGray
        $c = (Read-Host '   Choice').Trim()
        if ($c -match '^[Bb]$' -or -not $c) { return }
        if ($c -match '^[Rr]\s*(.+)$') {
            $sel = @()
            foreach ($tok in ([string]$Matches[1] -split '[,\s]+')) { if ($tok -match '^\d+$') { $k = [int]$tok; if ($k -ge 1 -and $k -le @($d.Items).Count) { $sel += [pscustomobject]@($d.Items)[$k - 1] } } }
            if ($sel.Count -gt 0) { try { $n = Remove-TraceItems -Dir $Dir -Items $sel; Write-Tag OK ("Removed {0} item(s) from the log." -f $n) } catch { Write-Tag WARN $_.Exception.Message } }
            continue
        }
        if ($c -match '^[Aa]$') {
            $t = (Read-Host '   Type: F folder, L file, K registry key, R startup value').Trim().ToUpper()
            $type = switch ($t) { 'F' { 'Folder' } 'L' { 'File' } 'K' { 'RegistryKey' } 'R' { 'RunValue' } default { '' } }
            if (-not $type) { continue }
            $p = (Read-Host '   Full path').Trim()
            $vn = ''
            if ($type -eq 'RunValue') { $vn = (Read-Host '   Value name').Trim() }
            try { Add-TraceItem -Dir $Dir -Type $type -Path $p -Name $vn; Write-Tag OK 'Added.' } catch { Write-Tag WARN $_.Exception.Message; Wait-Enter }
            continue
        }
        if ($c -match '^[Nn]$') {
            $nm = (Read-Host ("   New name (Enter = keep '{0}')" -f $d.Name)).Trim()
            if (-not $nm) { $nm = $d.Name }
            $cm = (Read-Host '   Comment (Enter = keep)').Trim()
            if (-not $cm) { $cm = $d.Comment }
            try { Set-TraceDetails -Dir $Dir -Name $nm -Comment $cm } catch { Write-Tag WARN $_.Exception.Message; Wait-Enter }
            continue
        }
    }
}

function Invoke-JunkPage {
    while ($true) {
        Clear-Host
        Show-Header 'JUNK CLEANER (old temp files, dumps, reports, caches)'
        Write-Host '   Read-only scan first. Nothing is selected for you. Items go to quarantine (restorable) unless you choose permanent delete.' -ForegroundColor DarkGray
        $rows = @(Get-JunkScan)
        $i = 0
        foreach ($r in $rows) {
            $i++
            $extra = ''
            if ($r.RecentSkipped -gt 0) { $extra = ('   ({0} newer kept)' -f $r.RecentSkipped) }
            Write-Host ('  {0,3}  {1,-24} {2,10}   {3:N0} file(s){4}' -f $i, $r.Name, (Format-Bytes $r.Bytes), $r.Files, $extra)
            foreach ($b in @($r.Blocked)) { Write-Host ('         ' + $b) -ForegroundColor Yellow }
        }
        Write-Host ''
        Write-Host '   Never touched: Recycle Bin, Downloads, Documents, Desktop, browser history/cookies/passwords.' -ForegroundColor DarkGray
        $c = (Read-Host '   Numbers to clean (e.g. 1,3), Q = quarantine page, B = back').Trim()
        if (-not $c -or $c -match '^[Bb]$') { return }
        if ($c -match '^[Qq]$') { Invoke-QuarantinePage; continue }
        $sel = @()
        foreach ($tok in ($c -split '[,\s]+')) { if ($tok -match '^\d+$') { $k = [int]$tok; if ($k -ge 1 -and $k -le $rows.Count -and $rows[$k - 1].Units.Count -gt 0 -and ($sel -notcontains $rows[$k - 1])) { $sel += $rows[$k - 1] } } }
        if ($sel.Count -eq 0) { Write-Tag WARN 'Nothing selected.'; Wait-Enter; continue }
        $mode = (Read-Host '   [M] move to quarantine (can be restored)   [D] delete permanently (cannot be undone)   Enter = M').Trim()
        $perm = ($mode -match '^[Dd]')
        $label = 'Move to quarantine'; if ($perm) { $label = 'PERMANENTLY delete' }
        if (-not (Read-YesNo -Prompt ("{0}: {1}?" -f $label, (($sel | ForEach-Object { $_.Name }) -join ', ')))) { continue }
        foreach ($r in $sel) {
            try {
                $res = Move-JunkToQuarantine -Category $r.Category -Units $r.Units -Permanent:$perm
                Write-KV $r.Name ('{0} moved ({1}), {2} skipped' -f $res.Moved, (Format-Bytes $res.Bytes), $res.Failed) 'Green'
            } catch { Write-Tag FAIL $_.Exception.Message }
        }
        Wait-Enter
    }
}

function Invoke-UninstallerPage {
    while ($true) {
        Clear-Host
        Show-Header 'DIVUNINSTALLER (Uninstall a program and clear its leftovers)'
        $filter = (Read-Host '   Search by name (Enter = all, L = logs, Q = quarantine, N = forced by name, W = Windows apps, X = browser extensions, T = install monitor, S = startup manager, E = exclude list, J = junk cleaner, O = options, B = back)').Trim()
        if ($filter -match '^[Bb]$') { return }
        if ($filter -match '^[Nn]$') { Invoke-ConsoleForcedByName; continue }
        if ($filter -match '^[Ww]$') { Invoke-ConsoleWindowsApps; continue }
        if ($filter -match '^[Xx]$') { Invoke-ConsoleBrowserExtensions; continue }
        if ($filter -match '^[Tt]$') { Invoke-ConsoleInstallMonitor; continue }
        if ($filter -match '^[Ss]$') { Invoke-StartupPage; continue }
        if ($filter -match '^[Ee]$') { Invoke-ConsoleExcludeList; continue }
        if ($filter -match '^[Oo]$') { Invoke-ConsoleUninstallerOptions; continue }
        if ($filter -match '^[Qq]$') { Invoke-QuarantinePage; continue }
        if ($filter -match '^[Jj]$') { Invoke-JunkPage; continue }
        if ($filter -match '^[Ll]$') {
            $hist = @(Get-UninstallHistory)
            if ($hist.Count -eq 0) { Write-Tag INFO 'Nothing has been uninstalled with DIVuninstaller yet.' }
            foreach ($h in $hist) {
                $how = $h.Mode; if ($h.Forced) { $how = 'Forced' }; if (-not $how) { $how = 'not finished' }
                Write-Host ('  {0}  {1} {2}  [{3}]  leftovers moved: {4}' -f $h.Started, $h.Name, $h.Version, $how, $(if ($h.LeftoversMoved) { $h.LeftoversMoved } else { '0' }))
            }
            Wait-Enter
            continue
        }
        Write-Busy -Activity 'Reading installed programs' -Status 'Reading the list Windows keeps...' -Percent 30
        $all = @(Get-InstalledPrograms)
        Write-Busy -Activity 'Reading installed programs' -Status 'Done' -Percent 100
        $shown = @($all | Where-Object { (-not $filter) -or ($_.Name -like ('*' + $filter + '*')) } | Select-Object -First 60)
        if ($shown.Count -eq 0) { Write-Tag INFO 'No programs matched.'; Wait-Enter; continue }
        $i = 0
        foreach ($p in $shown) {
            $i++
            $sz = ''
            if ($p.SizeKB -gt 0) { $sz = Format-Bytes ([double]$p.SizeKB * 1024) }
            $tag = ''
            if ($p.Protected) { $tag = '  [protected]' }
            Write-Host ('  {0,3}  {1}  {2}  {3}{4}' -f $i, $p.Name, $p.Version, $sz, $tag)
        }
        Write-Host ''
        Write-Host '   <n> uninstall   |   <n>,<n>,<n> uninstall several in one go   |   F<n> forced uninstall   |   D<n> details   |   Enter = search again' -ForegroundColor DarkGray
        $c = (Read-Host '   Choice').Trim()
        $forced = $false
        $details = $false
        if ($c -match '^\d+(\s*[,\s]\s*\d+)+$') {
            $batchSel = @()
            foreach ($tok in ($c -split '[,\s]+')) { if ($tok -match '^\d+$') { $k = [int]$tok; if ($k -ge 1 -and $k -le $shown.Count -and ($batchSel -notcontains $shown[$k - 1])) { $batchSel += $shown[$k - 1] } } }
            if ($batchSel.Count -gt 1) { Invoke-ConsoleBatchUninstall -Programs $batchSel -All $all; continue }
            if ($batchSel.Count -eq 1) { $c = [string]([array]::IndexOf(@($shown), $batchSel[0]) + 1) } else { continue }
        }
        if ($c -match '^[Ff]\s*(\d+)$') { $forced = $true; $c = [string]$Matches[1] }
        elseif ($c -match '^[Dd]\s*(\d+)$') { $details = $true; $c = [string]$Matches[1] }
        if ($c -notmatch '^\d+$') { continue }
        $n = [int]$c
        if ($n -lt 1 -or $n -gt $shown.Count) { Write-Tag WARN 'No such number.'; Wait-Enter; continue }
        $p = $shown[$n - 1]
        if ($details) { Write-Host ''; Write-Host (Get-ProgramDetailsText -Program $p); Wait-Enter; continue }
        if ($p.Protected) { Write-Tag WARN ("{0} is protected. Use Windows Settings > Apps to remove it." -f $p.Name); Wait-Enter; continue }
        $others = @($all | Where-Object { $_.KeyPath -ne $p.KeyPath })
        if ($forced) {
            Write-Host ''
            Write-KV 'Program' ($p.Name + ' ' + $p.Version)
            Write-Host '   Forced uninstall does NOT run the program''s uninstaller. It makes a restore point, backs up the registry entry,' -ForegroundColor Yellow
            Write-Host '   then scans at the Advanced level. Nothing is selected for you.' -ForegroundColor Yellow
            if (-not (Read-YesNo -Prompt 'Start a forced uninstall?')) { continue }
            try { $r = Invoke-ProgramUninstall -Program $p -SkipUninstaller } catch { Write-Tag FAIL $_.Exception.Message; Wait-Enter; continue }
            Invoke-ConsoleLeftoverStage -Program $p -Mode 'Advanced' -RecordDir $r.BackupDir -Others $others
            continue
        }
        $cmd = Split-UninstallCommand -Text $p.UninstallString
        if (-not $cmd) { Write-Tag FAIL 'The uninstall command could not be read safely, so nothing was run. Try a forced uninstall (F<n>).'; Wait-Enter; continue }
        Write-Host ''
        Write-KV 'Program' ($p.Name + ' ' + $p.Version)
        Write-KV 'Command' ($cmd.File + ' ' + $cmd.Arguments)
        $mode = Read-UninstallScanMode
        Write-Host ('   ' + (Get-ScanModeDescription -Mode $mode)) -ForegroundColor DarkGray
        Write-Host '   Steps: restore point, back up the registry entry, run its own uninstaller, then the scan above.' -ForegroundColor DarkGray
        if (-not (Read-YesNo -Prompt 'Uninstall this program now?')) { continue }
        try { $r = Invoke-ProgramUninstall -Program $p } catch { Write-Tag FAIL $_.Exception.Message; Wait-Enter; continue }
        if ($r.StillInstalled) {
            Update-UninstallRecord -Dir $r.BackupDir -Values @{ Mode = $mode; LeftoversFound = 0; LeftoversMoved = 0 }
            Write-Tag WARN ("{0} still appears to be installed (exit code {1}). Leftovers are not scanned until it is gone. If its uninstaller is broken, use F<n>." -f $p.Name, $r.ExitCode)
            Wait-Enter
            continue
        }
        Write-Tag OK 'The program is no longer listed.'
        Invoke-ConsoleLeftoverStage -Program $p -Mode $mode -RecordDir $r.BackupDir -Others $others
    }
}

function Show-GuiQuarantine {
    Reset-GuiPage -Title 'Quarantine' -Subtitle ('Folder: ' + $Script:QuarantineDir)
    $list = @(Get-QuarantineList)
    $lb = New-Object System.Windows.Controls.ListBox
    $lb.Height = 300
    $lb.Background = (Get-GuiBrush '#131D33'); $lb.Foreground = (Get-GuiBrush '#E8EEF8')
    foreach ($q in $list) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = ("{0}    {1}    {2} item(s)    {3}" -f $q.Program, $q.Created, $q.Count, (Format-Bytes $q.SizeBytes))
        $item.Tag = $q
        [void]$lb.Items.Add($item)
    }
    $Script:GuiQuarList = $lb
    Add-GuiChild $Script:GuiContent $lb
    if ($list.Count -eq 0) { Add-GuiChild $Script:GuiContent (New-GuiText -Text 'The quarantine is empty.' -Color '#8DA0BF') }
    $bar = New-Object System.Windows.Controls.WrapPanel
    $bar.Margin = '0,10,0,0'
    Add-GuiChild $bar (New-GuiButton -Text 'RESTORE' -Bg '#238636' -OnClick {
        $it = $Script:GuiQuarList.SelectedItem
        if (-not $it) { Show-GuiMessage 'Select an entry first.'; return }
        if (-not (Confirm-Gui ("Put everything from this quarantine entry back where it was?`n`n{0}" -f $it.Tag.Program) 'Confirm restore' 'Question')) { return }
        $r = Invoke-GuiWithBusy -Title 'Restoring' -Detail 'Moving folders back and importing registry keys...' -Action { Restore-Quarantine -Session $it.Tag }
        Show-GuiMessage ("Restored {0}. Skipped {1} (already present). Failed {2}." -f $r.Restored, $r.Skipped, $r.Failed)
        Show-GuiQuarantine
    })
    Add-GuiChild $bar (New-GuiButton -Text 'DELETE PERMANENTLY' -OnClick {
        $it = $Script:GuiQuarList.SelectedItem
        if (-not $it) { Show-GuiMessage 'Select an entry first.'; return }
        if (Confirm-Gui ("Permanently delete this quarantine entry?`n`n{0}   {1}`n`nThis cannot be undone." -f $it.Tag.Program, (Format-Bytes $it.Tag.SizeBytes)) 'Confirm delete' 'Warning') {
            try { Remove-QuarantineFolder -Dir $it.Tag.Path; Show-GuiQuarantine } catch { Show-GuiMessage $_.Exception.Message 'Failed' 'Error' }
        }
    })
    Add-GuiChild $bar (New-GuiButton -Text 'OPEN FOLDER' -OnClick {
        if (-not (Test-Path -LiteralPath $Script:QuarantineDir)) { New-Item -ItemType Directory -Path $Script:QuarantineDir -Force | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Script:QuarantineDir + '"')
    })
    Add-GuiChild $bar (New-GuiButton -Text 'BACK' -OnClick { Show-GuiUninstaller })
    Add-GuiChild $Script:GuiContent $bar
}

function Show-LeftoverList {
    param($Items)
    $i = 0
    foreach ($it in @($Items)) {
        $i++
        $sz = ''
        if ($it.SizeBytes -gt 0) { $sz = '  ' + (Format-Bytes $it.SizeBytes) }
        $what = $it.Path
        if ($it.Name) { $what = $it.Path + ' -> ' + $it.Name }
        if ($it.Status -eq 'Protected') { Write-Host ('  {0,3}  [PROTECTED] {1}: {2}   (exclude list)' -f $i, $it.Type, $what) -ForegroundColor Red }
        else { Write-Host ('  {0,3}  [{1}] {2}: {3}{4}' -f $i, $it.Risk, $it.Type, $what, $sz) }
    }
}

function Invoke-QuarantinePage {
    while ($true) {
        Clear-Host
        Show-Header 'DIVUNINSTALLER (Quarantine)'
        $list = @(Get-QuarantineList)
        if ($list.Count -eq 0) { Write-Tag INFO 'The quarantine is empty.'; Wait-Enter; return }
        $i = 0
        foreach ($q in $list) { $i++; Write-Host ('  {0,3}  {1}   {2}   {3} item(s)   {4}' -f $i, $q.Program, $q.Created, $q.Count, (Format-Bytes $q.SizeBytes)) }
        Write-Host ''
        Write-Host '   R <n>  restore   |   D <n>  delete permanently (cannot be undone)   |   B  back' -ForegroundColor DarkGray
        $c = (Read-Host '   Choice').Trim()
        if ($c -match '^[Bb]$') { return }
        if ($c -match '^([RrDd])\s*(\d+)$') {
            $verb = [string]$Matches[1]
            $n = [int]$Matches[2]
            if ($n -lt 1 -or $n -gt $list.Count) { Write-Tag WARN 'No such entry.'; Wait-Enter; continue }
            $q = $list[$n - 1]
            if ($verb -match '^[Rr]$') {
                if (Read-YesNo -Prompt ("Restore everything from '{0}'?" -f $q.Program)) { $r = Restore-Quarantine -Session $q; Write-KV 'Restored' $r.Restored 'Green'; Write-KV 'Skipped' $r.Skipped 'Yellow'; Write-KV 'Failed' $r.Failed; Wait-Enter }
            } else {
                if (Read-YesNo -Prompt ("PERMANENTLY delete '{0}'? This cannot be undone." -f $q.Program)) {
                    try { Remove-QuarantineFolder -Dir $q.Path; Write-Tag OK 'Deleted.' } catch { Write-Tag FAIL $_.Exception.Message }
                    Wait-Enter
                }
            }
        }
    }
}

function Show-GuiTweaksHub {
    # Two tab-style buttons: our own tweaks, and the YouTuber Optimizations area (not available yet).
    param([ValidateSet('Ours', 'YouTuber', 'Uninstalled')][string]$Tab = 'Ours')
    Reset-GuiPage -Title 'Tweaks' -Subtitle 'Choose a set. Nothing changes until you review and approve it.'
    $p = $Script:GuiContent
    $tabs = New-Object System.Windows.Controls.WrapPanel
    $tabs.Margin = '0,0,0,10'
    $activeOurs = ''; $activeYt = ''; $activeUn = ''
    if ($Tab -eq 'Ours') { $activeOurs = '#4A5BD8' } elseif ($Tab -eq 'YouTuber') { $activeYt = '#4A5BD8' } else { $activeUn = '#4A5BD8' }
    Add-GuiChild $tabs (New-GuiButton -Text 'DIVOPTIMIZER TWEAKS' -Width 220 -Bg $activeOurs -OnClick { Show-GuiTweaksHub -Tab 'Ours' })
    Add-GuiChild $tabs (New-GuiButton -Text 'YOUTUBER OPTIMIZATIONS' -Width 240 -Bg $activeYt -OnClick { Show-GuiTweaksHub -Tab 'YouTuber' })
    Add-GuiChild $tabs (New-GuiButton -Text 'DIVUNINSTALLER' -Width 180 -Bg $activeUn -OnClick { Show-GuiTweaksHub -Tab 'Uninstalled' })
    Add-GuiChild $p $tabs
    if ($Tab -eq 'Ours') {
        Add-GuiChild $p (New-GuiText -Text 'Tweaks written and reviewed for DIVoptimizer. Each one shows its current and new value, its risk, and whether it can be undone.' -Size 12 -Color '#8DA0BF' -Margin '0,0,0,8')
        $o = New-Object System.Windows.Controls.WrapPanel
        Add-GuiChild $o (New-GuiNavButton 'PERFORMANCE' { Show-GuiCategory -Title 'Performance' -Categories @('Performance') })
        Add-GuiChild $o (New-GuiNavButton 'GAMING' { Show-GuiCategory -Title 'Gaming' -Categories @('Gaming') })
        Add-GuiChild $o (New-GuiNavButton 'PRIVACY' { Show-GuiCategory -Title 'Privacy' -Categories @('Privacy') })
        Add-GuiChild $o (New-GuiNavButton 'OPTIONAL APPS' { Show-GuiOptionalApps })
        Add-GuiChild $p $o
    } elseif ($Tab -eq 'Uninstalled') {
        Add-GuiChild $p (New-GuiText -Text 'Remove a program with its own uninstaller, then clear the folders and registry keys it leaves behind. Leftovers are moved to a quarantine you can restore from.' -Size 12 -Color '#8DA0BF' -Margin '0,0,0,8')
        $u = New-Object System.Windows.Controls.WrapPanel
        Add-GuiChild $u (New-GuiNavButton 'OPEN DIVUNINSTALLER' { Show-GuiUninstaller } '#238636')
        Add-GuiChild $u (New-GuiNavButton 'JUNK CLEANER' { Show-GuiJunkCleaner })
        Add-GuiChild $u (New-GuiNavButton 'QUARANTINE' { Show-GuiQuarantine })
        Add-GuiChild $p $u
    } else {
        $card = New-Object System.Windows.Controls.Border
        $card.Background = (Get-GuiBrush '#131D33'); $card.BorderBrush = (Get-GuiBrush '#25324D'); $card.BorderThickness = '1'
        $card.CornerRadius = '10'; $card.Padding = '20,16'; $card.Margin = '0,6,0,0'
        $sp = New-Object System.Windows.Controls.StackPanel
        Add-GuiChild $sp (New-GuiText -Text 'Coming soon' -Size 18 -Bold)
        Add-GuiChild $sp (New-GuiText -Text 'This area is not available yet, and nothing here can change your PC.' -Size 13 -Color '#8DA0BF' -Margin '0,6,0,0')
        Add-GuiChild $sp (New-GuiText -Text 'When it arrives, every tweak will be reviewed one by one and shown with its current and new value, its risk, and an undo, like everything else in DIVoptimizer. It will not be added by copying a list.' -Size 12 -Color '#8DA0BF' -Margin '0,10,0,0')
        $card.Child = $sp
        Add-GuiChild $p $card
    }
    Set-GuiStatus 'Ready.'
}

function Show-GuiDashboard {
    Reset-GuiPage -Title 'System' -Subtitle ''
    $s = $Script:LastScan
    $p = $Script:GuiContent
    Update-GuiSysLine
    if ($s) {
        $m = Get-HealthMetrics -Scan $s
        $g = New-Object System.Windows.Controls.WrapPanel
        foreach ($k in @('CPU', 'RAM', 'Storage', 'Startup Apps', 'Windows Update', 'Game Mode', 'Game DVR', 'HAGS')) {
            $card = New-Object System.Windows.Controls.Border
            $card.Background = (Get-GuiBrush '#131D33'); $card.BorderBrush = (Get-GuiBrush '#25324D'); $card.BorderThickness = '1'
            $card.Padding = '12,8'; $card.Margin = '0,0,10,10'; $card.MinWidth = 150
            $sp = New-Object System.Windows.Controls.StackPanel
            Add-GuiChild $sp (New-GuiText -Text $k.ToUpper() -Size 10 -Color '#8DA0BF')
            Add-GuiChild $sp (New-GuiText -Text ([string]$m[$k]) -Size 14 -Bold)
            $card.Child = $sp
            Add-GuiChild $g $card
        }
        Add-GuiChild $p $g
        Add-GuiChild $p (New-GuiText -Text 'These are measurements, not a score.' -Size 11 -Color '#6F82A3')
        if (@($s.Games).Count -gt 0) { Add-GuiChild $p (New-GuiText -Text ('Detected games/launchers: ' + ((@($s.Games | ForEach-Object { $_.Name })) -join ', ')) -Size 12 -Color '#8DA0BF' -Margin '0,6,0,0') }
    }
    $top = New-Object System.Windows.Controls.WrapPanel
    $top.Margin = '0,14,0,0'
    Add-GuiChild $top (New-GuiNavButton 'SCAN SYSTEM' { Show-GuiScan } '#1F6FEB')
    Add-GuiChild $top (New-GuiNavButton 'RECOMMENDATIONS' { Show-GuiRecommendations } '#238636')
    Add-GuiChild $top (New-GuiNavButton 'QUICK OPTIMIZE' { Invoke-GuiQuickOptimize })
    Add-GuiChild $p $top
    Add-GuiChild $p (New-GuiText -Text 'PROFILES' -Size 12 -Bold -Color '#7C8CFF' -Margin '0,14,0,0')
    $pr = New-Object System.Windows.Controls.WrapPanel
    foreach ($k in @($Script:Profiles.Keys)) {
        Add-GuiChild $pr (New-GuiButton -Text ($k + ' Profile') -Tag $k -Width 200 -OnClick { param($sd, $e) Show-GuiRecommendations -ProfileName ([string]$sd.Tag) })
    }
    Add-GuiChild $p $pr
    Add-GuiChild $p (New-GuiText -Text 'TWEAKS' -Size 12 -Bold -Color '#7C8CFF' -Margin '0,14,0,0')
    $o = New-Object System.Windows.Controls.WrapPanel
    Add-GuiChild $o (New-GuiNavButton 'DIVOPTIMIZER TWEAKS' { Show-GuiTweaksHub -Tab 'Ours' })
    Add-GuiChild $o (New-GuiNavButton 'YOUTUBER OPTIMIZATIONS (SOON)' { Show-GuiTweaksHub -Tab 'YouTuber' })
    Add-GuiChild $p $o
    Add-GuiChild $p (New-GuiText -Text 'MAINTAIN' -Size 12 -Bold -Color '#7C8CFF' -Margin '0,14,0,0')
    $mt = New-Object System.Windows.Controls.WrapPanel
    Add-GuiChild $mt (New-GuiNavButton 'DIVUNINSTALLER' { Show-GuiUninstaller })
    Add-GuiChild $mt (New-GuiNavButton 'STARTUP' { Show-GuiStartup })
    Add-GuiChild $mt (New-GuiNavButton 'CLEANUP' { Show-GuiCleanup })
    Add-GuiChild $mt (New-GuiNavButton 'NETWORK' { Show-GuiNetwork })
    Add-GuiChild $mt (New-GuiNavButton 'MAINTENANCE' { Show-GuiMaintenance })
    Add-GuiChild $mt (New-GuiNavButton 'RESOURCES' { Show-GuiResources })
    Add-GuiChild $p $mt
    Add-GuiChild $p (New-GuiText -Text 'RECOVER AND MORE' -Size 12 -Bold -Color '#7C8CFF' -Margin '0,14,0,0')
    $rc = New-Object System.Windows.Controls.WrapPanel
    Add-GuiChild $rc (New-GuiNavButton 'BACKUP / RESTORE' { Show-GuiBackups })
    Add-GuiChild $rc (New-GuiNavButton 'HISTORY' { Show-GuiHistory })
    Add-GuiChild $rc (New-GuiNavButton 'ADVANCED TOOLS' { Show-GuiAdvanced })
    Add-GuiChild $rc (New-GuiNavButton 'REPORT / UPDATES / ABOUT' { Show-GuiReportAbout })
    Add-GuiChild $p $rc
    Set-GuiStatus 'Ready. Nothing is changed until you review and approve it.'
}

function Start-GuiApp {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $Script:IsGui = $true
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$Script:GuiXaml)
    $Script:GuiWindow = [Windows.Markup.XamlReader]::Load($reader)
    $Script:GuiContent = $Script:GuiWindow.FindName('Content')
    $Script:GuiStatus = $Script:GuiWindow.FindName('StatusText')
    $Script:GuiSysLine = $Script:GuiWindow.FindName('SysLine')
    $Script:GuiBusyOverlay = $Script:GuiWindow.FindName('BusyOverlay')
    $Script:GuiBusyTitle = $Script:GuiWindow.FindName('BusyTitle')
    $Script:GuiBusyDetail = $Script:GuiWindow.FindName('BusyDetail')
    $Script:GuiBusyBar = $Script:GuiWindow.FindName('BusyBar')
    $Script:GuiWindow.FindName('VersionText').Text = ("v{0}  |  by {1}" -f $Script:Version, $Script:Author)
    $Script:GuiWindow.FindName('HomeBtn').Add_Click({ Show-GuiDashboard })
    $Script:GuiStarted = $false
    # The window appears immediately; the first scan runs behind the loading overlay.
    $Script:GuiWindow.Add_ContentRendered({
        if ($Script:GuiStarted) { return }
        $Script:GuiStarted = $true
        try {
            $scan = Invoke-GuiWithBusy -Title 'Scanning your PC' -Detail 'Reading hardware and settings. This does not change anything.' -Action { Get-SystemScan }
            if (-not $scan.Windows.Supported) {
                Show-GuiMessage ("This PC is not supported: " + $scan.Windows.Status) 'DIVoptimizer' 'Error'
                $Script:GuiWindow.Close()
                return
            }
            $mm = Test-ElevationUserMismatch
            Show-GuiDashboard
            if ($Script:PreselectIds -and @($Script:PreselectIds).Count -gt 0) { Show-GuiRecommendations }
            if ($mm) { Set-GuiStatus $mm }
        } catch {
            Write-Log -Level FAIL -Action 'GUI_STARTUP' -ErrorText $_.Exception.ToString()
            Stop-GuiBusy
            Show-GuiMessage ('The startup scan failed: ' + $_.Exception.Message) 'DIVoptimizer' 'Error'
        }
    })
    [void]$Script:GuiWindow.ShowDialog()
}

# ================================================================
# ENTRY POINT
# ================================================================

function Invoke-DIVoptimizerMain {
    if ($ShowVersion) {
        Write-Host ("{0} v{1}" -f $Script:AppName, $Script:Version)
        return
    }

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Host 'DIVoptimizer needs Windows PowerShell 5.1 or newer.' -ForegroundColor Red
        return
    }

    $Script:PreselectIds = @()
    if ($Preselect) { $Script:PreselectIds = @($Preselect -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $fmt = 'txt'
    if ($Format -and $Format.ToLower() -eq 'json') { $fmt = 'json' }

    if ($CheckUpdate) {
        try {
            $u = Get-UpdateInfo
            Write-Host ("Current : v{0}" -f $u.Current)
            Write-Host ("Latest  : v{0}" -f $u.Latest)
            Write-Host ("Notes   : {0}" -f $u.Notes)
            Write-Host ("Source  : {0}" -f $u.Url)
            Write-Host ("SHA-256 : {0}" -f $u.Sha256)
            if ($u.Newer) { Write-Host 'A newer version exists. (Running via irm | iex always uses the latest published script.) Nothing was downloaded or changed.' -ForegroundColor Yellow }
            else { Write-Host 'You are on the latest version.' -ForegroundColor Green }
        } catch {
            Write-Host ('Could not check for updates: ' + $_.Exception.Message) -ForegroundColor Red
        }
        return
    }

    if ($Health) {
        Show-HealthReport
        return
    }

    if ($Scan) {
        # SCAN-ONLY: reads system state, changes nothing, writes no log or backup.
        $scanResult = Get-SystemScan
        if ($Report) {
            Export-SystemReport -Scan $scanResult -Path $Report -Format $fmt
            Write-Host "Report written to: $Report"
        } else {
            Show-ScanReport -Scan $scanResult
        }
        Write-Host 'SCAN ONLY: no changes were made.' -ForegroundColor Green
        return
    }

    if ($WhatIf) {
        # DRY RUN: shows potential changes, makes none (no registry, service, file, backup or log writes).
        Invoke-DryRunReport
        return
    }

    if ($Report) {
        $scanResult = Get-SystemScan
        Export-SystemReport -Scan $scanResult -Path $Report -Format $fmt
        Write-Host "Report written to: $Report"
        return
    }

    if ($ProfileName -and -not $Script:Profiles.Contains($ProfileName)) {
        Write-Host ("Unknown profile '{0}'. Choose one of: {1}" -f $ProfileName, (@($Script:Profiles.Keys) -join ', ')) -ForegroundColor Red
        return
    }

    # Administrator is required for everything below (it changes system settings, services, tasks and restore points).
    # The read-only modes above (-Scan, -WhatIf, -Report, -CheckUpdate, -ShowVersion) do not need it.
    if (-not (Test-Administrator)) {
        Write-Host ''
        Write-Host '  DIVoptimizer needs Administrator rights.' -ForegroundColor Yellow
        Write-Host '  It backs up and changes system settings, services and scheduled tasks, and creates restore points.' -ForegroundColor DarkGray
        Write-Host '  Windows will now ask for permission (UAC). Nothing is changed until you review and approve it.' -ForegroundColor DarkGray
        $modeArgs = @(Get-RelaunchModeArgs -IsConsole ([bool]$Console) -IsQuick ([bool]$Quick) -ProfileId $ProfileName -IsUndo ([bool]$Undo))
        $ok = Request-Elevation -Why 'DIVoptimizer must run as Administrator' -Ids $Script:PreselectIds -Silent -ModeArgs $modeArgs
        if ($ok) {
            Write-Host '  A new Administrator window was opened. This window can be closed.' -ForegroundColor Green
        } else {
            Write-Host '  Administrator was not granted, so nothing was started.' -ForegroundColor Red
            Write-Host '  For a read-only look without Administrator, run with -Scan or -WhatIf.' -ForegroundColor DarkGray
        }
        return
    }

    Start-LogSession

    if ($Undo) {
        Initialize-Console
        Invoke-UndoLast
        return
    }

    if ($Quick -or $ProfileName) {
        Initialize-Console
        $s = Get-SystemScan
        if (-not $s.Windows.Supported) { Write-Host ("Not supported: {0}" -f $s.Windows.Status) -ForegroundColor Red; return }
        if ($Quick) { Invoke-QuickOptimize } else { Invoke-RecommendationsPage -ProfileName $ProfileName }
        Show-SessionSummary
        return
    }

    if ($Console) {
        Start-ConsoleApp
        Write-Log -Level INFO -Action 'SESSION_END' -Message 'console'
        return
    }

    try {
        Start-GuiApp
        Write-Log -Level INFO -Action 'SESSION_END' -Message 'gui'
    } catch {
        Write-Host ('The GUI could not start: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Log -Level FAIL -Action 'GUI_START' -ErrorText $_.Exception.ToString()
        Write-Host 'Falling back to the console interface...' -ForegroundColor Yellow
        Start-ConsoleApp
    }
}

function Clear-RemoteSessionState {
    # After an irm | iex run, remove every function and variable this script added to the user's session.
    $keepF = @($Script:PreFunctions)
    $keepV = @($Script:PreVariables) + @('LASTEXITCODE', 'Matches', 'Error', 'PSItem', '_', '?', '^', '$')
    $paramNames = @('Console', 'Scan', 'WhatIf', 'Quick', 'ProfileName', 'Report', 'Format', 'CheckUpdate', 'ShowVersion', 'Undo', 'Health', 'Preselect')
    $newFunctions = @(Get-ChildItem -Path Function: | Where-Object { $keepF -notcontains $_.Name } | ForEach-Object { $_.Name })
    $newVariables = @(Get-ChildItem -Path Variable: | Where-Object { $keepV -notcontains $_.Name } | ForEach-Object { $_.Name })
    foreach ($n in ($newVariables + $paramNames)) { Remove-Variable -Name $n -Scope Global -Force -ErrorAction SilentlyContinue }
    foreach ($n in $newFunctions) { Remove-Item -LiteralPath ('Function:\' + $n) -Force -ErrorAction SilentlyContinue }
}

# When this file is dot-sourced (for example by the Pester tests) only the functions are defined.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    Invoke-DIVoptimizerMain
} finally {
    if ($Script:RemoteRun) { Clear-RemoteSessionState }
}
