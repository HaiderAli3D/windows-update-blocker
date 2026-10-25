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
. (Join-Path $PSScriptRoot 'GuardTask.ps1')
$null = [System.IO.Directory]::CreateDirectory($root,(New-InstallDirectorySecurity))
if (-not (Test-InstallDirectorySecurity $root)) { throw 'Installation directory permissions do not match the protected configuration, or it is a reparse point.' }
if (@(Get-ChildItem -LiteralPath $root -Force).Count -ne 0) { throw 'The new installation directory must be empty.' }
Start-Transcript -Path (Join-Path $root 'install.log') | Out-Null
try {
    Copy-InstalledFiles $PSScriptRoot $root
    $actionArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Enforce' -f (Join-Path $root 'UpdateBlock.ps1')
    $action = New-ScheduledTaskAction -Execute $psExe -Argument $actionArguments -WorkingDirectory $root
    $triggers = @((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)),(New-GuardEventTrigger))
    # Queue, not IgnoreNew: a service flip during a run must still be corrected right after it.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances Queue -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $description = Get-GuardDescription $root
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
