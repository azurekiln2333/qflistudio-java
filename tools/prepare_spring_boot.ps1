<#
.SYNOPSIS
Materialises the Java EE offline packs from their frozen lock files.

.DESCRIPTION
This script is a thin forwarder. The real recipe is
tools/prepare_javaee_packs.py, which:

  - treats tools/spring_boot.lock.json and tools/javaee8.lock.json as the only
    source of truth, so normal preparation reconstructs exactly the frozen
    artifacts and resolves no version;
  - fetches a file only when the lock names it and disk does not already hold it;
  - writes manifest.json and manifest.hashed.json from the lock;
  - extracts every recorded licence document and records its digest.

Two recipes would drift, so this script does not implement a second one.

.PARAMETER Refresh
Resolves versions freshly and writes a candidate lock for review. This is the
only operation that reads maven-metadata.xml, and it never modifies the live
lock. Cannot be combined with -VerifyOnly or -VerifyDigests.

.EXAMPLE
pwsh ./tools/prepare_spring_boot.ps1
pwsh ./tools/prepare_spring_boot.ps1 -Packs javaee8 -VerifyOnly
pwsh ./tools/prepare_spring_boot.ps1 -Packs all -Refresh
#>
[CmdletBinding()]
param(
    # Which packs to prepare. 'all' covers spring-boot and javaee8.
    [ValidateSet('all', 'spring-boot', 'javaee8')]
    [string]$Packs = 'all',

    # Check present files read-only and write nothing.
    [switch]$VerifyOnly,

    # Resolve versions freshly and write a candidate lock for review.
    [switch]$Refresh,

    # Cross-check every artifact against the repository's published digest.
    [switch]$VerifyDigests,

    # Foreground seconds for the whole run.
    [int]$Budget = 85
)

$ErrorActionPreference = 'Stop'

$script = Join-Path $PSScriptRoot 'prepare_javaee_packs.py'
if (-not (Test-Path -LiteralPath $script)) {
    throw "Recipe not found: $script"
}

$arguments = @($script, '--packs', $Packs, '--budget', "$Budget")
if ($VerifyOnly) { $arguments += '--verify-only' }
if ($Refresh) { $arguments += '--refresh' }
if ($VerifyDigests) { $arguments += '--verify-digests' }

Write-Host "Forwarding to prepare_javaee_packs.py ($Packs)"
& python @arguments
exit $LASTEXITCODE