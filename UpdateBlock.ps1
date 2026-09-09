[CmdletBinding()]
param([ValidateSet('Enforce','Restore','Verify')][string]$Mode = 'Verify')

# OS update controls only. Never remove servicing files or pending-reboot markers.
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess) {
    throw 'Use 64-bit Windows PowerShell 5.1 (Desktop edition) on Windows. PowerShell 7 and 32-bit hosts are not supported.'
}
$root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WindowsUpdateBlock'
$statePath = Join-Path $root 'original-state.clixml'
$taskName = 'WindowsUpdateBlock-Enforce'
$ruleGroup = 'Windows Update Block (local owner request)'
$serviceNames = @('wuauserv','UsoSvc','WaaSMedicSvc','uhssvc')
$taskPaths = @(
    '\Microsoft\Windows\UpdateOrchestrator\',
    '\Microsoft\Windows\WindowsUpdate\',
    '\Microsoft\Windows\WaaSMedic\',
    '\Microsoft\Windows\UpdateAssistant\',
    '\Microsoft\Windows\WindowsUpdateUpdateServices\',
    '\Microsoft\Windows\rempl\'
)
$policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$policies = @(
    @{Path="$policyPath\AU"; Name='NoAutoUpdate'; Value=1; Kind='DWord'},
    @{Path=$policyPath; Name='SetDisableUXWUAccess'; Value=1; Kind='DWord'},
    @{Path=$policyPath; Name='DoNotConnectToWindowsUpdateInternetLocations'; Value=1; Kind='DWord'},
    @{Path=$policyPath; Name='ExcludeWUDriversInQualityUpdate'; Value=1; Kind='DWord'},
    @{Path=$policyPath; Name='WUServer'; Value='http://127.0.0.1:9'; Kind='String'},
    @{Path=$policyPath; Name='WUStatusServer'; Value='http://127.0.0.1:9'; Kind='String'},
    @{Path="$policyPath\AU"; Name='UseWUServer'; Value=1; Kind='DWord'}
)
$script:issues = New-Object 'System.Collections.Generic.List[string]'
$script:changed = New-Object 'System.Collections.Generic.List[string]'

function Save-State {
    $temporaryPath = Join-Path $root 'original-state.new.clixml'
    $script:state | Export-Clixml -LiteralPath $temporaryPath -Depth 12
    Move-Item -LiteralPath $temporaryPath -Destination $statePath -Force
}

function Invoke-Step([string]$Label, [scriptblock]$Action) {
    try { & $Action } catch { $script:issues.Add("${Label}: $($_.Exception.Message)") }
}

function Save-RegistryValue([string]$Path,[string]$Name) {
    $id = "$Path|$Name"
    if (-not $script:state.Registry.ContainsKey($id)) {
        $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        $exists = $null -ne $key -and $Name -in $key.GetValueNames()
        $script:state.Registry[$id] = @{
            Path=$Path; Name=$Name; Exists=$exists
            Value=if($exists){$key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}else{$null}
            Kind=if($exists){$key.GetValueKind($Name).ToString()}else{$null}
        }
        Save-State
    }
}

function Set-BackedValue([string]$Path,[string]$Name,$Value,[string]$Kind) {
    Save-RegistryValue $Path $Name
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    $key = Get-Item -LiteralPath $Path
    if ($Name -notin $key.GetValueNames() -or $key.GetValue($Name) -ne $Value -or $key.GetValueKind($Name).ToString() -ne $Kind) {
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
        $script:changed.Add("Registry $Path $Name")
    }
}

function Get-UpdateTasks {
    # Enumeration under SYSTEM includes protected folders hidden from a normal user.
    @(Get-ScheduledTask | Where-Object { $_.TaskPath -in $taskPaths })
}

function Get-RuleSpecifications {
    foreach ($name in $serviceNames) {
        if (Get-Service -Name $name -ErrorAction SilentlyContinue) {
            # Service SID must be enabled for a service filter to apply.
            $sidType = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name ServiceSidType -ErrorAction SilentlyContinue).ServiceSidType
            if ($sidType -in @(1,3)) {
                @{Name="WindowsUpdateBlock-Service-$name"; Service=$name; Program="$env:SystemRoot\System32\svchost.exe"}
            } else { $script:issues.Add("Firewall service filter unavailable: $name has no service SID") }
        }
    }
    $programs = @(
        "$env:SystemRoot\System32\UsoClient.exe",
        "$env:SystemRoot\System32\MoUsoCoreWorker.exe",
        "$env:SystemRoot\uus\AMD64\MoUsoCoreWorker.exe",
        "$env:SystemRoot\uus\ARM64\MoUsoCoreWorker.exe",
        "$env:SystemRoot\System32\SIHClient.exe",
        "$env:SystemRoot\System32\WaaSMedicAgent.exe"
    )
    foreach ($program in $programs) {
        if (Test-Path -LiteralPath $program -PathType Leaf) {
            $suffix = $program.Substring($env:SystemRoot.Length).Replace('\','-').Replace('.','-')
            @{Name="WindowsUpdateBlock-Program$suffix"; Program=$program; Service='Any'}
        }
    }
}

function Get-Report {
    $services = @(foreach($name in $serviceNames) {
        $service = Get-CimInstance Win32_Service -Filter "Name='$name'"
        if ($service) {
            $start = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name Start).Start
            [pscustomobject]@{Name=$name; State=$service.State; StartMode=$service.StartMode; RegistryStart=$start; Blocked=($service.State -eq 'Stopped' -and $start -eq 4)}
        }
    })
    $updateTasks = @(Get-UpdateTasks | Select-Object TaskPath,TaskName,@{N='Enabled';E={$_.Settings.Enabled}},State)
    $rules = @(Get-NetFirewallRule -Group $ruleGroup -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{Name=$_.Name;Enabled=$_.Enabled.ToString();Direction=$_.Direction.ToString();Action=$_.Action.ToString();Profile=$_.Profile.ToString();Program=($_ | Get-NetFirewallApplicationFilter).Program;Service=($_ | Get-NetFirewallServiceFilter).Service}
    })
    $policyChecks = @(foreach ($entry in $policies) {
        $actual = (Get-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue).($entry.Name)
        [pscustomobject]@{Path=$entry.Path;Name=$entry.Name;Value=$actual;Expected=$entry.Value;Matches=($actual -eq $entry.Value)}
    })
    $profiles = @(Get-NetFirewallProfile | Select-Object Name,Enabled)
    $guard = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $guardInfo = if($guard){Get-ScheduledTaskInfo -TaskName $taskName}else{$null}
    [ordered]@{
        Time=(Get-Date).ToString('o'); Mode=$Mode; User=[Security.Principal.WindowsIdentity]::GetCurrent().Name
        Services=$services; UpdateTasks=$updateTasks; FirewallRules=$rules; FirewallProfiles=$profiles; Policies=$policyChecks
        Guard=if($guard){[ordered]@{Enabled=$guard.Settings.Enabled; State=$guard.State.ToString(); User=$guard.Principal.UserId; LastRun=$guardInfo.LastRunTime; LastResult=$guardInfo.LastTaskResult; NextRun=$guardInfo.NextRunTime}}else{$null}
        PrimaryUpdateServicesBlocked=(@($services | Where-Object {$_.Name -in @('wuauserv','UsoSvc') -and $_.Blocked}).Count -eq 2)
        AllPresentUpdateServicesBlocked=(@($services | Where-Object {-not $_.Blocked}).Count -eq 0)
        AllVisibleUpdateTasksDisabled=(@($updateTasks | Where-Object Enabled).Count -eq 0)
        WindowsUpdateRebootPending=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        ServicingRebootPending=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        Changes=@($script:changed.ToArray()); Issues=@($script:issues.ToArray())
    }
}

if ($Mode -eq 'Verify') { Get-Report | ConvertTo-Json -Depth 8; exit 0 }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator approval is required.' }
if ($PSScriptRoot -ne $root) { throw "Install this script into the protected directory $root first." }

# Enforce and restore never modify settings concurrently, including when manually invoked.
$mutex = New-Object Threading.Mutex($false,'Global\WindowsUpdateBlock-Settings')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
    if (-not $locked) { throw 'Another update-block operation is running. Retry after it finishes.' }
    if (Test-Path -LiteralPath $statePath) {
        $script:state = Import-Clixml -LiteralPath $statePath
    } elseif ($Mode -eq 'Enforce') {
        $script:state = @{Version=1; Created=(Get-Date).ToString('o'); Registry=@{}; Tasks=@{}; FirewallRules=@{}}
        Save-State
    } else { throw 'Original settings backup is missing; refusing to guess restore values.' }

    if ($Mode -eq 'Restore') {
        Disable-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Out-Null
        foreach ($name in @($script:state.FirewallRules.Keys)) {
            Invoke-Step "Remove firewall rule $name" {
                if (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -Name $name }
            }
        }
        foreach ($entry in $script:state.Registry.Values) {
            Invoke-Step "Restore $($entry.Path) $($entry.Name)" {
                if ($entry.Exists) {
                    if (-not (Test-Path -LiteralPath $entry.Path)) { New-Item -Path $entry.Path -Force | Out-Null }
                    New-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value $entry.Value -PropertyType $entry.Kind -Force | Out-Null
                    if ($entry.Name -eq 'Start' -and $entry.Path -match '\\Services\\([^\\]+)$') {
                        $startModes = @{0='boot';1='system';2='auto';3='demand';4='disabled'}
                        # Registry restoration remains valid even if a protected SCM refuses config.
                        $null = & "$env:SystemRoot\System32\sc.exe" config $Matches[1] start= $startModes[[int]$entry.Value] 2>&1
                    }
                } elseif (Get-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue) {
                    Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name
                }
            }
        }
        foreach ($entry in $script:state.Tasks.Values) {
            if ($entry.Enabled) {
                Invoke-Step "Restore task $($entry.Path)$($entry.Name)" {
                    Enable-ScheduledTask -TaskPath $entry.Path -TaskName $entry.Name | Out-Null
                }
            }
        }
        if ($script:issues.Count -eq 0) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Set-Content -LiteralPath (Join-Path $root 'RESTORED.txt') -Value (Get-Date).ToString('o')
        }
    } else {
        if (Test-Path -LiteralPath (Join-Path $root 'RESTORED.txt')) { throw 'This installation was restored. Install a fresh backup before applying again.' }
        foreach ($entry in $policies) {
            Invoke-Step "Policy $($entry.Name)" { Set-BackedValue $entry.Path $entry.Name $entry.Value $entry.Kind }
        }
        foreach ($name in $serviceNames) {
            if (Get-Service -Name $name -ErrorAction SilentlyContinue) {
                Invoke-Step "Disable service $name" {
                    $servicePath = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
                    Save-RegistryValue $servicePath 'Start'
                    $service = Get-Service -Name $name
                    if ($service.StartType -ne 'Disabled') {
                        $null = & "$env:SystemRoot\System32\sc.exe" config $name start= disabled 2>&1
                    }
                    Set-BackedValue $servicePath 'Start' 4 'DWord'
                    $service.Refresh()
                    if ($service.Status -ne 'Stopped') {
                        # Graceful SCM stop only. Never kill servicing or svchost processes.
                        $service.Stop()
                        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(15))
                        $script:changed.Add("Stopped service $name")
                    }
                }
            }
        }
        foreach ($task in @(Get-UpdateTasks)) {
            $id = "$($task.TaskPath)$($task.TaskName)"
            Invoke-Step "Disable task $id" {
                if (-not $script:state.Tasks.ContainsKey($id)) {
                    $script:state.Tasks[$id] = @{Path=$task.TaskPath;Name=$task.TaskName;Enabled=[bool]$task.Settings.Enabled;Xml=(Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath)}
                    Save-State
                }
                if ($task.Settings.Enabled) {
                    Disable-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName | Out-Null
                    $script:changed.Add("Disabled task $id")
                }
            }
        }
        foreach ($spec in @(Get-RuleSpecifications)) {
            Invoke-Step "Firewall $($spec.Name)" {
                $existing = Get-NetFirewallRule -Name $spec.Name -ErrorAction SilentlyContinue
                if ($existing -and -not $script:state.FirewallRules.ContainsKey($spec.Name)) { throw 'A rule with this name already exists and is not owned by this installation.' }
                if (-not $existing) {
                    $script:state.FirewallRules[$spec.Name] = $true
                    Save-State
                    New-NetFirewallRule -Name $spec.Name -DisplayName $spec.Name -Group $ruleGroup -Direction Outbound -Action Block -Enabled True -Profile Any -Program $spec.Program -Service $spec.Service | Out-Null
                    $script:changed.Add("Created firewall rule $($spec.Name)")
                } else {
                    if ($existing.Enabled -ne 'True' -or $existing.Direction -ne 'Outbound' -or $existing.Action -ne 'Block' -or $existing.Profile -ne 'Any') {
                        Set-NetFirewallRule -Name $spec.Name -Direction Outbound -Action Block -Enabled True -Profile Any | Out-Null
                    }
                    $appFilter = $existing | Get-NetFirewallApplicationFilter
                    if ($appFilter.Program -ne $spec.Program) { $appFilter | Set-NetFirewallApplicationFilter -Program $spec.Program | Out-Null }
                    $serviceFilter = $existing | Get-NetFirewallServiceFilter
                    if ($serviceFilter.Service -ne $spec.Service) { $serviceFilter | Set-NetFirewallServiceFilter -Service $spec.Service | Out-Null }
                }
            }
        }
    }
    $report = Get-Report
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root ("last-$($Mode.ToLowerInvariant()).json")) -Encoding UTF8
    if ($script:changed.Count -gt 0 -or $script:issues.Count -gt 0 -or $Mode -eq 'Restore') {
        $logPath=Join-Path $root 'activity.log'
        if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 2MB) { Move-Item -LiteralPath $logPath -Destination (Join-Path $root 'activity.previous.log') -Force }
        [ordered]@{Time=$report.Time;Mode=$Mode;Changes=$report.Changes;Issues=$report.Issues} | ConvertTo-Json -Compress -Depth 5 | Add-Content -LiteralPath $logPath -Encoding UTF8
    }
    $report | ConvertTo-Json -Depth 8
    if ($script:issues.Count -gt 0) { exit 2 }
    if ($Mode -eq 'Enforce' -and (-not $report.PrimaryUpdateServicesBlocked -or -not $report.AllPresentUpdateServicesBlocked -or -not $report.AllVisibleUpdateTasksDisabled)) { exit 3 }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
