<#
.SYNOPSIS
Downloads and verifies the pinned Spring Boot dependency set used by the
QFLIJVMX Spring Boot template and by the HarmonyOS feasibility probe.

.DESCRIPTION
Reads tools/spring_boot.lock.json (the source of truth) and fetches every
recorded artifact from Maven Central, verifying each file's SHA-256 before it is
accepted. Artifacts already present and matching are reused, so the script is
idempotent. A hash mismatch aborts the run; a partially downloaded file is never
left in place.

The output directory is ignored by Git. Only the lock file and this script are
tracked, mirroring how native/openjdk pins its recipe inputs.

.EXAMPLE
pwsh ./tools/prepare_spring_boot.ps1
pwsh ./tools/prepare_spring_boot.ps1 -OutputDirectory build/spring_boot
#>
[CmdletBinding()]
param(
    # Where verified JARs are written. Defaults to the in-repo asset directory so
    # desktop runs can read them directly; the mobile packaging step copies from
    # here into the app's assets.
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../assets/spring_boot'),

    # Maven Central mirror. Override for a different mirror when needed.
    [string]$Repository = 'https://repo1.maven.org/maven2',

    # Verify hashes but fetch nothing (used to check a prepared directory).
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'

$lockPath = Join-Path $PSScriptRoot 'spring_boot.lock.json'
if (-not (Test-Path -LiteralPath $lockPath)) {
    throw "Lock file not found: $lockPath"
}

$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
if (-not $lock.version -or -not $lock.artifacts) {
    throw "Lock file is malformed: $lockPath"
}

$target = Join-Path $OutputDirectory $lock.version
Write-Host "Spring Boot $($lock.version) -> $target"
Write-Host "Artifacts: $($lock.artifacts.Count), repository: $Repository"

if (-not $VerifyOnly) {
    New-Item -ItemType Directory -Force -Path $target | Out-Null
}

$downloaded = 0
$reused = 0
$totalBytes = 0

foreach ($artifact in $lock.artifacts) {
    $destination = Join-Path $target $artifact.file
    $expected = $artifact.sha256.ToLower()

    if (Test-Path -LiteralPath $destination) {
        $actual = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLower()
        if ($actual -eq $expected) {
            $reused++
            $totalBytes += (Get-Item -LiteralPath $destination).Length
            continue
        }
        Write-Host "  replacing mismatched $($artifact.file)"
        Remove-Item -LiteralPath $destination -Force
    }

    if ($VerifyOnly) {
        throw "Missing artifact: $($artifact.file)"
    }

    $uri = "$Repository/$($artifact.mavenPath)"
    $partial = "$destination.partial"
    try {
        Invoke-WebRequest -Uri $uri -OutFile $partial -UseBasicParsing -TimeoutSec 300
        $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $expected) {
            throw "SHA-256 mismatch for $($artifact.file) from $uri`nexpected: $expected`nactual:   $actual"
        }
        Move-Item -LiteralPath $partial -Destination $destination -Force
        $downloaded++
        $totalBytes += (Get-Item -LiteralPath $destination).Length
        Write-Host "  fetched $($artifact.file)"
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}

Write-Host ''
Write-Host "Verified $($lock.artifacts.Count) artifacts: $downloaded fetched, $reused reused."
Write-Host "Total size: $([math]::Round($totalBytes / 1MB, 2)) MB"

# The Flutter asset layer cannot enumerate a directory on every platform, so the
# authoritative file list is written next to the JARs and read by
# lib/spring_boot_bundle.dart. Regenerating it here keeps it in step with the
# lock file instead of letting the two drift.
if (-not $VerifyOnly) {
    $manifestPath = Join-Path $target 'manifest.json'
    $names = $lock.artifacts | ForEach-Object { $_.file } | Sort-Object
    $json = ConvertTo-Json -InputObject @($names) -Depth 2
    [IO.File]::WriteAllText($manifestPath, $json, [Text.UTF8Encoding]::new($false))
    Write-Host "Manifest: $manifestPath ($($names.Count) entries)"
}

Write-Host "Ready at: $target"
