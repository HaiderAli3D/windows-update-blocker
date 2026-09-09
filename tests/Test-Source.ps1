#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object 'System.Collections.Generic.List[string]'
$scripts = @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.ps1' -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })

# Parse source without dot-sourcing it: no service, registry, firewall, or task mutations.
foreach ($scriptFile in $scripts) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    foreach ($parseError in $parseErrors) {
        $failures.Add("$($scriptFile.Name):$($parseError.Extent.StartLineNumber): $($parseError.Message)")
    }
}

foreach ($name in @('Install.ps1','UpdateBlock.ps1','Restore.ps1','Verify-Installed.ps1','README.md','.gitignore')) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $name) -PathType Leaf)) { $failures.Add("Missing packaged file: $name") }
}

# Check the actual tracked manifest when git is available, including ignored files
# that might accidentally have been forced into an earlier commit.
if ((Test-Path -LiteralPath (Join-Path $repoRoot '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $tracked = @(& git -C $repoRoot ls-files)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the repository manifest.' }
    foreach ($path in $tracked) {
        if ($path -match '(?i)(\.(clixml|reg|log|pem|key|pfx|p12)$|(^|/)(last-[^/]+\.json|verification\.json|RESTORED\.txt|\.env(\..*)?)$)') {
            $failures.Add("Local runtime data or credential file is tracked: $path")
        }
    }
}

# Exercise the backup serialization boundary entirely in memory. Exact missing-
# value, registry kind and unexpanded string preservation are needed by restore.
$backup = @{
    Version = 1
    Registry = @{
        'sample|Start' = @{ Path='HKLM:\Example'; Name='Start'; Exists=$true; Value=[int]3; Kind='DWord' }
        'sample|Missing' = @{ Path='HKLM:\Example'; Name='Missing'; Exists=$false; Value=$null; Kind=$null }
        'sample|Path' = @{ Path='HKLM:\Example'; Name='Path'; Exists=$true; Value='%SystemRoot%\folder with spaces\$literal'; Kind='ExpandString' }
    }
    Tasks = @{ 'sample' = @{ Path='\Example\'; Name='Original'; Enabled=$false; Xml='<Task />' } }
    FirewallRules = @{ 'example-owned-rule' = $true }
}
$roundTrip = [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($backup,12))
if ($roundTrip.Registry['sample|Start'].Value -cne 3 -or $roundTrip.Registry['sample|Start'].Kind -cne 'DWord') { $failures.Add('Registry value/kind changed during backup serialization.') }
if ($roundTrip.Registry['sample|Missing'].Exists -or $null -ne $roundTrip.Registry['sample|Missing'].Value) { $failures.Add('Missing registry value did not survive backup serialization.') }
if ($roundTrip.Registry['sample|Path'].Value -cne $backup.Registry['sample|Path'].Value -or $roundTrip.Registry['sample|Path'].Kind -cne 'ExpandString') { $failures.Add('Unexpanded registry string changed during backup serialization.') }
if ($roundTrip.Tasks['sample'].Enabled -or -not $roundTrip.FirewallRules.ContainsKey('example-owned-rule')) { $failures.Add('Task/rule ownership state changed during backup serialization.') }

if ($failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
Write-Output "PASS: $($scripts.Count) PowerShell files parse; package manifest and backup serialization checks passed. No Windows settings changed."
