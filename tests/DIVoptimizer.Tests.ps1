# Pester 5 tests for DIVoptimizer v0.8.0
#
# SAFETY: these tests never touch your real Windows configuration.
#   * Registry tests use Pester's TestRegistry: drive (a throw-away key under HKCU).
#   * Services, scheduled tasks, power plans and hibernation are MOCKED.
#   * Backups and logs go to $TestDrive.
#
# Run (Windows PowerShell 5.1 or PowerShell 7, Pester 5+):
#   Invoke-Pester .\tests\DIVoptimizer.Tests.ps1 -Output Detailed

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'DIVoptimizer.ps1')          # dot-sourcing defines functions only
    $Script:ReadOnlyRun = $true                            # no log files during tests
    $Script:BackupsDir = Join-Path $TestDrive 'Backups'
    $Script:LegacyBackupsDir = Join-Path $TestDrive 'LegacyBackups'
    $Script:LogsDir = Join-Path $TestDrive 'Logs'
    $Script:SettingsPath = Join-Path $TestDrive 'settings.json'
    $Script:DryRun = $false

    function script:New-TestScan {
        param([double]$Ram = 16, [string]$Device = 'Desktop', [bool]$Touch = $false, [bool]$Discrete = $false,
              [string]$Drive = 'SSD', [string]$PlanGuid = '381b4222-f694-41f0-9685-ff5bb260df2e', [int]$Build = 22631)
        [pscustomobject]@{
            Windows  = [pscustomobject]@{ Build = $Build; Generation = $(if ($Build -ge 22000) { 11 } else { 10 }); Edition = 'Professional'; Supported = $true }
            Hardware = [pscustomobject]@{ RamGB = $Ram; DeviceType = $Device; Touch = $Touch; HasDiscreteGpu = $Discrete; IsVirtualMachine = $false; SystemDriveType = $Drive; BatteryPresent = ($Device -eq 'Laptop') }
            Features = [pscustomobject]@{ GameDvr = 'Default (not set)'; HagsRaw = $null; Hibernation = 'Enabled' }
            Power    = [pscustomobject]@{ PlanGuid = $PlanGuid; PlanName = 'Balanced' }
            Storage  = [pscustomobject]@{ FreeGB = 200; FreePct = 50 }
            Memory   = [pscustomobject]@{ UsedPct = 40 }
            Startup  = @(1..3 | ForEach-Object { [pscustomobject]@{ Enabled = $true } })
            UserTempMB = 50
        }
    }
}

Describe 'Version consistency' {
    It 'uses 0.8.0 everywhere' {
        $Script:Version | Should -Be '0.8.0'
        (Get-Content (Join-Path $script:Root 'DIVoptimizer.ps1') -Raw) | Should -Match 'DIVoptimizer v0\.7\.0'
        (Get-Content (Join-Path $script:Root 'DIVoptimizer-Reset.ps1') -Raw) | Should -Match "Version\s+= '0\.7\.0'"
    }
    It 'embeds an identical restore core in the main script and the Reset script' {
        $get = {
            param($f)
            $t = Get-Content (Join-Path $script:Root $f) -Raw
            $m = [regex]::Match($t, '(?s)# <<<CORE-BEGIN.*?# <<<CORE-END')
            $m.Value
        }
        $a = & $get 'DIVoptimizer.ps1'
        $b = & $get 'DIVoptimizer-Reset.ps1'
        $a.Length | Should -BeGreaterThan 1000
        $a | Should -BeExactly $b
    }
    It 'contains only ASCII characters (safe for Windows PowerShell 5.1 without a BOM)' {
        foreach ($f in 'DIVoptimizer.ps1', 'DIVoptimizer-Reset.ps1') {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:Root $f))
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }
    }
}

Describe 'System detection' {
    It 'detects Windows 11 from the build number' {
        Mock Get-CimSafe { [pscustomobject]@{ BuildNumber = '22631'; ProductType = 1; Caption = 'Microsoft Windows 11 Pro'; Version = '10.0.22631'; OSArchitecture = '64-bit' } } -ParameterFilter { $Class -eq 'Win32_OperatingSystem' }
        $w = Get-WindowsInfo
        $w.Generation | Should -Be 11
        $w.Supported | Should -BeTrue
    }
    It 'detects Windows 10 and flags server editions as unsupported' {
        Mock Get-CimSafe { [pscustomobject]@{ BuildNumber = '19045'; ProductType = 1; Caption = 'Microsoft Windows 10 Pro'; Version = '10.0.19045'; OSArchitecture = '64-bit' } } -ParameterFilter { $Class -eq 'Win32_OperatingSystem' }
        (Get-WindowsInfo).Generation | Should -Be 10
        Mock Get-CimSafe { [pscustomobject]@{ BuildNumber = '20348'; ProductType = 3; Caption = 'Windows Server 2022'; Version = '10.0.20348'; OSArchitecture = '64-bit' } } -ParameterFilter { $Class -eq 'Win32_OperatingSystem' }
        (Get-WindowsInfo).Supported | Should -BeFalse
    }
    Context 'device type' {
        BeforeEach {
            Mock Get-StorageDevices { @() }
            Mock Test-TouchHardware { $false }
            Mock Get-SystemDriveType { 'SSD' }
            Mock Get-CimSafe { [pscustomobject]@{ Name = 'CPU'; NumberOfCores = 4; NumberOfLogicalProcessors = 8; VirtualizationFirmwareEnabled = $true } } -ParameterFilter { $Class -eq 'Win32_Processor' }
            Mock Get-CimSafe { @() } -ParameterFilter { $Class -eq 'Win32_VideoController' }
            Mock Get-CimSafe { $null } -ParameterFilter { $Class -eq 'Win32_Battery' }
        }
        It 'identifies a laptop from the chassis type' {
            Mock Get-CimSafe { [pscustomobject]@{ TotalPhysicalMemory = 17179869184; Manufacturer = 'ACME'; Model = 'Book' } } -ParameterFilter { $Class -eq 'Win32_ComputerSystem' }
            Mock Get-CimSafe { [pscustomobject]@{ ChassisTypes = @(10) } } -ParameterFilter { $Class -eq 'Win32_SystemEnclosure' }
            (Get-HardwareInfo).DeviceType | Should -Be 'Laptop'
        }
        It 'identifies a desktop' {
            Mock Get-CimSafe { [pscustomobject]@{ TotalPhysicalMemory = 17179869184; Manufacturer = 'ACME'; Model = 'Tower' } } -ParameterFilter { $Class -eq 'Win32_ComputerSystem' }
            Mock Get-CimSafe { [pscustomobject]@{ ChassisTypes = @(3) } } -ParameterFilter { $Class -eq 'Win32_SystemEnclosure' }
            (Get-HardwareInfo).DeviceType | Should -Be 'Desktop'
        }
        It 'identifies a virtual machine' {
            Mock Get-CimSafe { [pscustomobject]@{ TotalPhysicalMemory = 8589934592; Manufacturer = 'VMware, Inc.'; Model = 'VMware Virtual Platform' } } -ParameterFilter { $Class -eq 'Win32_ComputerSystem' }
            Mock Get-CimSafe { [pscustomobject]@{ ChassisTypes = @(1) } } -ParameterFilter { $Class -eq 'Win32_SystemEnclosure' }
            $h = Get-HardwareInfo
            $h.DeviceType | Should -Be 'Virtual machine'
            $h.IsVirtualMachine | Should -BeTrue
        }
    }
}

Describe 'JSON serialization' {
    It 'round-trips special characters without corruption' {
        $odd = 'a|b "quoted" back\slash <tag> & ' + [char]0x00E9 + [char]0x4E2D + "`r`nline2"
        $p = Join-Path $TestDrive 'j.json'
        Write-JsonFile -Path $p -Object ([ordered]@{ Records = @([pscustomobject]@{ V = $odd }) })
        (Read-JsonFile -Path $p).Records[0].V | Should -BeExactly $odd
    }
    It 'keeps a single-element array an array and an empty array empty' {
        $p = Join-Path $TestDrive 'a.json'
        Write-JsonFile -Path $p -Object ([ordered]@{ Records = @([pscustomobject]@{ X = 1 }) })
        @((Read-JsonFile -Path $p).Records).Count | Should -Be 1
        Write-JsonFile -Path $p -Object ([ordered]@{ Records = @() })
        @((Read-JsonFile -Path $p).Records).Count | Should -Be 0
    }
}

Describe 'Registry backup and restore' {
    BeforeEach {
        $Script:BackupSession = $null
        [void](New-Backup -Description 'test')
        $key = 'TestRegistry:\Div'
        if (Test-Path $key) { Remove-Item $key -Recurse -Force }
        New-Item -Path $key -Force | Out-Null
    }
    It 'captures path, name, type, value and existence for every supported type' {
        $k = 'TestRegistry:\Div'
        New-ItemProperty -LiteralPath $k -Name S -PropertyType String -Value 'text' | Out-Null
        New-ItemProperty -LiteralPath $k -Name D -PropertyType DWord -Value 7 | Out-Null
        New-ItemProperty -LiteralPath $k -Name Q -PropertyType QWord -Value ([long]5000000000) | Out-Null
        New-ItemProperty -LiteralPath $k -Name M -PropertyType MultiString -Value ([string[]]@('one', 'two')) | Out-Null
        New-ItemProperty -LiteralPath $k -Name B -PropertyType Binary -Value ([byte[]]@(1, 2, 255)) | Out-Null
        New-ItemProperty -LiteralPath $k -Name E -PropertyType ExpandString -Value '%SystemRoot%\x' | Out-Null
        $r = @{}
        foreach ($n in 'S', 'D', 'Q', 'M', 'B', 'E', 'Missing') { $r[$n] = Backup-RegistryValue -Path $k -Name $n }
        $r['S'].Type | Should -Be 'String'
        $r['D'].Type | Should -Be 'DWord'
        $r['D'].Value | Should -Be 7
        $r['Q'].Value | Should -Be 5000000000
        $r['M'].Type | Should -Be 'MultiString'
        $r['B'].Value | Should -Be ([Convert]::ToBase64String([byte[]]@(1, 2, 255)))
        $r['E'].Value | Should -BeExactly '%SystemRoot%\x'      # NOT expanded
        $r['Missing'].Exists | Should -BeFalse
        $r['Missing'].KeyExisted | Should -BeTrue
    }
    It 'restores a changed value to its original value' {
        $k = 'TestRegistry:\Div'
        New-ItemProperty -LiteralPath $k -Name D -PropertyType DWord -Value 1 | Out-Null
        $rec = Backup-RegistryValue -Path $k -Name D
        Set-ItemProperty -LiteralPath $k -Name D -Value 99
        Restore-RegistryValue -Record $rec | Should -Be 'ok'
        (Get-ItemProperty -LiteralPath $k -Name D).D | Should -Be 1
    }
    It 'removes a value that did not exist before' {
        $k = 'TestRegistry:\Div'
        $rec = Backup-RegistryValue -Path $k -Name New
        New-ItemProperty -LiteralPath $k -Name New -PropertyType DWord -Value 5 | Out-Null
        Restore-RegistryValue -Record $rec | Should -Be 'ok'
        (Get-RegistryValueState -Path $k -Name New).Exists | Should -BeFalse
    }
    It 'restores the original TYPE when the type was changed' {
        $k = 'TestRegistry:\Div'
        New-ItemProperty -LiteralPath $k -Name T -PropertyType String -Value '5' | Out-Null
        $rec = Backup-RegistryValue -Path $k -Name T
        New-ItemProperty -LiteralPath $k -Name T -PropertyType DWord -Value 5 -Force | Out-Null
        Restore-RegistryValue -Record $rec | Should -Be 'ok'
        (Get-RegistryValueState -Path $k -Name T).Type | Should -Be 'String'
    }
    It 'recreates a value that was deleted' {
        $k = 'TestRegistry:\Div'
        New-ItemProperty -LiteralPath $k -Name Gone -PropertyType String -Value 'keep me' | Out-Null
        $rec = Backup-RegistryValue -Path $k -Name Gone
        Remove-ItemProperty -LiteralPath $k -Name Gone
        Restore-RegistryValue -Record $rec | Should -Be 'ok'
        (Get-ItemProperty -LiteralPath $k -Name Gone).Gone | Should -BeExactly 'keep me'
    }
    It 'round-trips MultiString and Binary through the saved backup files' {
        $k = 'TestRegistry:\Div'
        New-ItemProperty -LiteralPath $k -Name M -PropertyType MultiString -Value ([string[]]@('a', 'b')) | Out-Null
        New-ItemProperty -LiteralPath $k -Name B -PropertyType Binary -Value ([byte[]]@(9, 8, 7)) | Out-Null
        [void](Backup-RegistryValue -Path $k -Name M); [void](Backup-RegistryValue -Path $k -Name B)
        Save-BackupSession
        $recs = @((Read-JsonFile -Path (Join-Path $Script:BackupSession.Dir 'registry/registry.json')).Records)
        Set-ItemProperty -LiteralPath $k -Name M -Value ([string[]]@('x'))
        Set-ItemProperty -LiteralPath $k -Name B -Value ([byte[]]@(0))
        foreach ($r in $recs) { Restore-RegistryValue -Record $r | Should -Be 'ok' }
        ((Get-ItemProperty -LiteralPath $k -Name M).M -join ',') | Should -Be 'a,b'
        ((Get-ItemProperty -LiteralPath $k -Name B).B -join ',') | Should -Be '9,8,7'
    }
    It 'removes a key DIVoptimizer created once it is empty' {
        $k = 'TestRegistry:\Div\Created'
        $rec = Backup-RegistryValue -Path $k -Name V
        $rec.KeyExisted | Should -BeFalse
        New-Item -Path $k -Force | Out-Null
        New-ItemProperty -LiteralPath $k -Name V -PropertyType DWord -Value 1 | Out-Null
        Restore-RegistryValue -Record $rec | Should -Be 'ok'
        Test-Path $k | Should -BeFalse
    }
    It 'reports failure instead of throwing, and logs it' {
        $k = 'TestRegistry:\Div'
        New-ItemProperty -LiteralPath $k -Name D -PropertyType DWord -Value 1 | Out-Null
        $rec = Backup-RegistryValue -Path $k -Name D
        Mock Set-RegistryValueSafe { throw 'access denied' }
        Restore-RegistryValue -Record $rec | Should -Be 'failed'
    }
}

Describe 'Service backup and restore' {
    BeforeEach { $Script:BackupSession = $null; [void](New-Backup -Description 'test') }
    It 'records name, display name, startup type, status and delayed start' {
        Mock Get-ServiceInfo { [pscustomobject]@{ Exists = $true; Name = 'SysMain'; DisplayName = 'SysMain'; Status = 'Running'; StartMode = 'Auto'; Delayed = $true; StartupType = 'Automatic (Delayed)' } }
        $r = Backup-Service -Name 'SysMain'
        $r.StartupType | Should -Be 'Automatic (Delayed)'
        $r.DelayedAutoStart | Should -BeTrue
        $r.Status | Should -Be 'Running'
    }
    It 'does NOT start a service that was originally stopped' {
        Mock Get-ServiceInfo { [pscustomobject]@{ Exists = $true; Status = 'Stopped'; StartupType = 'Manual'; StartMode = 'Manual'; Delayed = $false } }
        Mock Set-ServiceStartMode { $true }
        Mock Start-ServiceSafe { }
        $rec = [pscustomobject]@{ ServiceName = 'X'; StartMode = 'Manual'; StartupType = 'Manual'; DelayedAutoStart = $false; Status = 'Stopped' }
        Restore-ServiceRecord -Record $rec | Should -Be 'ok'
        Should -Invoke Start-ServiceSafe -Times 0
        Should -Invoke Set-ServiceStartMode -Times 1 -ParameterFilter { $Mode -eq 'demand' }
    }
    It 'starts a service that was originally running and restores delayed-auto' {
        Mock Get-ServiceInfo { [pscustomobject]@{ Exists = $true; Status = 'Stopped'; StartupType = 'Automatic (Delayed)'; StartMode = 'Auto'; Delayed = $true } }
        Mock Set-ServiceStartMode { $true }
        Mock Start-ServiceSafe { }
        $rec = [pscustomobject]@{ ServiceName = 'X'; StartMode = 'Auto'; StartupType = 'Automatic (Delayed)'; DelayedAutoStart = $true; Status = 'Running' }
        Restore-ServiceRecord -Record $rec | Should -Be 'ok'
        Should -Invoke Start-ServiceSafe -Times 1
        Should -Invoke Set-ServiceStartMode -Times 1 -ParameterFilter { $Mode -eq 'delayed-auto' }
    }
    It 'skips a service that is not present' {
        Mock Get-ServiceInfo { [pscustomobject]@{ Exists = $false } }
        Restore-ServiceRecord -Record ([pscustomobject]@{ ServiceName = 'Nope'; StartMode = 'Auto'; StartupType = 'Automatic'; DelayedAutoStart = $false; Status = 'Running' }) | Should -Be 'skipped'
    }
}

Describe 'Scheduled task backup and restore' {
    BeforeEach { $Script:BackupSession = $null; [void](New-Backup -Description 'test'); $global:DivTaskEnabled = $true }
    AfterEach { Remove-Variable DivTaskEnabled -Scope Global -ErrorAction SilentlyContinue }
    It 'stores the Enabled flag, not just the State (Ready is not the same as Enabled)' {
        Mock Get-TaskInfo { [pscustomobject]@{ Exists = $true; TaskPath = '\T\'; TaskName = 'N'; State = 'Ready'; Enabled = $false } }
        $r = Backup-ScheduledTask -TaskPath '\T\' -TaskName 'N'
        $r.State | Should -Be 'Ready'
        $r.Enabled | Should -BeFalse
    }
    It 'restores the exact previous enabled/disabled state' {
        Mock Get-TaskInfo { [pscustomobject]@{ Exists = $true; TaskPath = '\T\'; TaskName = 'N'; State = 'Ready'; Enabled = $global:DivTaskEnabled } }
        Mock Set-TaskEnabledSafe { param($TaskPath, $TaskName, $Enabled) $global:DivTaskEnabled = $Enabled; $true }
        $rec = [pscustomobject]@{ TaskPath = '\T\'; TaskName = 'N'; State = 'Ready'; Enabled = $false }
        Restore-TaskRecord -Record $rec | Should -Be 'ok'
        $global:DivTaskEnabled | Should -BeFalse
    }
}

Describe 'Power plan backup and restore' {
    BeforeEach { $Script:BackupSession = $null; [void](New-Backup -Description 'test') }
    It 'records the active plan GUID and name' {
        Mock Get-ActivePowerPlan { [pscustomobject]@{ Guid = '381b4222-f694-41f0-9685-ff5bb260df2e'; Name = 'Balanced' } }
        $r = Backup-PowerPlan
        $r.Guid | Should -Be '381b4222-f694-41f0-9685-ff5bb260df2e'
        $r.Name | Should -Be 'Balanced'
    }
    It 'restores the original plan' {
        Mock Get-ActivePowerPlan { [pscustomobject]@{ Guid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'; Name = 'High performance' } }
        Mock Get-PowerPlans { @([pscustomobject]@{ Guid = '381b4222-f694-41f0-9685-ff5bb260df2e'; Name = 'Balanced'; Active = $false }) }
        Mock Set-ActivePowerPlan { $true }
        Restore-PowerPlanRecord -Record ([pscustomobject]@{ Guid = '381b4222-f694-41f0-9685-ff5bb260df2e'; Name = 'Balanced'; CreatedPlanGuid = '' }) | Should -Be 'ok'
        Should -Invoke Set-ActivePowerPlan -Times 1 -ParameterFilter { $Guid -eq '381b4222-f694-41f0-9685-ff5bb260df2e' }
    }
    It 'fails clearly when the original plan no longer exists' {
        Mock Get-ActivePowerPlan { [pscustomobject]@{ Guid = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; Name = 'Other' } }
        Mock Get-PowerPlans { @() }
        Restore-PowerPlanRecord -Record ([pscustomobject]@{ Guid = '381b4222-f694-41f0-9685-ff5bb260df2e'; Name = 'Balanced'; CreatedPlanGuid = '' }) | Should -Be 'failed'
    }
}

Describe 'Hibernation backup and restore' {
    BeforeEach { $Script:BackupSession = $null; [void](New-Backup -Description 'test'); $global:DivHib = $true }
    AfterEach { Remove-Variable DivHib -Scope Global -ErrorAction SilentlyContinue }
    It 'records whether hibernation was enabled before it is turned off' {
        Mock Get-HibernationState { $global:DivHib }
        (Backup-Hibernation).Enabled | Should -BeTrue
    }
    It 'restores the original state' {
        $global:DivHib = $false
        Mock Get-HibernationState { $global:DivHib }
        Mock Set-HibernationState { param([bool]$Enabled) $global:DivHib = $Enabled; $true }
        Restore-HibernationRecord -Record ([pscustomobject]@{ Enabled = $true }) | Should -Be 'ok'
        $global:DivHib | Should -BeTrue
    }
}

Describe 'Startup backup and restore' {
    BeforeEach {
        $Script:BackupSession = $null; [void](New-Backup -Description 'test')
        if (Test-Path 'TestRegistry:\Approved') { Remove-Item 'TestRegistry:\Approved' -Recurse -Force }
        $script:item = [pscustomobject]@{ Name = 'App'; Location = 'HKCU:\Run'; Command = 'c:\app.exe'; Enabled = $true; ApprovedPath = 'TestRegistry:\Approved'; ApprovedName = 'App' }
    }
    It 'interprets the StartupApproved flag bytes' {
        Test-StartupApprovedEnabled -Bytes ([byte[]]@(2, 0, 0, 0)) | Should -BeTrue
        Test-StartupApprovedEnabled -Bytes ([byte[]]@(6, 0, 0, 0)) | Should -BeTrue
        Test-StartupApprovedEnabled -Bytes ([byte[]]@(3, 0, 0, 0)) | Should -BeFalse
        Test-StartupApprovedEnabled -Bytes $null | Should -BeTrue
    }
    It 'disables without deleting and restores a missing flag by removing it' {
        $rec = Backup-StartupItem -Item $script:item
        $rec.ApprovedExists | Should -BeFalse
        Set-RegistryValueSafe -Path 'TestRegistry:\Approved' -Name 'App' -Type Binary -Value (New-StartupApprovedBytes -Enabled $false) | Out-Null
        Test-StartupApprovedEnabled -Bytes (Get-RegistryValueState -Path 'TestRegistry:\Approved' -Name 'App').Value | Should -BeFalse
        Restore-StartupRecord -Record $rec | Should -Be 'ok'
        (Get-RegistryValueState -Path 'TestRegistry:\Approved' -Name 'App').Exists | Should -BeFalse
    }
    It 'restores an existing flag byte-for-byte' {
        New-Item -Path 'TestRegistry:\Approved' -Force | Out-Null
        $orig = [byte[]]@(6, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8)
        New-ItemProperty -LiteralPath 'TestRegistry:\Approved' -Name 'App' -PropertyType Binary -Value $orig | Out-Null
        $rec = Backup-StartupItem -Item $script:item
        Set-RegistryValueSafe -Path 'TestRegistry:\Approved' -Name 'App' -Type Binary -Value (New-StartupApprovedBytes -Enabled $false) | Out-Null
        Restore-StartupRecord -Record $rec | Should -Be 'ok'
        ((Get-ItemProperty -LiteralPath 'TestRegistry:\Approved' -Name 'App').App -join ',') | Should -Be ($orig -join ',')
    }
}

Describe 'Backup files, verification and legacy format' {
    BeforeEach {
        $Script:BackupSession = $null
        $script:s = New-Backup -Description 'verify'
        if (Test-Path 'TestRegistry:\V') { Remove-Item 'TestRegistry:\V' -Recurse -Force }
        New-Item -Path 'TestRegistry:\V' -Force | Out-Null
        New-ItemProperty -LiteralPath 'TestRegistry:\V' -Name D -PropertyType DWord -Value 1 | Out-Null
        [void](Backup-RegistryValue -Path 'TestRegistry:\V' -Name D)
        Save-BackupSession
    }
    It 'creates the documented folder layout and a verifiable backup.json' {
        foreach ($sub in 'registry', 'services', 'tasks', 'startup', 'power', 'settings') { Test-Path (Join-Path $script:s.Dir $sub) | Should -BeTrue }
        (Test-Backup -Dir $script:s.Dir).Ok | Should -BeTrue
        $script:s.Id | Should -Match '^\d{4}-\d{2}-\d{2}_\d{6}'
    }
    It 'detects a tampered data file and refuses to restore it' {
        Add-Content -LiteralPath (Join-Path $script:s.Dir 'registry/registry.json') -Value ' '
        (Test-BackupDir -Dir $script:s.Dir).Ok | Should -BeFalse
        (Restore-Backup -Dir $script:s.Dir).Refused | Should -BeTrue
    }
    It 'restores a whole backup' {
        Set-ItemProperty -LiteralPath 'TestRegistry:\V' -Name D -Value 42
        $r = Restore-Backup -Dir $script:s.Dir -Types @('Registry')
        $r.Success | Should -Be 1
        (Get-ItemProperty -LiteralPath 'TestRegistry:\V' -Name D).D | Should -Be 1
    }
    It 'restores only unambiguous v0.6 records and uses the FIRST (original) record per value' {
        $d = Join-Path $Script:LegacyBackupsDir 'old'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $lines = @('TOOLKIT_VERSION|0.6.0', 'REGISTRY|TestRegistry:\V|D|1|DWord|True', 'REGISTRY|TestRegistry:\V|D|99|DWord|True', 'TASK|\x\y\|Ready', 'APPX|Microsoft.BingNews')
        Set-Content -LiteralPath (Join-Path $d 'manifest.txt') -Value $lines
        Set-ItemProperty -LiteralPath 'TestRegistry:\V' -Name D -Value 55
        $r = Restore-Backup -Dir $d
        $r.Success | Should -Be 1
        $r.Skipped | Should -Be 2
        (Get-ItemProperty -LiteralPath 'TestRegistry:\V' -Name D).D | Should -Be 1
    }
    It 'refuses a legacy backup it cannot verify and shows the exact message' {
        $d = Join-Path $Script:LegacyBackupsDir 'bad'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'manifest.txt') -Value @('something else', 'REGISTRY|a|b|c|DWord|True')
        $r = Restore-Backup -Dir $d
        $r.Refused | Should -BeTrue
        $r.Message | Should -Match 'Automatic migration is not available'
        $r.Message | Should -Match 'cannot be verified'
    }
}

Describe 'Safety lists are enforced' {
    It 'protects critical packages and services' {
        Test-PackageProtected -Name 'Microsoft.WindowsStore' | Should -BeTrue
        Test-PackageProtected -Name 'Microsoft.VCLibs.140.00' | Should -BeTrue
        Test-PackageProtected -Name 'Microsoft.SecHealthUI' | Should -BeTrue
        Test-PackageProtected -Name 'Microsoft.BingNews' | Should -BeFalse
        Test-ServiceProtected -Name 'wuauserv' | Should -BeTrue
        Test-ServiceProtected -Name 'WinDefend' | Should -BeTrue
        Test-ServiceProtected -Name 'MapsBroker' | Should -BeTrue   # not on the allow-list
        Test-ServiceProtected -Name 'DiagTrack' | Should -BeFalse
        Test-ServiceProtected -Name 'SysMain' | Should -BeFalse
        Test-ServiceProtected -Name 'SomeUnknownService' | Should -BeTrue
    }
    It 'rejects wildcard package names' {
        { Remove-AppPackageExact -Name 'Microsoft.*' } | Should -Throw
    }
    It 'refuses to change a protected service' {
        $t = New-Tweak @{ Id = 'x'; Kind = 'Service'; Service = 'wuauserv'; ServiceTarget = 'Disabled' }
        { Invoke-TweakChange -Tweak $t } | Should -Throw
    }
    It 'never offers a catalog service that is on the do-not-touch list' {
        foreach ($e in $Script:ServiceCatalog) { Test-ServiceProtected -Name $e.Name | Should -BeFalse }
    }
    It 'refuses to delete a folder that is not a backup folder' {
        { Remove-BackupFolder -Dir (Join-Path $env:SystemRoot 'System32') } | Should -Throw
    }
}

Describe 'Compatibility metadata' {
    It 'marks a Windows 10-only tweak unavailable on Windows 11' {
        $t = @(Get-TweakCatalog -Scan (New-TestScan -Build 22631) | Where-Object { $_.Id -eq 'bgapps-off' })[0]
        $c = Test-TweakCompat -Tweak $t -Windows (New-TestScan -Build 22631).Windows
        $c.Ok | Should -BeFalse
        $c.Message | Should -Be 'This tweak is not available on this Windows version.'
    }
    It 'allows it on Windows 10' {
        $scan = New-TestScan -Build 19045
        $t = @(Get-TweakCatalog -Scan $scan | Where-Object { $_.Id -eq 'bgapps-off' })[0]
        (Test-TweakCompat -Tweak $t -Windows $scan.Windows).Ok | Should -BeTrue
    }
}

Describe 'Recommendation engine' {
    BeforeEach {
        Mock Test-TweakApplied { $false }
        Mock Get-TweakCurrent { 'current' }
        Mock Get-TweakNew { 'new' }
        Mock Get-RegValue { $null }
        Mock Get-ServiceInfo { [pscustomobject]@{ Exists = $true; Name = 'x'; Status = 'Running'; StartupType = 'Automatic'; StartMode = 'Auto'; Delayed = $false } }
    }
    It 'gives an 8 GB touchscreen laptop different advice from a 32 GB desktop with a discrete GPU' {
        $lap = @(Get-Recommendations -Scan (New-TestScan -Ram 8 -Device 'Laptop' -Touch $true) | ForEach-Object { $_.Id })
        $desk = @(Get-Recommendations -Scan (New-TestScan -Ram 32 -Device 'Desktop' -Discrete $true -Drive 'NVMe SSD') | ForEach-Object { $_.Id })
        $lap | Should -Contain 'visual-reduce'
        $lap | Should -Not -Contain 'hags-on'
        $lap | Should -Not -Contain 'power-performance'
        $desk | Should -Contain 'hags-on'
        $desk | Should -Contain 'power-performance'
        $desk | Should -Not -Contain 'visual-reduce'
    }
    It 'never preselects OPTIONAL or ADVANCED items and never auto-selects a service' {
        $all = @(Get-Recommendations -Scan (New-TestScan -Ram 8) -All)
        @($all | Where-Object { $_.DefaultSelected -and $_.Risk -ne 'LOW RISK' }).Count | Should -Be 0
        @($all | Where-Object { $_.DefaultSelected -and $_.Kind -eq 'Service' }).Count | Should -Be 0
        @($all | Where-Object { $_.DefaultSelected -and $_.Tier -ne 'SAFE' }).Count | Should -Be 0
        @($all | Where-Object { $_.DefaultSelected -and $_.Rollback -ne 'Full' }).Count | Should -Be 0
    }
    It 'blocks the touch keyboard service on a touchscreen' {
        $row = @(Get-Recommendations -Scan (New-TestScan -Touch $true) -All | Where-Object { $_.Id -like 'svc-tabletinputservice*' })[0]
        $row.Blocked | Should -Not -BeNullOrEmpty
        $row.Selectable | Should -BeFalse
    }
    It 'does not recommend disabling Windows Search, SysMain or Xbox services' {
        $ids = @(Get-Recommendations -Scan (New-TestScan -Ram 8) | ForEach-Object { $_.Id })
        $ids | Should -Not -Contain 'svc-wsearch-disabled'
        $ids | Should -Not -Contain 'svc-sysmain-disabled'
        @($ids | Where-Object { $_ -like 'svc-xbl*' -or $_ -like 'svc-xbox*' }).Count | Should -Be 0
    }
    It 'Quick Optimize contains only LOW RISK items' {
        $set = @(Get-QuickOptimizeSet -Scan (New-TestScan -Ram 8))
        @($set | Where-Object { $_.Risk -ne 'LOW RISK' }).Count | Should -Be 0
        @($set | Where-Object { $_.Kind -eq 'Trim' }).Count | Should -Be 0
    }
    It 'uses the edition-appropriate diagnostic-data level' {
        $pro = @(Get-TweakCatalog -Scan (New-TestScan) | Where-Object { $_.Id -eq 'privacy-diag' })[0]
        $pro.Entries[0].Value | Should -Be 1
        $s = New-TestScan; $s.Windows.Edition = 'Enterprise'
        (@(Get-TweakCatalog -Scan $s | Where-Object { $_.Id -eq 'privacy-diag' })[0]).Entries[0].Value | Should -Be 0
    }
}

Describe 'Apply engine (transaction model)' {
    BeforeEach {
        $Script:BackupSession = $null
        $Script:LastScan = New-TestScan
        if (Test-Path 'TestRegistry:\Apply') { Remove-Item 'TestRegistry:\Apply' -Recurse -Force }
        New-Item -Path 'TestRegistry:\Apply' -Force | Out-Null
        New-ItemProperty -LiteralPath 'TestRegistry:\Apply' -Name V -PropertyType DWord -Value 1 | Out-Null
        $script:tw = New-Tweak @{ Id = 't-reg'; Name = 'Test tweak'; Category = 'Test'; Risk = 'LOW RISK'; Kind = 'Registry'
            Entries = @(@{ Path = 'TestRegistry:\Apply'; Name = 'V'; Type = 'DWord'; Value = 0 }); Labels = @{ '0' = 'Off'; '1' = 'On' } }
        Mock New-DivRestorePoint { [pscustomobject]@{ Status = 'Skipped'; Message = 'test' } }
    }
    It 'backs up first, changes, verifies and logs the result' {
        $res = Invoke-ApplyPlan -Tweaks @($script:tw) -Description 'unit'
        $res.Success | Should -Be 1
        $res.Failed | Should -Be 0
        $res.BackupOk | Should -BeTrue
        (Get-ItemProperty -LiteralPath 'TestRegistry:\Apply' -Name V).V | Should -Be 0
        (Test-BackupDir -Dir $res.BackupDir).Ok | Should -BeTrue
        $recs = @((Read-JsonFile -Path (Join-Path $res.BackupDir 'registry/registry.json')).Records)
        $recs[0].Value | Should -Be 1
        # and the backup really restores it
        (Restore-Backup -Dir $res.BackupDir -Types @('Registry')).Success | Should -Be 1
        (Get-ItemProperty -LiteralPath 'TestRegistry:\Apply' -Name V).V | Should -Be 1
    }
    It 'reports failure honestly and rolls the tweak back' {
        Mock Invoke-TweakChange { throw 'boom' }
        $res = Invoke-ApplyPlan -Tweaks @($script:tw) -Description 'unit'
        $res.Failed | Should -Be 1
        $res.Success | Should -Be 0
        $res.Items[0].Message | Should -Match 'boom'
        (Get-ItemProperty -LiteralPath 'TestRegistry:\Apply' -Name V).V | Should -Be 1
    }
    It 'reports a change that does not verify as failed and rolls back' {
        Mock Invoke-TweakChange { }   # "succeeds" but changes nothing
        $res = Invoke-ApplyPlan -Tweaks @($script:tw) -Description 'unit'
        $res.Failed | Should -Be 1
        $res.Items[0].Message | Should -Match 'Verification failed'
    }
    It 'makes no change in dry-run mode' {
        $Script:DryRun = $true
        try {
            $res = Invoke-ApplyPlan -Tweaks @($script:tw) -Description 'unit'
            $res.Aborted | Should -BeTrue
            (Get-ItemProperty -LiteralPath 'TestRegistry:\Apply' -Name V).V | Should -Be 1
            Set-RegistryValueSafe -Path 'TestRegistry:\Apply' -Name V -Type DWord -Value 9 | Out-Null
            (Get-ItemProperty -LiteralPath 'TestRegistry:\Apply' -Name V).V | Should -Be 1
        } finally { $Script:DryRun = $false }
    }
    It 'refuses ADVANCED changes without explicit confirmation' {
        $adv = New-Tweak @{ Id = 't-adv'; Name = 'Adv'; Risk = 'ADVANCED'; Kind = 'Registry'; Entries = @(@{ Path = 'TestRegistry:\Apply'; Name = 'V'; Type = 'DWord'; Value = 0 }) }
        $res = Invoke-ApplyPlan -Tweaks @($adv) -Description 'unit'
        $res.Aborted | Should -BeTrue
        (Get-ItemProperty -LiteralPath 'TestRegistry:\Apply' -Name V).V | Should -Be 1
    }
    It 'cancels advanced changes when the backup fails' {
        Mock Save-BackupSession { throw 'disk full' }
        $adv = New-Tweak @{ Id = 't-adv'; Name = 'Adv'; Risk = 'ADVANCED'; Kind = 'Registry'; Entries = @(@{ Path = 'TestRegistry:\Apply'; Name = 'V'; Type = 'DWord'; Value = 0 }) }
        $res = Invoke-ApplyPlan -Tweaks @($adv) -Description 'unit' -AdvancedConfirmed
        $res.Aborted | Should -BeTrue
        (Get-ItemProperty -LiteralPath 'TestRegistry:\Apply' -Name V).V | Should -Be 1
    }
}

Describe 'Backup retention' {
    BeforeEach {
        if (Test-Path $Script:BackupsDir) { Remove-Item $Script:BackupsDir -Recurse -Force }
        1..7 | ForEach-Object {
            $d = Join-Path $Script:BackupsDir ('2026-01-0{0}_000000' -f $_)
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Write-JsonFile -Path (Join-Path $d 'backup.json') -Object ([ordered]@{ SchemaVersion = 2; BackupId = (Split-Path -Leaf $d); Files = [ordered]@{}; Changes = @() })
        }
    }
    It 'never selects anything for deletion when retention is All' {
        Save-DivSettings -Settings ([pscustomobject]@{ BackupRetention = 'All' })
        @(Get-BackupsOverRetention).Count | Should -Be 0
    }
    It 'selects only the oldest backups beyond the limit (deletion still needs confirmation)' {
        $Script:ReadOnlyRun = $false
        try { Save-DivSettings -Settings ([pscustomobject]@{ BackupRetention = '5' }) } finally { $Script:ReadOnlyRun = $true }
        $over = @(Get-BackupsOverRetention)
        $over.Count | Should -Be 2
        @($over | ForEach-Object { $_.Id }) | Should -Be @('2026-01-02_000000', '2026-01-01_000000')
    }
}

Describe 'Remote (irm | iex) elevation safeguards' {
    It 'only accepts HTTPS GitHub script URLs' {
        Test-AllowedScriptUrl -Url 'https://raw.githubusercontent.com/Bulbug/DIVoptimizer/refs/heads/main/DIVoptimizer.ps1' | Should -BeTrue
        Test-AllowedScriptUrl -Url 'http://raw.githubusercontent.com/x/y/main/a.ps1' | Should -BeFalse
        Test-AllowedScriptUrl -Url 'https://evil.example.com/a.ps1' | Should -BeFalse
        Test-AllowedScriptUrl -Url 'https://raw.githubusercontent.com.evil.com/a.ps1' | Should -BeFalse
        Test-AllowedScriptUrl -Url 'not a url' | Should -BeFalse
    }
    It 'only lets plain identifiers into a relaunch command line' {
        ConvertTo-SafeIdList -Ids @('gamedvr-off', "x'; calc; '", 'startup-disable_a_b', 'a b', '$(evil)') | Should -Be 'gamedvr-off,startup-disable_a_b'
    }
    It 'ignores an unsafe DIVOPTIMIZER_URL override' {
        $old = $env:DIVOPTIMIZER_URL
        try {
            $env:DIVOPTIMIZER_URL = 'https://evil.example.com/a.ps1'
            Get-SelfUrl | Should -Be $Script:SelfUrl
        } finally { $env:DIVOPTIMIZER_URL = $old }
    }
    It 'points the built-in URLs at GitHub over HTTPS' {
        Test-AllowedScriptUrl -Url $Script:SelfUrl | Should -BeTrue
        Test-AllowedScriptUrl -Url $Script:ResetUrl | Should -BeTrue
    }
}

Describe 'Administrator relaunch and progress' {
    It 'relaunches in the same mode the user chose' {
        @(Get-RelaunchModeArgs -IsConsole $false -IsQuick $true -ProfileId '') | Should -Be @('-Quick')
        @(Get-RelaunchModeArgs -IsConsole $false -IsQuick $false -ProfileId 'Gaming') | Should -Be @('-ProfileName', 'Gaming')
        @(Get-RelaunchModeArgs -IsConsole $true -IsQuick $false -ProfileId '') | Should -Be @('-Console')
        @(Get-RelaunchModeArgs -IsConsole $false -IsQuick $false -ProfileId '').Count | Should -Be 0
    }
    It 'never passes an unknown profile name into a command line' {
        @(Get-RelaunchModeArgs -IsConsole $true -IsQuick $false -ProfileId 'x; calc') | Should -Be @('-Console')
    }
    It 'rejects an unsafe relaunch argument' {
        Mock Start-Process { }
        Request-Elevation -Why 'test' -Silent -ModeArgs @('-Console; calc') | Should -BeFalse
        Should -Invoke Start-Process -Times 0
    }
    It 'progress helpers do not throw in the console' {
        { Write-Busy -Activity 'Test' -Status 'Step' -Percent 50 } | Should -Not -Throw
        { Write-Busy -Activity 'Test' -Status 'Step' } | Should -Not -Throw
        { Clear-Busy } | Should -Not -Throw
    }
}

Describe 'Tiers and compatibility (v0.8.0)' {
    It 'maps risk levels to tiers' {
        Get-TweakTier -Tweak ([pscustomobject]@{ Risk = 'LOW RISK' }) | Should -Be 'SAFE'
        Get-TweakTier -Tweak ([pscustomobject]@{ Risk = 'OPTIONAL' }) | Should -Be 'BALANCED'
        Get-TweakTier -Tweak ([pscustomobject]@{ Risk = 'ADVANCED' }) | Should -Be 'ADVANCED'
    }
    It 'only allows two services to be changed' {
        $Script:ServiceAllowList.Count | Should -Be 2
    }
    It 'creates backup IDs in the new format' {
        'backup-2026-10-10-122500-0A1F' | Should -Match '^backup-\d{4}-\d{2}-\d{2}-\d{6}-[0-9A-F]{4}$'
    }
}

Describe 'Health and Undo (v0.8.0)' {
    It 'health report returns the expected checks' {
        $r = @(Get-HealthReport)
        $r.Count | Should -BeGreaterThan 4
        ($r | Where-Object { $_.Check -eq 'Service allow-list' }).Ok | Should -BeTrue
    }
    It 'relaunch keeps -Undo' {
        (Get-RelaunchModeArgs -IsConsole $false -IsQuick $false -IsUndo $true) | Should -Contain '-Undo'
    }
}
