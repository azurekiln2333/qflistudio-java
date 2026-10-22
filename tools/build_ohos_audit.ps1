[CmdletBinding()]
param(
    [string]$Target = 'tools/java_catalog_ohos_smoke.dart',
    [string]$LogPath = 'build/java-ohos-audit-build.log',
    [string]$ReportPath = 'build/java-ohos-audit-build.json'
)

# Build an emulator HAP without changing the production ARM64 selection.
# Run this script from a PowerShell process that owns the exclusive Java build
# window. It never installs, starts, stops, or resets a device or emulator.
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$profilePath = Join-Path $projectRoot 'ohos/entry/build-profile.json5'
$buildDirectory = Join-Path $projectRoot 'build'
[IO.Directory]::CreateDirectory($buildDirectory) | Out-Null

function Resolve-ProjectPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $projectRoot $Path))
}

function Get-ByteHash([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-EntryHash($Entry) {
    $stream = $Entry.Open()
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

function Replace-One([string]$Text, [string]$Pattern, [string]$Replacement) {
    if ([regex]::Matches($Text, $Pattern).Count -ne 1) {
        throw "The production profile no longer has exactly one expected setting: $Pattern"
    }
    return [regex]::Replace($Text, $Pattern, $Replacement)
}

function Inspect-Hap([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $nativeEntries = @($archive.Entries | Where-Object { $_.FullName -match '^libs/[^/]+/[^/]+\.so$' })
        $wrongAbi = @($nativeEntries | Where-Object { $_.FullName -notmatch '^libs/x86_64/' })
        if ($nativeEntries.Count -eq 0 -or $wrongAbi.Count -ne 0) {
            throw 'The HAP must contain only x86_64 native libraries.'
        }
        foreach ($entry in $nativeEntries) {
            $stream = $entry.Open()
            try {
                $header = New-Object byte[] 20
                $read = 0
                while ($read -lt $header.Length) {
                    $count = $stream.Read($header, $read, $header.Length - $read)
                    if ($count -eq 0) { break }
                    $read += $count
                }
                if ($read -ne 20 -or $header[0] -ne 127 -or $header[1] -ne 69 -or
                    $header[2] -ne 76 -or $header[3] -ne 70 -or $header[4] -ne 2 -or
                    $header[5] -ne 1 -or [BitConverter]::ToUInt16($header, 18) -ne 62) {
                    throw "The HAP contains a native file that is not ELF64 x86_64: $($entry.FullName)"
                }
            }
            finally { $stream.Dispose() }
        }
        $stagedLibraries = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'ohos/entry/libs/x86_64') -Filter '*.so')
        foreach ($library in $stagedLibraries) {
            if (@($nativeEntries | Where-Object { $_.FullName -eq "libs/x86_64/$($library.Name)" }).Count -ne 1) {
                throw "A staged JDK library is missing from the HAP: $($library.Name)"
            }
        }
        $assets = @()
        foreach ($extension in @('json', 'zip')) {
            $assetName = "jdk-x86_64.$extension"
            $entries = @($archive.Entries | Where-Object { $_.FullName -match "/$([regex]::Escape($assetName))$" })
            if ($entries.Count -ne 1) { throw "Expected one packaged $assetName; found $($entries.Count)." }
            $packagedHash = Get-EntryHash $entries[0]
            $stagedPath = Join-Path $projectRoot "ohos/entry/src/main/resources/rawfile/$assetName"
            $stagedHash = (Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($packagedHash -ne $stagedHash) { throw "Packaged $assetName differs from its staged source." }
            $assets += [ordered]@{ path = $entries[0].FullName; bytes = $entries[0].Length; sha256 = $packagedHash }
        }
        if (@($archive.Entries | Where-Object { $_.FullName -match '/jdk-arm64-v8a\.(json|zip)$' }).Count -ne 0) {
            throw 'The emulator HAP unexpectedly includes ARM64 JDK data.'
        }
        return [ordered]@{
            path = $Path
            bytes = (Get-Item -LiteralPath $Path).Length
            sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
            signedOutput = $Path -match '-signed\.hap$'
            abi = 'x86_64'
            verifiedElfCount = $nativeEntries.Count
            stagedJdkLibraryCount = $stagedLibraries.Count
            jdkAssets = $assets
        }
    }
    finally { $archive.Dispose() }
}

$logFullPath = Resolve-ProjectPath $LogPath
$reportFullPath = Resolve-ProjectPath $ReportPath
foreach ($path in @($logFullPath, $reportFullPath)) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
}
$targetFullPath = Resolve-ProjectPath $Target
if (-not (Test-Path -LiteralPath $targetFullPath -PathType Leaf)) { throw "Target does not exist: $Target" }
$flutter = (Get-Command flutter -ErrorAction Stop).Source
$lockPath = Join-Path $buildDirectory '.ohos-audit-build.lock'
$lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$originalBytes = $null
$hadJavaOptions = Test-Path Env:JAVA_TOOL_OPTIONS
$oldJavaOptions = [Environment]::GetEnvironmentVariable('JAVA_TOOL_OPTIONS', 'Process')
$previousLocation = Get-Location
$started = [DateTime]::UtcNow
$report = [ordered]@{
    startedUtc = $started.ToString('o')
    target = $Target
    platform = 'ohos-x64'
    javaToolOptions = '-Xms16m -Xmx256m -XX:+UseSerialGC'
    buildExitCode = $null
    profileRestored = $false
    environmentRestored = $false
    logPath = $logFullPath
    hap = $null
    error = $null
}
try {
    $originalBytes = [IO.File]::ReadAllBytes($profilePath)
    $report.originalProfileSha256 = Get-ByteHash $originalBytes
    $backupPath = Join-Path $buildDirectory "ohos-audit-profile-$($started.ToString('yyyyMMddTHHmmssfff'))-$PID.original"
    [IO.File]::WriteAllBytes($backupPath, $originalBytes)
    $report.recoveryProfilePath = $backupPath
    $text = [Text.Encoding]::UTF8.GetString($originalBytes)
    $text = Replace-One $text '("abiFilters"\s*:\s*)\["arm64-v8a"\]' '${1}["x86_64"]'
    $text = Replace-One $text '("excludes"\s*:\s*)\["\*\*/x86_64/\*\*"\]' '${1}["**/arm64-v8a/**"]'
    $text = Replace-One $text '("ignoreResourcePattern"\s*:\s*)\["\*\*/jdk-x86_64\.\*"\]' '${1}["**/jdk-arm64-v8a.*"]'
    [IO.File]::WriteAllText($profilePath, $text, (New-Object Text.UTF8Encoding($false)))
    $report.temporaryProfileSha256 = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [Environment]::SetEnvironmentVariable('JAVA_TOOL_OPTIONS', $report.javaToolOptions, 'Process')
    Set-Location -LiteralPath $projectRoot
    $flutterArguments = @('build', 'hap', '--debug', '--no-pub', '--target-platform', 'ohos-x64', '-t', $Target)
    Write-Output "Building $Target for x86_64; log: $logFullPath"
    # A tool may write warnings to stderr. Native exit status remains decisive.
    $ErrorActionPreference = 'Continue'
    & $flutter @flutterArguments 2>&1 | Tee-Object -FilePath $logFullPath
    $report.buildExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($report.buildExitCode -ne 0) { throw "Flutter HAP build failed with exit code $($report.buildExitCode)." }
    $outputs = Join-Path $projectRoot 'ohos/entry/build/default/outputs/default'
    $candidates = @(Get-ChildItem -LiteralPath $outputs -Filter '*-signed.hap' |
        Where-Object { $_.LastWriteTimeUtc -ge $started.AddSeconds(-2) } |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($candidates.Count -eq 0) { throw 'No fresh signed HAP was produced; refusing to report an older package.' }
    $report.hap = Inspect-Hap $candidates[0].FullName
}
catch {
    $report.error = $_.Exception.Message
}
finally {
    $ErrorActionPreference = 'Stop'
    try {
        if ($null -ne $originalBytes) {
            [IO.File]::WriteAllBytes($profilePath, $originalBytes)
            $report.restoredProfileSha256 = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash.ToLowerInvariant()
            $report.profileRestored = $report.restoredProfileSha256 -eq $report.originalProfileSha256
        }
    }
    finally {
        if ($hadJavaOptions) {
            [Environment]::SetEnvironmentVariable('JAVA_TOOL_OPTIONS', $oldJavaOptions, 'Process')
        }
        else {
            # On current .NET, SetEnvironmentVariable(name, $null) creates an
            # empty variable. Remove through the provider to restore absence.
            Remove-Item Env:JAVA_TOOL_OPTIONS -ErrorAction SilentlyContinue
        }
        $report.environmentRestored = ((Test-Path Env:JAVA_TOOL_OPTIONS) -eq $hadJavaOptions) -and
            ([Environment]::GetEnvironmentVariable('JAVA_TOOL_OPTIONS', 'Process') -eq $oldJavaOptions)
        Set-Location -LiteralPath $previousLocation.Path
        $lock.Dispose()
        $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportFullPath -Encoding UTF8
    }
}
if (-not $report.profileRestored -or -not $report.environmentRestored) { throw "Build state restoration failed; see $reportFullPath" }
if ($null -ne $report.error) { throw "$($report.error) Report: $reportFullPath" }
Write-Output "Verified signed x86_64 HAP: $($report.hap.path)"
Write-Output "Build profile and process environment restored; report: $reportFullPath"
