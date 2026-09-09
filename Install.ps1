[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess) {
    throw 'Use 64-bit Windows PowerShell 5.1 (Desktop edition) on Windows. PowerShell 7 and 32-bit hosts are not supported.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this installer as administrator.' }
$root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WindowsUpdateBlock'
$taskName = 'WindowsUpdateBlock-Enforce'
$psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
if (Test-Path -LiteralPath $root) { throw "The installation directory already exists: $root. Review it before reinstalling." }
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'An enforcement task already exists; refusing to overwrite it.' }
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
$directory = [System.IO.Directory]::CreateDirectory($root,$acl)
if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The installation directory must not be a reparse point.' }
$actualAcl = Get-Acl -LiteralPath $root
if ($actualAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544' -or $actualAcl.GetSecurityDescriptorSddlForm('Access') -ne $acl.GetSecurityDescriptorSddlForm('Access')) { throw 'Installation directory permissions do not match the protected configuration.' }
if (@(Get-ChildItem -LiteralPath $root -Force).Count -ne 0) { throw 'The new installation directory must be empty.' }
Start-Transcript -Path (Join-Path $root 'install.log') | Out-Null
try {
    foreach ($fileName in @('UpdateBlock.ps1','Restore.ps1','Verify-Installed.ps1','README.md')) {
        $target = Join-Path $root $fileName
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $fileName) -Destination $target
        $fileAcl = Get-Acl -LiteralPath $target
        $fileAcl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        Set-Acl -LiteralPath $target -AclObject $fileAcl
        if ((Get-Acl -LiteralPath $target).GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544') { throw "Unexpected file owner: $target" }
    }
    $actionArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Enforce' -f (Join-Path $root 'UpdateBlock.ps1')
    $action = New-ScheduledTaskAction -Execute $psExe -Argument $actionArguments -WorkingDirectory $root
    $triggers = @((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)))
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $description = 'Owner requested persistent Windows OS update block. Reapplies at startup and every minute. Undo: "{0}"' -f (Join-Path $root 'Restore.ps1')
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings -Principal $taskPrincipal -Description $description | Out-Null
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddSeconds(55)
    do {
        Start-Sleep -Seconds 2
        $result = Get-ScheduledTaskInfo -TaskName $taskName
        $task = Get-ScheduledTask -TaskName $taskName
    } while (($task.State -eq 'Running' -or -not (Test-Path (Join-Path $root 'last-enforce.json'))) -and (Get-Date) -lt $deadline)
    if (Test-Path (Join-Path $root 'last-enforce.json')) { Get-Content -LiteralPath (Join-Path $root 'last-enforce.json') }
    $result | Select-Object LastRunTime,LastTaskResult,NextRunTime | Format-List
    # One-time cancellation only; deliberate user restarts are not continually intercepted.
    try {
        $abortOutput = & "$env:SystemRoot\System32\shutdown.exe" /a 2>&1
        "Pending-shutdown cancellation: $abortOutput"
    } catch { "Pending-shutdown cancellation returned: $($_.Exception.Message)" }
    if ($task.State -eq 'Running') {
        'VERIFICATION PENDING: enforcement is still running. Inspect last-enforce.json and LastTaskResult after completion.'
    } else {
        $reportPath=Join-Path $root 'last-enforce.json'
        if (-not (Test-Path $reportPath)) { throw "Enforcement produced no report. Task result: $($result.LastTaskResult)" }
        $report=Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        if ($result.LastTaskResult -ne 0 -or $report.Issues.Count -gt 0 -or -not $report.PrimaryUpdateServicesBlocked -or -not $report.AllPresentUpdateServicesBlocked -or -not $report.AllVisibleUpdateTasksDisabled) { throw 'Enforcement is incomplete. Inspect last-enforce.json for the exact remaining controls.' }
        'ENFORCEMENT VERIFIED: see last-enforce.json for the actual installed controls.'
    }
} finally { Stop-Transcript | Out-Null }
