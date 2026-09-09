# Windows Update Blocker

Persistent, reversible blocking of Windows OS updates and their automatic restart workflow, using PowerShell and built-in Windows tools.

The blocker runs at startup and every minute with no expiry. It saves original settings before changing them and includes status reporting, an integration check, and an undo script.

**Disabling Windows Update stops Windows security patches, feature updates, and drivers delivered through Windows Update.** This is a local workaround, not a guarantee against every future Windows repair, reinstall, or new updater mechanism. Review the scripts before running them.

## Requirements

- Windows with **64-bit Windows PowerShell 5.1** (`powershell.exe`), not PowerShell 7 (`pwsh`).
- Administrator access to install, inspect protected tasks, and restore settings.
- Task Scheduler and Windows Firewall available and enabled.
- Initial live verification used Windows 11 Home 25H2 on x64. Other Windows versions and architectures have not been validated.

Windows Home does not have the documented Pro edition policy guarantees. Service and scheduled-task controls provide the primary block; the registry policies add another layer.

## Install

Clone or download the repository, review its scripts, then open **Windows PowerShell as administrator** in the repository directory:

```powershell
git clone https://github.com/HaiderAli3D/windows-update-blocker.git
cd windows-update-blocker
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

The execution-policy override applies only to that PowerShell process. If using a downloaded ZIP, extract its contents before running the installer.

The installer creates `%ProgramData%\WindowsUpdateBlock` and the `WindowsUpdateBlock-Enforce` scheduled task. The installation directory permits writes only by SYSTEM and Administrators; ordinary users can read the scripts and reports. The task runs as SYSTEM at startup and every minute, including on battery, without waking the computer. No reboot is required.

An existing installation directory or task causes installation to stop rather than overwrite its backup. Do not run the installer against an active Windows servicing operation or delete a previous installation's backup to get past this check.

## What it changes

| Layer | Changes |
| --- | --- |
| Services | Stops and disables `wuauserv`, `UsoSvc`, `WaaSMedicSvc`, and `uhssvc` where present. |
| Scheduled tasks | Disables tasks in Windows Update, Update Orchestrator, Medic, Update Assistant, and remediation folders where permissions allow. |
| Network | Adds outbound blocks scoped to update service identities and update executables. |
| Policies | Disables automatic updates, restricts Windows Update UI access, excludes update-delivered drivers, and configures a nonfunctional local update endpoint. |
| Enforcement | Reapplies these settings every minute and at startup, recording failures and changes. |

The installer also attempts to cancel an already queued shutdown once. It does not continuously cancel intentional restarts.

BITS, Delivery Optimization, Defender, Microsoft Store services, browsers, and third-party updaters are not disabled. Store installations and Defender update paths that depend on Windows Update can nevertheless be affected. The scripts do not delete servicing files, update caches, pending-reboot markers, or existing scheduled tasks, and do not change system service/file ownership to bypass protections.

## Check status

The latest SYSTEM-run report is `%ProgramData%\WindowsUpdateBlock\last-enforce.json`. Its timestamp, issues, service states, and task states matter; registration of the guard alone does not prove that the block works.

For a fresh **read-only** report, run in an elevated Windows PowerShell window:

```powershell
$installRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WindowsUpdateBlock'
& (Join-Path $installRoot 'UpdateBlock.ps1') -Mode Verify
Get-ScheduledTaskInfo -TaskName 'WindowsUpdateBlock-Enforce'
```

A completed guard run should return `LastTaskResult = 0`. A report written from inside a running guard may show `267009` (`0x41301`, task running); check the completed task separately. A non-elevated query may omit protected tasks.

### Optional integration check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Verify-Installed.ps1
```

This is an **active test**, not a read-only status query. It checks that Windows rejects starting the disabled update service, briefly disables one of the blocker's own firewall rules while the update services remain disabled, and waits for the scheduled guard to restore that rule. It also checks scheduling, rule filters, firewall profiles, and the completed guard result. Allow roughly two minutes. Results are written to `%ProgramData%\WindowsUpdateBlock\verification.json`.

## Restore Windows Update

From the repository or installed folder, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Restore.ps1
```

The script requests administrator approval if needed and starts restoration as SYSTEM. It disables the enforcement task, removes only the firewall rules it created, restores the registry values it changed, and re-enables update tasks that were originally enabled. It does not trigger an update scan or restart the PC. Restored service startup settings apply on their next normal trigger or next restart.

Inspect `%ProgramData%\WindowsUpdateBlock\last-restore.json` for completion and errors. Successful restoration creates `RESTORED.txt` and removes the guard task. Backups and logs remain available. If restoration fails, the guard remains disabled and the backup remains available for retry or manual recovery. Missing original settings are an error; the scripts do not guess replacements.

## Files and local data

| File | Purpose |
| --- | --- |
| `Install.ps1` | Creates the protected installation and SYSTEM task. |
| `UpdateBlock.ps1` | Applies controls, reports status, and restores backed-up settings. |
| `Restore.ps1` | Starts restoration with the same SYSTEM privileges. |
| `Verify-Installed.ps1` | Explicit integration test of an installed blocker. |
| `tests/Test-Source.ps1` | Source checks that do not install the blocker or change Windows settings. |

Runtime data stays in `%ProgramData%\WindowsUpdateBlock`: `original-state.clixml`, `last-enforce.json`, `last-restore.json`, `verification.json`, `install.log`, and activity logs. These can contain machine details and are excluded by `.gitignore`. Review and redact reports before sharing them in an issue.

## Validation and limits

The original installed implementation was exercised on Windows 11 Home 25H2 x64: the update service rejected a start request with error 1058, a completed guard returned 0, and a deliberately changed firewall rule was restored automatically. Three services, 17 update tasks, and six firewall rules were observed on that machine; counts vary by installation.

This repository includes subsequent portability and validation changes. Its CI performs source checks only. Those changes have not yet undergone a fresh-machine installation, full restore cycle, reboot test, or overnight test. A Windows VM with a snapshot is appropriate for those checks; do not run installation or integration scripts as part of routine CI on a shared machine.

The periodic guard has a timing window. Already-staged servicing, power loss, crashes, deliberate restarts, third-party restarts, disabled supporting services, or future Windows repair/install operations are outside a permanent guarantee. Protected operations that fail are reported rather than silently treated as successful.

To run the same source validation as CI:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Source.ps1
```

## Microsoft documentation

- [Windows Update policy and registry settings](https://learn.microsoft.com/en-us/windows/deployment/update/waas-wu-settings)
- [Update policy edition applicability](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-update#allowautoupdate)
- [Restart policy limitations](https://learn.microsoft.com/en-us/windows/deployment/update/waas-restart)
- [Service-scoped Windows Firewall rules](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/configure)
- [Windows Update repair components](https://support.microsoft.com/en-us/servicing/os/windows-10/2020/11/kb4023057-update-health-tools-windows-update-service-components)
