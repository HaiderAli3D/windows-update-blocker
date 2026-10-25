<div align="center">

# Windows Update Blocker

**Keep Windows Update on your schedule.**

Persistent, reversible Windows OS update blocking with PowerShell and built-in Windows tools.

[![Source checks](https://github.com/HaiderAli3D/windows-update-blocker/actions/workflows/validate.yml/badge.svg)](https://github.com/HaiderAli3D/windows-update-blocker/actions/workflows/validate.yml)
![Windows PowerShell 5.1](https://img.shields.io/badge/Windows_PowerShell-5.1-5391FE?logo=powershell&logoColor=white)
[![Tested baseline: Windows 11](https://img.shields.io/badge/Tested_baseline-Windows_11-0078D4)](#validation-and-limits)

[Install](#install) · [Check status](#check-status) · [Restore](#restore-windows-update) · [How it works](#how-it-works) · [Validation](#validation-and-limits)

</div>

> **Before you install:** this stops Windows security patches, feature updates, and drivers delivered through Windows Update. Review the scripts and keep the original settings backup. Persistence has no expiry, but future Windows repairs, reinstalls, or new update mechanisms can override it.

- **Automatic enforcement.** Reapplies the block at startup, every minute, and within seconds of anything re-enabling an update service.
- **No wake-ups.** Runs on battery without waking the computer.
- **Built-in undo.** Saves settings before changing them and restores them on request.
- **Visible results.** Reports actual service, task, policy, and firewall state locally.

## Install

You need **64-bit Windows PowerShell 5.1** (`powershell.exe`), administrator access, and working Task Scheduler and Windows Firewall services. PowerShell 7 (`pwsh`) and 32-bit hosts are rejected before changes begin. The original implementation was tested on **Windows 11 Home 25H2 x64**; other versions and architectures are unvalidated.

Open **Windows PowerShell as administrator**, then:

```powershell
git clone https://github.com/HaiderAli3D/windows-update-blocker.git
cd windows-update-blocker
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

You can also [download the ZIP](https://github.com/HaiderAli3D/windows-update-blocker/archive/refs/heads/main.zip), extract it, and run the last command from the extracted directory. The execution-policy override applies only to that process.

Installation creates `%ProgramData%\WindowsUpdateBlock` and the `WindowsUpdateBlock-Enforce` SYSTEM task. Only SYSTEM and Administrators can write to the installation directory. No reboot is required.

Install while Windows is not actively servicing an update. An existing installation directory or enforcement task stops installation to preserve its backup; see [troubleshooting](#troubleshooting).

### Upgrade an existing installation

To apply a newer version without losing the original-settings backup, run from the updated repository in an elevated Windows PowerShell window:

```powershell
git pull
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Upgrade.ps1
```

The upgrade refuses to run if the backup is missing, the installation was restored, or the directory permissions differ from the protected configuration. It pauses the guard, replaces the installed scripts, updates the guard task, and verifies a fresh enforcement report. `original-state.clixml` is never modified. The guard is re-enabled even if the upgrade fails.

## Check status

For a fresh **read-only** report, use an elevated Windows PowerShell window:

```powershell
$installRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WindowsUpdateBlock'
& (Join-Path $installRoot 'UpdateBlock.ps1') -Mode Verify
Get-ScheduledTaskInfo -TaskName 'WindowsUpdateBlock-Enforce'
```

Check the report's timestamp, `Issues`, and blocked service/task results. A completed guard run should have `LastTaskResult = 0`. The latest report from the SYSTEM task is saved as `%ProgramData%\WindowsUpdateBlock\last-enforce.json`.

<details>
<summary><strong>Advanced: test automatic enforcement</strong></summary>

From the repository or installation directory, run as administrator:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Verify-Installed.ps1
```

This is an **active integration test**. It attempts to start the disabled update service and expects Windows to reject it, switches Windows Update to manual start (as Windows Update clients do) and times how quickly the guard disables it again, temporarily disables one owned firewall rule, and waits for the guard to restore that rule. The update service is never started. It also inspects scheduling, the event trigger, effective firewall filters, enabled profiles, and the completed guard result.

Allow roughly two minutes. Results are saved to `%ProgramData%\WindowsUpdateBlock\verification.json`.

</details>

## Restore Windows Update

From the repository or installation directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Restore.ps1
```

The script requests administrator approval if needed, stops recurring enforcement, and starts restoration as SYSTEM. It restores saved registry settings, re-enables update tasks that were originally enabled, and removes its own firewall rules. It does not initiate an update scan or restart the PC. Restored service startup settings take effect on their next normal trigger or restart.

Check `%ProgramData%\WindowsUpdateBlock\last-restore.json` for completion and errors. Success creates `RESTORED.txt` and removes the guard task. Backups and logs remain available; missing original settings cause an error rather than guessed replacements.

## How it works

| Layer | Control |
| --- | --- |
| Services | Stops and disables Windows Update, Update Orchestrator, Medic, and Update Health services where present. |
| Tasks | Disables tasks in update, orchestration, assistant, and remediation folders, plus Microsoft Store app auto-update tasks, where permissions allow. |
| Firewall | Blocks outbound traffic for selected update service identities and executables, including relocated `uus` and Update Health Tools binaries. |
| Settings and policies | Stops device installation from searching Windows Update for drivers. Restricts automatic updates, Windows Update UI access, and Store auto-download, and sets a nonfunctional local update endpoint. |
| Guard | Reapplies controls at startup, every minute, and within seconds of an update-service start-type change or Windows Update client activity, with changes and failures recorded locally. |

<details>
<summary><strong>Implementation details and scope</strong></summary>

Service targets are `wuauserv`, `UsoSvc`, `WaaSMedicSvc`, and `uhssvc`. Windows Home ignores Windows Update policies, and third-party network filters (for example VPN threat protection) can let traffic through despite firewall rules. On Home, the disabled services, disabled tasks, and the guard are the effective block; reports include `IsHomeEdition` to make this explicit. Available services, tasks, and firewall rules vary by Windows installation.

Any program that uses the Windows Update API with administrator or SYSTEM rights, including the Microsoft Store and Store-installed apps checking for updates, switches `wuauserv` from disabled to manual start. Windows logs this as System event 7040, and the guard's event trigger disables the service again within seconds. Overlapping triggers are queued, not dropped. The guard's own correction logs one more 7040, which causes one extra run that changes nothing. Windows Update Medic can start without such an event; the one-minute timer covers it.

Store app auto-update tasks are disabled, except `RestoreDevice`, which restores apps on new devices. Store and winget installs that depend on Windows Update may fail or need a retry while the blocker is active.

The installer attempts to cancel a queued shutdown once. Intentional restarts are not continually intercepted. BITS, Delivery Optimization, Defender, Microsoft Store services, browsers, and third-party updaters are not disabled. Defender security intelligence updates continue through their own fallback source.

The scripts preserve servicing files, update caches, pending-reboot markers, and existing tasks. They do not change system service or file ownership to bypass Windows protections. Installation uses a protected directory; enforcement and restoration share a mutex to prevent simultaneous changes.

</details>

<details>
<summary><strong>Files, backups, and privacy</strong></summary>

| File | Purpose |
| --- | --- |
| [`Install.ps1`](Install.ps1) | Creates the protected installation and SYSTEM task. |
| [`Upgrade.ps1`](Upgrade.ps1) | Upgrades an existing installation while keeping its backup. |
| [`UpdateBlock.ps1`](UpdateBlock.ps1) | Enforces controls, reports status, and restores saved settings. |
| [`GuardTask.ps1`](GuardTask.ps1) | Shared guard trigger, update program list, and installation-directory definitions. |
| [`Restore.ps1`](Restore.ps1) | Starts restoration with SYSTEM privileges. |
| [`Verify-Installed.ps1`](Verify-Installed.ps1) | Tests an installed blocker's behavior. |
| [`tests/Test-Source.ps1`](tests/Test-Source.ps1) | Validates source without changing Windows settings. |

Runtime data stays in `%ProgramData%\WindowsUpdateBlock`: `original-state.clixml`, JSON reports, `install.log`, `upgrade.log`, and activity logs. Reports and backups can contain machine details. They are excluded by `.gitignore`; review and redact them before sharing an issue. Keep `original-state.clixml` for restoration.

</details>

## Validation and limits

The **original installed implementation** passed live checks on Windows 11 Home 25H2 x64: Windows rejected a service start with error `1058`, a completed guard returned `0`, and the guard automatically restored a changed firewall rule.

The event-driven guard was applied to that installation with `Upgrade.ps1` and passed `Verify-Installed.ps1`. A switch of Windows Update to manual start was reversed in 2.1 seconds, where the timer alone took up to a minute.

**CI validates source only.** The current version has not completed a fresh-machine install, full restore cycle, reboot test, or overnight test. The badge above reflects that source workflow. A Windows VM with a snapshot is appropriate for integration testing.

The guard has a short timing window of a few seconds after an update service is re-enabled. No software can promise that Windows never updates. These are outside the guarantee:
- updates Windows staged before installation, which complete at the next restart
- Windows reset, repair, or reinstall
- feature upgrades you run yourself from install media or the Installation Assistant
- vendor updaters for drivers and firmware
- network filters that override firewall rules
- disabled supporting services, crashes, power loss, and restarts initiated by people or other software

Failed protected operations appear in reports.

To run the same safe source checks as CI:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Source.ps1
```

## Troubleshooting

<details>
<summary><strong>Installation stopped, reports look incomplete, or restore needs attention</strong></summary>

- **Existing installation:** inspect its reports and backup first. Do not delete the backup to bypass the installer's check. Restore the existing installation before preparing a new one.
- **Task result `267009` (`0x41301`):** the guard was running when queried. Check again after it finishes; use the completed task result.
- **Incomplete report:** use an elevated shell so protected tasks are visible, then inspect `Issues` in the latest SYSTEM-run report. Registration of the guard alone does not prove every control succeeded.
- **Firewall verification failure:** check that all three firewall profiles are enabled and inspect the reported rule/filter mismatch. Policies managed by an organization may affect effective settings.
- **Restore errors:** inspect `last-restore.json`. On a reported restoration failure, recurring enforcement remains disabled and the backup remains available for retry or manual recovery.

</details>

For bug reports, include your Windows edition/version, PowerShell version, and the relevant **redacted** error. Run source checks before proposing a change; never run installer or integration scripts as routine CI on a shared machine.

<details>
<summary><strong>Microsoft reference documentation</strong></summary>

[Update policies](https://learn.microsoft.com/en-us/windows/deployment/update/waas-wu-settings) · [Edition applicability](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-update#allowautoupdate) · [Restart behavior](https://learn.microsoft.com/en-us/windows/deployment/update/waas-restart) · [Firewall rules](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/configure) · [Update repair components](https://support.microsoft.com/en-us/servicing/os/windows-10/2020/11/kb4023057-update-health-tools-windows-update-service-components)

</details>
