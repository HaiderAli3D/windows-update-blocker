[CmdletBinding()]
param()
# Upgrades an existing installation in place. The upgrade never rewrites the original-settings backup;
# later enforcement only adds entries for newly covered settings.
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess) {
    throw 'Use 64-bit Windows PowerShell 5.1 (Desktop edition) on Windows. PowerShell 7 and 32-bit hosts are not supported.'
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this upgrade as administrator.' }
$root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WindowsUpdateBlock'
$taskName = 'WindowsUpdateBlock-Enforce'
$statePath = Join-Path $root 'original-state.clixml'
$reportPath = Join-Path $root 'last-enforce.json'
. (Join-Path $PSScriptRoot 'GuardTask.ps1')

if ($PSScriptRoot -eq $root) { throw 'Run the upgrade from the repository, not the installation directory.' }
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "No installation found at $root. Use Install.ps1." }
if (-not (Test-InstallDirectorySecurity $root)) { throw 'Installation directory permissions do not match the protected configuration, or it is a reparse point.' }
if (Test-Path -LiteralPath (Join-Path $root 'RESTORED.txt')) { throw 'This installation was restored. Review it instead of upgrading.' }
# Without the backup, enforcement would record already-blocked values as the originals.
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'Original settings backup is missing; refusing to upgrade.' }
$state = Import-Clixml -LiteralPath $statePath
if ($state.Version -ne 1 -or $state.Registry -isnot [System.Collections.IDictionary]) { throw 'Original settings backup has an unsupported format; refusing to upgrade.' }
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task -or $task.Principal.UserId -notin @('SYSTEM','S-1-5-18')) { throw 'The SYSTEM enforcement task is missing.' }
foreach ($fileName in $installedFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $fileName) -PathType Leaf)) { throw "Missing source file: $fileName" }
}

Start-Transcript -Path (Join-Path $root 'upgrade.log') -Append | Out-Null
$mutex = New-Object Threading.Mutex($false,'Global\WindowsUpdateBlock-Settings')
$locked = $false
try {
    Disable-ScheduledTask -TaskName $taskName | Out-Null
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
        if ((Get-Date) -ge $deadline) { throw 'The running enforcement did not finish; upgrade did not interrupt it. Retry later.' }
        Start-Sleep -Seconds 2
    }
    try { $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(60)) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another update-block operation is running. Retry after it finishes.' }
    Copy-InstalledFiles $PSScriptRoot $root
    $task = Get-ScheduledTask -TaskName $taskName
    # Keep the existing startup and repetition triggers; replace only the event trigger.
    $task.Triggers = @(@($task.Triggers | Where-Object { $_.CimClass.CimClassName -ne 'MSFT_TaskEventTrigger' }) + (New-GuardEventTrigger))
    $task.Settings.MultipleInstances = 'Queue'
    $task.Settings.Enabled = $true
    $task.Description = Get-GuardDescription $root
    Set-ScheduledTask -InputObject $task | Out-Null
    'Upgraded files and enforcement task.'
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    # Never leave the machine unguarded, including after a failed upgrade.
    if (-not (Get-ScheduledTask -TaskName $taskName).Settings.Enabled) { Enable-ScheduledTask -TaskName $taskName | Out-Null }
}

try {
    $started = Get-Date
    Start-ScheduledTask -TaskName $taskName
    $deadline = $started.AddSeconds(90)
    do {
        Start-Sleep -Seconds 2
        $report = if (Test-Path -LiteralPath $reportPath) { Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json } else { $null }
        $fresh = $report -and [datetimeoffset]::Parse($report.Time) -ge $started
        $running = (Get-ScheduledTask -TaskName $taskName).State -eq 'Running'
    } while ((-not $fresh -or $running) -and (Get-Date) -lt $deadline)
    if (-not $fresh) { throw 'Enforcement produced no fresh report after the upgrade.' }
    Get-Content -LiteralPath $reportPath
    $info = Get-ScheduledTaskInfo -TaskName $taskName
    $info | Select-Object LastRunTime,LastTaskResult,NextRunTime | Format-List
    if ($report.Issues.Count -gt 0 -or -not $report.PrimaryUpdateServicesBlocked -or -not $report.AllPresentUpdateServicesBlocked -or -not $report.AllVisibleUpdateTasksDisabled -or @($report.Policies | Where-Object {-not $_.Matches}).Count -gt 0) { throw 'Enforcement is incomplete. Inspect last-enforce.json for the exact remaining controls.' }
    'UPGRADE VERIFIED: see last-enforce.json for the actual installed controls.'
} finally { Stop-Transcript | Out-Null }
