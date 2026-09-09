[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess) {
    throw 'Use 64-bit Windows PowerShell 5.1 (Desktop edition) on Windows. PowerShell 7 and 32-bit hosts are not supported.'
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $quotedPath = '"' + $PSCommandPath + '"'
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File $quotedPath"
    exit
}
$taskName = 'WindowsUpdateBlock-Enforce'
$root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WindowsUpdateBlock'
$psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task) { throw 'Enforcement task is missing. Review the saved state before restoring manually.' }
Disable-ScheduledTask -TaskName $taskName | Out-Null
$deadline=(Get-Date).AddMinutes(3)
while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
    if ((Get-Date) -ge $deadline) { throw 'The existing run has not finished; restore did not interrupt it. Retry later.' }
    Start-Sleep -Seconds 2
}
$actionArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Restore' -f (Join-Path $root 'UpdateBlock.ps1')
$action=New-ScheduledTaskAction -Execute $psExe -Argument $actionArguments -WorkingDirectory $root
# Retain SYSTEM rights so protected tasks are restored under the same identity.
$task.Actions=@($action)
$task.Triggers=@()
$task.Settings.Enabled=$true
Set-ScheduledTask -InputObject $task | Out-Null
Start-ScheduledTask -TaskName $taskName
