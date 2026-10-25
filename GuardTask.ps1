# Shared guard task definition. Dot-sourced by Install.ps1, Upgrade.ps1 and Verify-Installed.ps1.
# Defines values and functions only; dot-sourcing it changes no Windows settings.

# GuardTask.ps1 comes first: newer scripts dot-source it, older ones ignore it.
$installedFiles = @('GuardTask.ps1','UpdateBlock.ps1','Restore.ps1','Verify-Installed.ps1','README.md')

function New-InstallDirectorySecurity {
    # The SYSTEM task must never execute a script writable by an ordinary user.
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    $readRule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($readRule)
    $acl
}

function Test-InstallDirectorySecurity([string]$Root) {
    $item = Get-Item -LiteralPath $Root -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    $actualAcl = Get-Acl -LiteralPath $Root
    $actualAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544' -and $actualAcl.GetSecurityDescriptorSddlForm('Access') -eq (New-InstallDirectorySecurity).GetSecurityDescriptorSddlForm('Access')
}

function Copy-InstalledFiles([string]$SourceRoot, [string]$Root) {
    # Stage every file beside its target before swapping any, so a failed copy leaves the old set intact.
    foreach ($fileName in $installedFiles) {
        $staged = Join-Path $Root "$fileName.new"
        Copy-Item -LiteralPath (Join-Path $SourceRoot $fileName) -Destination $staged -Force
        $fileAcl = Get-Acl -LiteralPath $staged
        $fileAcl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        Set-Acl -LiteralPath $staged -AclObject $fileAcl
        if ((Get-Acl -LiteralPath $staged).GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544') { throw "Unexpected file owner: $staged" }
    }
    foreach ($fileName in $installedFiles) {
        Move-Item -LiteralPath (Join-Path $Root "$fileName.new") -Destination (Join-Path $Root $fileName) -Force
    }
}

function Get-UpdatePrograms {
    $healthTools = Join-Path $env:ProgramFiles 'Microsoft Update Health Tools'
    @(
        "$env:SystemRoot\System32\UsoClient.exe",
        "$env:SystemRoot\System32\MoUsoCoreWorker.exe",
        "$env:SystemRoot\uus\AMD64\MoUsoCoreWorker.exe",
        "$env:SystemRoot\uus\ARM64\MoUsoCoreWorker.exe",
        "$env:SystemRoot\System32\SIHClient.exe",
        "$env:SystemRoot\System32\WaaSMedicAgent.exe",
        "$env:SystemRoot\uus\AMD64\WaaSMedicAgent.exe",
        "$env:SystemRoot\uus\ARM64\WaaSMedicAgent.exe",
        "$env:SystemRoot\uus\AMD64\wuaucltcore.exe",
        "$env:SystemRoot\uus\AMD64\UIEOrchestrator.exe",
        "$env:SystemRoot\uus\AMD64\MoNotificationUx.exe",
        "$healthTools\uhssvc.exe",
        "$healthTools\expediteupdater.exe"
    )
}

function Get-ProgramRuleName([string]$Program) {
    # Windows-directory rule names match earlier releases, so installed backups keep their ownership list.
    $suffix = if ($Program.StartsWith($env:SystemRoot, [StringComparison]::OrdinalIgnoreCase)) { $Program.Substring($env:SystemRoot.Length) } else { '-ProgramFiles' + $Program.Substring($env:ProgramFiles.Length) }
    "WindowsUpdateBlock-Program$($suffix.Replace('\','-').Replace('.','-').Replace(' ',''))"
}

function Get-GuardSubscription {
    # Windows Update API callers flip wuauserv from disabled to demand start (SCM 7040; param4 is the
    # unlocalized service key name). 7036 is not logged on current builds, so it is not used.
    $serviceMatch = (@('wuauserv','UsoSvc','WaaSMedicSvc','uhssvc') | ForEach-Object { "Data[@Name='param4']='$_'" }) -join ' or '
    '<QueryList><Query Id="0" Path="System">' +
    "<Select Path=`"System`">*[System[Provider[@Name='Service Control Manager'] and EventID=7040]] and *[EventData[$serviceMatch]]</Select>" +
    "<Select Path=`"System`">*[System[Provider[@Name='Service Control Manager'] and EventID=7045]] and *[EventData[Data[@Name='ServiceName']='Microsoft Update Health Service']]</Select>" +
    '<Select Path="Microsoft-Windows-WindowsUpdateClient/Operational">*[System[(EventID=26 or EventID=44)]]</Select>' +
    '</Query></QueryList>'
}

function New-GuardEventTrigger {
    $class = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $trigger = New-CimInstance -CimClass $class -ClientOnly
    $trigger.Subscription = Get-GuardSubscription
    $trigger.Enabled = $true
    $trigger
}

function Get-GuardDescription([string]$Root) {
    'Owner requested persistent Windows OS update block. Reapplies at startup, every minute, and within seconds of an update-service start-type change. Undo: "{0}"' -f (Join-Path $Root 'Restore.ps1')
}
