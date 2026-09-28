[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Refuse to install/uninstall on an ordinary user's desktop.
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows') {
    throw 'Disposable GitHub-hosted Windows runner required. No installation was attempted.'
}
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell to inspect the requested registry views.' }

$packageUrl = 'https://vonncore-installer-downloads.onrender.com/windows/v0.3.0-d7b193716e49/Vonncore_0.3.0_x64-setup.exe'
$expectedHash = 'c502e107579e3c0a40ae4b733431bd7101b41b6d16f262c1aa8397784803235f'
$expectedBytes = 240723416
$installDirectory = Join-Path $env:LOCALAPPDATA 'Vonncore'
$installedExe = Join-Path $installDirectory 'vongcore.exe'
$uninstaller = Join-Path $installDirectory 'uninstall.exe'
$registryRoots = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$fields = @('DisplayName','Publisher','DisplayVersion','InstallLocation','UninstallString','QuietUninstallString','SystemComponent')
[void](New-Item -ItemType Directory -Path $EvidenceDirectory -Force)
$report = [ordered]@{
    status = 'RUNNING'
    startedAt = [DateTime]::UtcNow.ToString('o')
    sourceRun = '36356178830'
    sourceCommit = 'd7b193716e49fe46d1c8e0d7bd3576ce2485d5ac'
    packageUrl = $packageUrl
    expectedSha256 = $expectedHash
    expectedBytes = $expectedBytes
    runner = @{ os = [Environment]::OSVersion.VersionString; image = $env:ImageOS; imageVersion = $env:ImageVersion; runId = $env:GITHUB_RUN_ID }
    interactiveSilence = 'NOT_OBSERVED: a hosted runner does not prove absence of installer UI or UAC.'
    checks = @()
}

function Save-Json([string]$Name, $Value) {
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory $Name) -Encoding utf8
}
function Assert-Check([string]$Name, [bool]$Condition, $Details) {
    $report.checks += [ordered]@{ name = $Name; passed = $Condition; details = $Details }
    Save-Json 'result.json' $report
    if (-not $Condition) { throw "Check failed: $Name. See result.json for exact evidence." }
}
function Read-UninstallEntries {
    $entries = @()
    foreach ($root in $registryRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root)) {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath
            $entry = [ordered]@{ key = "$root\$($key.PSChildName)" }
            foreach ($field in $fields) {
                $property = $properties.PSObject.Properties[$field]
                $entry[$field] = if ($null -eq $property) { $null } else { $property.Value }
            }
            $entries += [pscustomobject]$entry
        }
    }
    return @($entries | Sort-Object key)
}
function Compare-Entries($Before, $After) {
    $beforeMap = @{}; $afterMap = @{}
    foreach ($entry in @($Before)) { $beforeMap[$entry.key] = $entry }
    foreach ($entry in @($After)) { $afterMap[$entry.key] = $entry }
    $added = @($After | Where-Object { -not $beforeMap.ContainsKey($_.key) })
    $removed = @($Before | Where-Object { -not $afterMap.ContainsKey($_.key) })
    $changed = @()
    foreach ($entry in @($Before)) {
        if ($afterMap.ContainsKey($entry.key)) {
            $oldJson = ConvertTo-Json -InputObject $entry -Compress
            $newJson = ConvertTo-Json -InputObject $afterMap[$entry.key] -Compress
            if ($oldJson -cne $newJson) { $changed += @{ before = $entry; after = $afterMap[$entry.key] } }
        }
    }
    return @{ added = $added; removed = $removed; changed = $changed }
}
function File-Evidence([string]$Path) {
    $file = Get-Item -LiteralPath $Path
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    return [ordered]@{
        bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        productVersion = $file.VersionInfo.ProductVersion
        signatureStatus = [string]$signature.Status
        publisherSubject = if ($null -ne $signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }
        timestamped = $null -ne $signature.TimeStamperCertificate
    }
}
function Has-ExpectedSignature($Evidence) {
    return $Evidence.signatureStatus -eq 'Valid' -and $Evidence.timestamped -and $Evidence.publisherSubject -match '(^|,\s*)CN=WORKFLOWOS LLC(,|$)'
}
function Run-Bounded([string]$Phase, [string]$FilePath, [string]$Arguments) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    # Do not hide installer windows; no-UI evidence must be observed separately.
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru
    $null = $process.Handle
    $completed = $process.WaitForExit(300000)
    $watch.Stop()
    $details = @{ executable = $FilePath; arguments = $Arguments; elapsedSeconds = $watch.Elapsed.TotalSeconds; completed = $completed; processId = $process.Id; exitCode = $null }
    if ($completed) { $details.exitCode = $process.ExitCode }
    $report[$Phase] = $details
    Assert-Check "$Phase-completed-within-300-seconds" $completed $details
    Assert-Check "$Phase-exit-code-zero" ($details.exitCode -eq 0) $details
}

try {
    $before = @(Read-UninstallEntries)
    Save-Json 'uninstall-entries-before.json' $before
    $existing = @($before | Where-Object { $_.DisplayName -match '(?i)vonncore|vongcore' })
    Assert-Check 'no-preexisting-vonncore' ($existing.Count -eq 0 -and -not (Test-Path -LiteralPath $installDirectory)) @{ existingEntries = $existing; installDirectoryExists = (Test-Path -LiteralPath $installDirectory) }

    $downloadDirectory = Join-Path $env:RUNNER_TEMP ('exact-installer-' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $downloadDirectory)
    $installer = Join-Path $downloadDirectory 'Vonncore_0.3.0_x64-setup.exe'
    $response = Invoke-WebRequest -Uri $packageUrl -OutFile $installer -PassThru -MaximumRedirection 0 -TimeoutSec 300
    Assert-Check 'anonymous-direct-http-200' ($response.StatusCode -eq 200) @{ status = $response.StatusCode }
    $candidate = File-Evidence $installer
    $report.candidate = $candidate
    Assert-Check 'exact-candidate-bytes' ($candidate.bytes -eq $expectedBytes -and $candidate.sha256 -ceq $expectedHash) $candidate
    Assert-Check 'candidate-signature-and-version' ((Has-ExpectedSignature $candidate) -and $candidate.productVersion -eq '0.3.0') $candidate

    Run-Bounded 'install' $installer '/S'
    $afterInstall = @(Read-UninstallEntries)
    Save-Json 'uninstall-entries-after-install.json' $afterInstall
    $installDelta = Compare-Entries $before $afterInstall
    $report.installRegistryDelta = $installDelta
    Assert-Check 'baseline-entries-preserved-during-install' ($installDelta.removed.Count -eq 0 -and $installDelta.changed.Count -eq 0) $installDelta
    Assert-Check 'exactly-one-new-uninstall-entry' ($installDelta.added.Count -eq 1) $installDelta.added
    $entry = $installDelta.added[0]
    $report.vonncoreEntry = $entry
    Assert-Check 'exact-vonncore-registry-identity' ($entry.DisplayName -ceq 'Vonncore' -and $entry.Publisher -ceq 'WORKFLOWOS LLC' -and $entry.DisplayVersion -ceq '0.3.0') $entry
    Assert-Check 'vonncore-entry-not-hidden' ($entry.SystemComponent -ne 1) $entry
    Assert-Check 'installed-executable-present' (Test-Path -LiteralPath $installedExe -PathType Leaf) $installedExe
    $installedEvidence = File-Evidence $installedExe
    Assert-Check 'installed-executable-version-and-signature' ((Has-ExpectedSignature $installedEvidence) -and $installedEvidence.productVersion -eq '0.3.0') $installedEvidence

    Assert-Check 'installed-uninstaller-present' (Test-Path -LiteralPath $uninstaller -PathType Leaf) $uninstaller
    $uninstallerEvidence = File-Evidence $uninstaller
    Assert-Check 'installed-uninstaller-signature' (Has-ExpectedSignature $uninstallerEvidence) $uninstallerEvidence
    $recordedUninstaller = $null
    if ($entry.UninstallString -match '^\s*"([^\"]+\.exe)"(?:\s|$)') { $recordedUninstaller = $Matches[1] }
    elseif ($entry.UninstallString -match '^\s*(.+?\.exe)(?:\s|$)') { $recordedUninstaller = $Matches[1] }
    Assert-Check 'recorded-uninstaller-matches-vonncore-path' ($null -ne $recordedUninstaller -and $recordedUninstaller -ieq $uninstaller) @{ recorded = $entry.UninstallString; expected = $uninstaller }

    Run-Bounded 'uninstall' $uninstaller ('/S _?=' + $installDirectory)
    $afterUninstall = @(Read-UninstallEntries)
    Save-Json 'uninstall-entries-after-uninstall.json' $afterUninstall
    $uninstallDelta = Compare-Entries $before $afterUninstall
    $report.finalRegistryDelta = $uninstallDelta
    Assert-Check 'installed-executable-removed' (-not (Test-Path -LiteralPath $installedExe)) $installedExe
    Assert-Check 'vonncore-uninstall-entry-removed' (@($afterUninstall | Where-Object { $_.key -eq $entry.key -or $_.DisplayName -match '(?i)vonncore|vongcore' }).Count -eq 0) $entry.key
    Assert-Check 'baseline-apps-preserved-and-no-extra-entries' ($uninstallDelta.added.Count -eq 0 -and $uninstallDelta.removed.Count -eq 0 -and $uninstallDelta.changed.Count -eq 0) $uninstallDelta
    $report.status = 'AUTOMATED_CHECKS_PASS_INTERACTIVE_CHECK_PENDING'
} catch {
    $report.status = 'FAILED_OR_BLOCKED'
    $report.failure = $_.Exception.Message
    try { Save-Json 'uninstall-entries-at-stop.json' @(Read-UninstallEntries) } catch { $report.evidenceCollectionFailure = $_.Exception.Message }
} finally {
    $report.finishedAt = [DateTime]::UtcNow.ToString('o')
    Save-Json 'result.json' $report
    Write-Output $report.status
    if ($env:GITHUB_STEP_SUMMARY) {
        @("## Exact candidate diagnostic", "Result: $($report.status)", 'Interactive no-UI/UAC behavior remains unobserved. This is not a full Microsoft reproduction PASS.', 'See result.json and registry snapshots in the evidence artifact.') | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
    }
}
if ($report.status -ne 'AUTOMATED_CHECKS_PASS_INTERACTIVE_CHECK_PENDING') { exit 1 }
