#Requires -Version 5.1
# ================================================================
# DIVoptimizer-Reset.ps1   (v0.8.0)   EMERGENCY RESTORE
#
# Independent of DIVoptimizer.ps1 and its GUI. It embeds the same
# restore code, finds your backups, verifies them and restores
# registry values, services, scheduled tasks, startup settings,
# the power plan and the hibernation state.
#
# Run:   irm "https://raw.githubusercontent.com/Bulbug/DIVoptimizer/refs/heads/main/DIVoptimizer-Reset.ps1" | iex
#   or:  powershell -ExecutionPolicy Bypass -File .\DIVoptimizer-Reset.ps1
# Best run as Administrator (HKLM settings, services, tasks, power).
# ================================================================
param(
    [switch]$Latest,
    [string]$BackupId = ''
)

$Script:ResetUrl = 'https://raw.githubusercontent.com/Bulbug/DIVoptimizer/refs/heads/main/DIVoptimizer-Reset.ps1'
$Script:AppName       = 'DIVoptimizer Emergency Restore'
$Script:Version       = '0.8.0'
$Script:SchemaVersion = 2
$Script:DryRun        = $false
$Script:ReadOnlyRun   = $false
$Script:LogWarned     = $false
$Script:SessionLogPath = $null
$Script:WinLabel      = ''
$Script:LocalBase = $env:LOCALAPPDATA
if (-not $Script:LocalBase) { $Script:LocalBase = [System.IO.Path]::GetTempPath() }
$Script:BackupsDir       = Join-Path $Script:LocalBase 'DIVoptimizer\Backups'
$Script:LogsDir          = Join-Path $Script:LocalBase 'DIVoptimizer\Logs'
$Script:ProgramDataBase  = $env:ProgramData
if (-not $Script:ProgramDataBase) { $Script:ProgramDataBase = $Script:LocalBase }
$Script:LegacyBackupsDir = Join-Path $Script:ProgramDataBase 'DIVoptimizer\Backups'
$Script:LegacyMessage = @"
This backup was created by DIVoptimizer v0.6.0.

Automatic migration is not available.

Do not attempt restoration because the backup format cannot be verified.
"@

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

function Set-RegistryValueSafe {
    # The ONLY function that writes a registry value. Honors dry-run.
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would set $Path\$Name"; return $true }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Type -Value $Value -Force -ErrorAction Stop | Out-Null
    return $true
}

function Remove-RegistryValueSafe {
    param([string]$Path, [string]$Name)
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would remove $Path\$Name"; return $true }
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
    $out = & sc.exe config $Name start= $Mode 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("sc.exe failed (exit {0}): {1}" -f $LASTEXITCODE, (($out | Out-String).Trim())) }
    return $true
}

function Stop-ServiceSafe {
    param([string]$Name)
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would stop service $Name"; return }
    Stop-Service -Name $Name -Force -ErrorAction Stop
}

function Start-ServiceSafe {
    param([string]$Name)
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would start service $Name"; return }
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
    $out = & powercfg.exe /setactive $Guid 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("powercfg /setactive failed: " + (($out | Out-String).Trim())) }
    $now = Get-ActivePowerPlan
    if (-not $now -or $now.Guid -ne $Guid.ToLower()) { throw 'the power plan did not become active' }
    return $true
}

function Remove-PowerPlanSafe {
    param([string]$Guid)
    if ($Script:DryRun) { Write-Tag INFO "[DRY RUN] would delete power plan $Guid"; return }
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
# EMERGENCY RESTORE MENU
# ---------------------------------------------------------------

function Show-ResetBackups {
    param([object[]]$List)
    $i = 0
    foreach ($b in $List) {
        $i++
        $fmt = switch ($b.Format) { 'v2' { 'v0.7' } 'legacy' { 'legacy v0.6' } default { $b.Format } }
        Write-Host ('  [{0}] {1,-19} {2,-12} {3}   {4}' -f $i, $b.Id, $fmt, $b.Created, $b.Description)
    }
}

function Select-ResetBackup {
    param([object[]]$List, [string]$PreferId = '')
    if ($PreferId) { $m = @($List | Where-Object { $_.Id -eq $PreferId }); if ($m.Count -gt 0) { return $m[0] } }
    return $null
}

function Invoke-ResetRestore {
    param($Backup, [string[]]$Types, [string]$Label)
    Write-Host ''
    Write-Host ("  Backup  : {0}" -f $Backup.Id)
    Write-Host ("  Created : {0}" -f $Backup.Created)
    Write-Host ("  Contents: {0}" -f $Label)
    $chk = Test-BackupDir -Dir $Backup.Path
    if ($chk.Format -eq 'v2' -and -not $chk.Ok) {
        Write-Host '  This backup FAILED verification and will not be restored:' -ForegroundColor Red
        foreach ($p in $chk.Problems) { Write-Host ('    ' + $p) -ForegroundColor Red }
        return
    }
    if ($chk.Format -eq 'legacy') { Write-Host $Script:LegacyMessage -ForegroundColor Yellow }
    if ($chk.Format -eq 'unknown') { Write-Host ('  ' + (@($chk.Problems) -join ' ')) -ForegroundColor Red; return }
    $a = Read-Host '  Restore now? [y/N]'
    if ($a -notmatch '^(y|yes)$') { Write-Host '  Cancelled. Nothing was changed.'; return }
    $r = Restore-Backup -Dir $Backup.Path -Types $Types
    Write-Host ''
    if ($r.Refused) { Write-Host $r.Message -ForegroundColor Yellow; return }
    Write-Host ("  Restored: {0}   Failed: {1}   Skipped: {2}" -f $r.Success, $r.Failed, $r.Skipped) -ForegroundColor $(if ($r.Failed -gt 0) { 'Yellow' } else { 'Green' })
    if ($r.Failed -gt 0) { Write-Host '  Some items failed. Run as Administrator and try again; see the log in:' -ForegroundColor Yellow; Write-Host ('  ' + $Script:LogsDir) }
    Write-Host '  Restart or sign out for all restored settings to take effect.'
}

try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $Script:WinLabel = ('{0} build {1}' -f $os.Caption, $os.BuildNumber) } catch { $Script:WinLabel = 'Windows' }
Start-LogSession -Prefix 'reset'

if (-not (Test-Administrator)) {
    Write-Host ''
    Write-Host '  Not running as Administrator. HKCU settings and startup entries can be restored;' -ForegroundColor Yellow
    Write-Host '  HKLM settings, services, scheduled tasks, power plan and hibernation need Administrator.' -ForegroundColor Yellow
    $a = Read-Host '  Relaunch as Administrator now? [Y/n]'
    if ($a -notmatch '^(n|no)$') {
        try {
            $hostExe = (Get-Process -Id $PID).Path
            if ($PSCommandPath) {
                $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
            } else {
                $u = [uri]$Script:ResetUrl
                if ($u.Scheme -ne 'https' -or @('raw.githubusercontent.com', 'github.com') -notcontains $u.Host) { throw 'The reset script URL is not an allowed HTTPS GitHub address.' }
                $inner = "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((Invoke-RestMethod -Uri '$($Script:ResetUrl)' -UseBasicParsing)))"
                $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ('"' + $inner + '"'))
            }
            Start-Process -FilePath $hostExe -ArgumentList $relaunch -Verb RunAs -ErrorAction Stop
            return
        } catch { Write-Host ('  Elevation cancelled or failed: ' + $_.Exception.Message) -ForegroundColor Red }
    }
}

$all = @(Get-BackupList)
if ($all.Count -eq 0) {
    Write-Host ''
    Write-Host '  No backups were found in:' -ForegroundColor Yellow
    Write-Host ('    ' + $Script:BackupsDir)
    Write-Host ('    ' + $Script:LegacyBackupsDir)
    Write-Host '  Windows System Restore points (if any) are an alternative: run rstrui.exe.'
    return
}

$current = $null
if ($BackupId) { $current = Select-ResetBackup -List $all -PreferId $BackupId }
if (-not $current) { $current = $all[0] }

if ($Latest) {
    Invoke-ResetRestore -Backup $current -Types @('Registry', 'Services', 'Tasks', 'Startup', 'PowerPlan', 'Hibernation') -Label 'everything'
    return
}

while ($true) {
    Write-Host ''
    Write-Host '  DIVoptimizer Emergency Restore' -ForegroundColor Cyan
    Write-Host ('  Selected backup: {0}  ({1})' -f $current.Id, $current.Created) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [1] Restore latest backup (everything)'
    Write-Host '  [2] Restore registry'
    Write-Host '  [3] Restore services'
    Write-Host '  [4] Restore scheduled tasks'
    Write-Host '  [5] Restore startup settings'
    Write-Host '  [6] Restore power plan'
    Write-Host '  [7] Restore hibernation'
    Write-Host '  [8] Exit'
    Write-Host '  [L] List backups / choose a different backup'
    $c = (Read-Host '  Choice').Trim()
    switch -Regex ($c) {
        '^1$' { Invoke-ResetRestore -Backup $all[0] -Types @('Registry', 'Services', 'Tasks', 'Startup', 'PowerPlan', 'Hibernation') -Label 'everything (newest backup)' }
        '^2$' { Invoke-ResetRestore -Backup $current -Types @('Registry') -Label 'registry values only' }
        '^3$' { Invoke-ResetRestore -Backup $current -Types @('Services') -Label 'services only' }
        '^4$' { Invoke-ResetRestore -Backup $current -Types @('Tasks') -Label 'scheduled tasks only' }
        '^5$' { Invoke-ResetRestore -Backup $current -Types @('Startup') -Label 'startup settings only' }
        '^6$' { Invoke-ResetRestore -Backup $current -Types @('PowerPlan') -Label 'power plan only' }
        '^7$' { Invoke-ResetRestore -Backup $current -Types @('Hibernation') -Label 'hibernation only' }
        '^8$' { return }
        '^[Ll]$' {
            Show-ResetBackups -List $all
            $n = (Read-Host '  Select number (Enter keeps current)').Trim()
            if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $all.Count) { $current = $all[[int]$n - 1] }
        }
        default { Write-Host '  Invalid choice.' -ForegroundColor Yellow }
    }
}
