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

function Invoke-BindingTool([string[]]$Arguments) {
    & $python $bindingTool @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Build input/artifact binding failed with exit code $LASTEXITCODE." }
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
        $verifiedStagedLibraries = @()
        foreach ($library in $stagedLibraries) {
            $packaged = @($nativeEntries | Where-Object { $_.FullName -eq "libs/x86_64/$($library.Name)" })
            if ($packaged.Count -ne 1) {
                throw "A staged JDK library is missing from the HAP: $($library.Name)"
            }
            $packagedHash = Get-EntryHash $packaged[0]
            $stagedHash = (Get-FileHash -LiteralPath $library.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($packagedHash -ne $stagedHash) { throw "Packaged native library differs from its staged source: $($library.Name)" }
            $verifiedStagedLibraries += [ordered]@{
                path = $packaged[0].FullName; bytes = $packaged[0].Length
                sha256 = $packagedHash; stagedSha256 = $stagedHash
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
        $moduleEntries = @($archive.Entries | Where-Object { $_.FullName -match '(^|/)module\.json$' })
        if ($moduleEntries.Count -ne 1) { throw 'Expected exactly one packed module.json.' }
        $moduleReader = [IO.StreamReader]::new($moduleEntries[0].Open())
        try { $packedModule = $moduleReader.ReadToEnd() | ConvertFrom-Json }
        finally { $moduleReader.Dispose() }
        if ($packedModule.app.bundleName -ne 'com.azurekiln.qfli.java') {
            throw 'The HAP does not contain the Java application bundle.'
        }
        return [ordered]@{
            path = $Path
            bytes = (Get-Item -LiteralPath $Path).Length
            sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
            signedOutput = $Path -match '-signed\.hap$'
            abi = 'x86_64'
            bundleName = $packedModule.app.bundleName
            verifiedElfCount = $nativeEntries.Count
            stagedJdkLibraryCount = $stagedLibraries.Count
            stagedJdkLibraries = $verifiedStagedLibraries
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
$python = (Get-Command python -ErrorAction Stop).Source
$bindingTool = Join-Path $PSScriptRoot 'verify_java_ohos_binding.py'
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
    nativeOfflineBinding = $null
    inputBinding = $null
    hap = $null
    error = $null
}
try {
    $originalBytes = [IO.File]::ReadAllBytes($profilePath)
    $report.originalProfileSha256 = Get-ByteHash $originalBytes
    $nativeBindingInputs = @(
        'ohos/entry/src/main/ets/entryability/EntryAbility.ets',
        'ohos/entry/src/main/resources/base/profile/main_pages.json',
        'ohos/entry/src/main/module.json5'
    )
    $isRuntimeAcceptance = $targetFullPath -ieq (Resolve-ProjectPath 'tools/java_runtime_acceptance.dart')
    if ($isRuntimeAcceptance) {
        $capturedNativeInputs = @($nativeBindingInputs | ForEach-Object {
            [ordered]@{
                path = $_
                sha256 = (Get-FileHash -LiteralPath (Resolve-ProjectPath $_) -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
        $report.nativeOfflineBinding = [ordered]@{
            inputs = $capturedNativeInputs
            entryAbilitySha256 = $capturedNativeInputs[0].sha256
            sourceUnchangedDuringBuild = $false
            requiresMatchingInstalledHap = $true
        }
    }
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
    # Capture resolved package sources, configuration, shipped assets and staged
    # JDK bytes. The managed entry profile has its own original/temporary/restored
    # hashes. Key material is never enumerated or written into the report.
    $inputManifestPath = "$reportFullPath.inputs.json"
    Invoke-BindingTool -Arguments @('capture', '--repo', $projectRoot, '--target', $targetFullPath, '--output', $inputManifestPath)
    $inputManifest = Get-Content -LiteralPath $inputManifestPath -Raw | ConvertFrom-Json
    $report.target = $inputManifest.target
    $report.inputBinding = [ordered]@{
        schemaVersion = 1
        manifestPath = $inputManifestPath
        manifestSha256 = $inputManifest.manifestSha256
        buildNonce = [Guid]::NewGuid().ToString('N')
        resolvedCoreRoot = $inputManifest.roots.'package:qfli_studio_core'
        sourceUnchangedDuringBuild = $false
        installedPackageProven = $false
        requiresExternalInstallEvidence = $true
    }
    $flutterArguments = @('build', 'hap', '--debug', '--no-pub', '--target-platform', 'ohos-x64', '-t', $Target)
    if ($isRuntimeAcceptance) {
        # Only this freshly built target may invoke the native account refusal
        # probe. The device driver must install the exact reported HAP and bind
        # its runtime report back to these source hashes; defines alone are not
        # proof that a previously installed package contains current native code.
        $flutterArguments += '--dart-define=QFLI_JAVA_NATIVE_OFFLINE_SOURCE_BOUND=true'
        $flutterArguments += "--dart-define=QFLI_JAVA_NATIVE_OFFLINE_SOURCE_SHA256=$($report.nativeOfflineBinding.entryAbilitySha256)"
        $flutterArguments += "--dart-define=QFLI_JAVA_BUILD_NONCE=$($report.inputBinding.buildNonce)"
        $flutterArguments += "--dart-define=QFLI_JAVA_BUILD_INPUTS_SHA256=$($report.inputBinding.manifestSha256)"
    }
    Write-Output "Building $Target for x86_64; log: $logFullPath"
    # A tool may write warnings to stderr. Native exit status remains decisive.
    $ErrorActionPreference = 'Continue'
    & $flutter @flutterArguments 2>&1 | Tee-Object -FilePath $logFullPath
    $report.buildExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($report.buildExitCode -ne 0) { throw "Flutter HAP build failed with exit code $($report.buildExitCode)." }
    if ($isRuntimeAcceptance) {
        foreach ($inputSource in $capturedNativeInputs) {
            $currentHash = (Get-FileHash -LiteralPath (Resolve-ProjectPath $inputSource.path) -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($currentHash -ne $inputSource.sha256) {
                throw "Native acceptance source changed during build: $($inputSource.path)"
            }
        }
        $report.nativeOfflineBinding.sourceUnchangedDuringBuild = $true
    }
    $outputs = Join-Path $projectRoot 'ohos/entry/build/default/outputs/default'
    $candidates = @(Get-ChildItem -LiteralPath $outputs -Filter '*-signed.hap' |
        Where-Object { $_.LastWriteTimeUtc -ge $started.AddSeconds(-2) } |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($candidates.Count -eq 0) { throw 'No fresh signed HAP was produced; refusing to report an older package.' }
    $report.hap = Inspect-Hap $candidates[0].FullName
    $currentTemporaryProfileHash = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($currentTemporaryProfileHash -ne $report.temporaryProfileSha256) {
        throw 'The managed temporary entry profile changed during build.'
    }
    Invoke-BindingTool -Arguments @('verify-inputs', '--manifest', $inputManifestPath)
    $report.inputBinding.sourceUnchangedDuringBuild = $true
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
