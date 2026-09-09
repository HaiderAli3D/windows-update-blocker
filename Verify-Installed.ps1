[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess) {
    throw 'Use 64-bit Windows PowerShell 5.1 (Desktop edition) on Windows. PowerShell 7 and 32-bit hosts are not supported.'
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run installed verification as administrator.' }
$root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WindowsUpdateBlock'
$taskName='WindowsUpdateBlock-Enforce'
$ruleGroup='Windows Update Block (local owner request)'
$ruleName=$null
$evidence=[ordered]@{Started=(Get-Date).ToString('o');Passed=$false;Errors=@()}
$restoreRule=$false
try {
    $state=Import-Clixml -LiteralPath (Join-Path $root 'original-state.clixml')
    if ($state.Version -ne 1 -or $state.FirewallRules -isnot [System.Collections.IDictionary] -or $state.FirewallRules.Count -eq 0) { throw 'A supported original-state backup with owned firewall rules is required.' }
    $expectedNames=@($state.FirewallRules.Keys | Sort-Object)
    # Windows builds expose different update executables and services. Use this
    # installation's saved ownership list, never a machine-specific rule count.
    $expectedFilters=@{}
    foreach ($serviceName in @('wuauserv','UsoSvc','WaaSMedicSvc','uhssvc')) {
        $expectedFilters["WindowsUpdateBlock-Service-$serviceName"]=@{Program="$env:SystemRoot\System32\svchost.exe";Service=$serviceName}
    }
    foreach ($program in @(
        "$env:SystemRoot\System32\UsoClient.exe",
        "$env:SystemRoot\System32\MoUsoCoreWorker.exe",
        "$env:SystemRoot\uus\AMD64\MoUsoCoreWorker.exe",
        "$env:SystemRoot\uus\ARM64\MoUsoCoreWorker.exe",
        "$env:SystemRoot\System32\SIHClient.exe",
        "$env:SystemRoot\System32\WaaSMedicAgent.exe"
    )) {
        $suffix=$program.Substring($env:SystemRoot.Length).Replace('\','-').Replace('.','-')
        $expectedFilters["WindowsUpdateBlock-Program$suffix"]=@{Program=$program;Service='Any'}
    }
    foreach ($name in $expectedNames) {
        if (-not $expectedFilters.ContainsKey($name)) { throw "The backup contains an unknown owned firewall rule: $name" }
    }
    $ruleName=if ('WindowsUpdateBlock-Service-wuauserv' -in $expectedNames) { 'WindowsUpdateBlock-Service-wuauserv' } else { $expectedNames[0] }
    $task=Get-ScheduledTask -TaskName $taskName
    if ($task.Principal.UserId -notin @('SYSTEM','S-1-5-18') -or -not $task.Settings.Enabled) { throw 'The SYSTEM guard is not enabled.' }
    [xml]$xml=Export-ScheduledTask -TaskName $taskName
    $ns=New-Object Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    $boot=$xml.SelectSingleNode('/t:Task/t:Triggers/t:BootTrigger',$ns)
    $repeat=$xml.SelectSingleNode('/t:Task/t:Triggers/t:TimeTrigger/t:Repetition',$ns)
    if (-not $boot -or $repeat.Interval -ne 'PT1M' -or $repeat.Duration) { throw 'The task lacks startup plus indefinite one-minute enforcement.' }
    if ($task.Settings.DisallowStartIfOnBatteries -or $task.Settings.StopIfGoingOnBatteries -or $task.Settings.WakeToRun) { throw 'Task battery/wake settings are unexpected.' }
    $evidence.Task=[ordered]@{User=$task.Principal.UserId;BootTrigger=$true;Interval=$repeat.Interval;Duration='Indefinite';RunsOnBattery=$true;WakesComputer=$false;Action=$task.Actions.Arguments}

    # Prove that an actual service-start request is rejected by the service manager.
    $service=Get-Service -Name wuauserv
    if ($service.StartType -ne 'Disabled' -or $service.Status -ne 'Stopped') { throw 'Windows Update is not stopped and disabled.' }
    try {
        $service.Start()
        $service.Stop()
        throw 'Windows Update unexpectedly accepted a start request.'
    } catch {
        $exception=$_.Exception
        while ($exception.InnerException) { $exception=$exception.InnerException }
        if ($exception -isnot [ComponentModel.Win32Exception] -or $exception.NativeErrorCode -ne 1058) { throw }
        $evidence.ServiceStartTest=[ordered]@{Rejected=$true;Win32Error=1058;Meaning='Service disabled'}
    }

    # Keep every update service stopped; test only restoration of our own extra firewall layer.
    $before=Get-NetFirewallRule -Name $ruleName
    if ($before.Enabled -ne 'True' -or $before.Action -ne 'Block') { throw 'The test rule is not initially enabled as a block.' }
    $start=(Get-Date)
    Disable-NetFirewallRule -Name $ruleName | Out-Null
    $restoreRule=$true
    $deadline=$start.AddSeconds(100)
    $reapplied=$false
    do {
        Start-Sleep -Seconds 2
        $rule=Get-NetFirewallRule -Name $ruleName
        if ($rule.Enabled -eq 'True') { $reapplied=$true;break }
    } while ((Get-Date) -lt $deadline)
    if (-not $reapplied) { throw 'The periodic guard did not restore its firewall rule within 100 seconds.' }
    $restoreRule=$false
    $evidence.ReapplicationTest=[ordered]@{Rule=$ruleName;Restored=$true;Seconds=[math]::Round(((Get-Date)-$start).TotalSeconds,1)}
    $deadline=(Get-Date).AddSeconds(35)
    do {
        Start-Sleep -Seconds 2
        $task=Get-ScheduledTask -TaskName $taskName
        $info=Get-ScheduledTaskInfo -TaskName $taskName
    } while ($task.State -eq 'Running' -and (Get-Date) -lt $deadline)
    if ($task.State -eq 'Running' -or $info.LastTaskResult -ne 0) { throw "The verification run did not finish successfully: $($info.LastTaskResult)" }
    $report=Get-Content -LiteralPath (Join-Path $root 'last-enforce.json') -Raw | ConvertFrom-Json
    if ([datetimeoffset]::Parse($report.Time) -lt $start -or $report.Issues.Count -gt 0 -or -not $report.AllPresentUpdateServicesBlocked -or -not $report.AllVisibleUpdateTasksDisabled) { throw 'The fresh guard report is incomplete.' }
    if (@($report.Policies).Count -ne 7 -or @($report.Policies | Where-Object {-not $_.Matches}).Count -gt 0) { throw 'A policy differs from the expected configuration.' }
    # Inspect the effective firewall configuration, including its actual filters.
    $rules=@(Get-NetFirewallRule -PolicyStore ActiveStore -Group $ruleGroup)
    $actualNames=@($rules.Name | Sort-Object)
    if ($actualNames.Count -ne $expectedNames.Count -or @(Compare-Object -ReferenceObject $expectedNames -DifferenceObject $actualNames).Count -gt 0) { throw 'Effective firewall rule names do not match the saved ownership list.' }
    foreach ($rule in $rules) {
        if ($rule.Enabled -ne 'True' -or $rule.Action -ne 'Block' -or $rule.Direction -ne 'Outbound' -or $rule.Profile -ne 'Any') { throw "A firewall rule differs from the expected configuration: $($rule.Name)" }
        $expected=$expectedFilters[$rule.Name]
        $appFilter=$rule | Get-NetFirewallApplicationFilter
        $serviceFilter=$rule | Get-NetFirewallServiceFilter
        $addressFilter=$rule | Get-NetFirewallAddressFilter
        $portFilter=$rule | Get-NetFirewallPortFilter
        if ([Environment]::ExpandEnvironmentVariables($appFilter.Program) -ne $expected.Program -or $serviceFilter.Service -ne $expected.Service) { throw "A firewall application or service filter differs: $($rule.Name)" }
        if (@($addressFilter.LocalAddress).Count -ne 1 -or $addressFilter.LocalAddress -ne 'Any' -or @($addressFilter.RemoteAddress).Count -ne 1 -or $addressFilter.RemoteAddress -ne 'Any' -or $portFilter.Protocol -ne 'Any' -or @($portFilter.LocalPort).Count -ne 1 -or $portFilter.LocalPort -ne 'Any' -or @($portFilter.RemotePort).Count -ne 1 -or $portFilter.RemotePort -ne 'Any') { throw "A firewall address or port filter is unexpectedly restricted: $($rule.Name)" }
    }
    $profiles=@(Get-NetFirewallProfile -PolicyStore ActiveStore)
    if ($profiles.Count -ne 3 -or @($profiles | Where-Object {$_.Enabled -ne 'True'}).Count -gt 0) { throw 'All three Windows Firewall profiles must be enabled for this verification to pass.' }
    $evidence.ExpectedFirewallRuleNames=$expectedNames
    $evidence.EffectiveFirewallProfiles=@($profiles | Select-Object Name,Enabled)
    $evidence.CompletedTaskResult=$info.LastTaskResult
    $evidence.CompletedTaskLastRun=$info.LastRunTime.ToString('o')
    $evidence.FinalReport=$report
    $evidence.PreservedServices=@(Get-CimInstance Win32_Service -Filter "Name='BITS' OR Name='DoSvc' OR Name='WinDefend'" | Select-Object Name,State,StartMode)
    $evidence.Passed=$true
} catch {
    $evidence.Errors+=@($_.Exception.Message)
} finally {
    if ($restoreRule) { Enable-NetFirewallRule -Name $ruleName | Out-Null }
    $evidence.Finished=(Get-Date).ToString('o')
    $evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $root 'verification.json') -Encoding UTF8
}
if (-not $evidence.Passed) { exit 1 }
