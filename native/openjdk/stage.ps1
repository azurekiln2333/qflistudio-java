param(
    [Parameter(Mandatory)][ValidateSet('android', 'ohos')][string]$Platform,
    [Parameter(Mandatory)][ValidateSet('arm64-v8a', 'x86_64')][string]$Abi,
    [Parameter(Mandatory)][string]$Image
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
$Image = (Resolve-Path -LiteralPath $Image).ProviderPath
$header = [System.IO.File]::ReadAllBytes((Join-Path $Image 'bin/java'))
$machine = [BitConverter]::ToUInt16($header, 18)
if ($header[0] -ne 127 -or $header[1] -ne 69 -or $header[2] -ne 76 -or $header[3] -ne 70 -or
    $header[4] -ne 2 -or $header[5] -ne 1 -or
    ($Abi -eq 'arm64-v8a' -and $machine -ne 183) -or
    ($Abi -eq 'x86_64' -and $machine -ne 62)) {
    throw 'The image must contain an ELF64 launcher matching the selected ABI.'
}

function Assert-AndroidElf([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $machine = [BitConverter]::ToUInt16($bytes, 18)
    if (($Abi -eq 'arm64-v8a' -and $machine -ne 183) -or
        ($Abi -eq 'x86_64' -and $machine -ne 62)) {
        throw "Wrong Android ELF architecture: $Path"
    }
    $table = [BitConverter]::ToUInt64($bytes, 32)
    $size = [BitConverter]::ToUInt16($bytes, 54)
    $count = [BitConverter]::ToUInt16($bytes, 56)
    for ($index = 0; $index -lt $count; $index++) {
        $entry = [int]($table + $index * $size)
        if ([BitConverter]::ToUInt32($bytes, $entry) -ne 1) { continue }
        $alignment = [BitConverter]::ToUInt64($bytes, $entry + 48)
        if ($alignment -lt 16384) { throw "Android ELF lacks 16 KB LOAD alignment: $Path" }
        $offset = [BitConverter]::ToUInt64($bytes, $entry + 8)
        $address = [BitConverter]::ToUInt64($bytes, $entry + 16)
        if ($offset % 16384 -ne $address % 16384) {
            throw "Android ELF lacks 16 KB LOAD offset congruence: $Path"
        }
    }
}
if ($Platform -eq 'android') {
    foreach ($file in Get-ChildItem -LiteralPath $Image -File -Recurse) {
        if ($file.Name -match '\.so(?:\.[0-9]+)*$' -or
            $file.FullName -in @((Join-Path $Image 'bin/java'), (Join-Path $Image 'bin/javac')) -or
            $file.Name -in @('jspawnhelper', 'jexec')) {
            Assert-AndroidElf $file.FullName
        }
    }
}

$out = Join-Path $repo "native/build/$Platform"
$libraryDir = Join-Path $out "jniLibs/$Abi"
New-Item -ItemType Directory -Force -Path $libraryDir | Out-Null
$links = [System.Collections.Generic.List[object]]::new()
$names = @{}
foreach ($library in Get-ChildItem -LiteralPath (Join-Path $Image 'lib') -File -Recurse) {
    if ($library.Name -notmatch '\.so(?:\.[0-9]+)*$') { continue }
    $name = $library.Name -replace '\.so(?:\.[0-9]+)+$', '.so'
    $relative = [IO.Path]::GetRelativePath($Image, $library.FullName).Replace('\', '/')
    $digest = (Get-FileHash -LiteralPath $library.FullName).Hash
    if ($names.ContainsKey($name) -and $names[$name] -ne $digest) {
        throw "Multiple libraries map to $name."
    }
    $names[$name] = $digest
    Copy-Item -LiteralPath $library.FullName -Destination (Join-Path $libraryDir $name) -Force
    $links.Add(@{ path = $relative; library = $name })
}
foreach ($tool in @('java', 'javac')) {
    Copy-Item -LiteralPath (Join-Path $Image "bin/$tool") -Destination (Join-Path $libraryDir "libqfli_$tool.so") -Force
}
foreach ($helper in @('jspawnhelper', 'jexec')) {
    $path = Join-Path $Image "lib/$helper"
    if (Test-Path -LiteralPath $path) {
        $name = "libqfli_$helper.so"
        Copy-Item -LiteralPath $path -Destination (Join-Path $libraryDir $name) -Force
        $links.Add(@{ path = "lib/$helper"; library = $name })
        $names[$name] = (Get-FileHash -LiteralPath $path).Hash
    }
}
if ($Platform -eq 'android') {
    foreach ($library in @('libandroid-shmem.so', 'libandroid-spawn.so', 'libandroid-sysv-semaphore.so', 'libiconv.so', 'libasound.so', 'libc++_shared.so')) {
        if (-not (Test-Path -LiteralPath (Join-Path $libraryDir $library))) { throw "Missing dependency: $library" }
    }
}
$assets = Join-Path $out 'assets'
New-Item -ItemType Directory -Force -Path $assets | Out-Null
$zipPath = Join-Path $assets "jdk-$Abi.zip"
$dataFiles = @(
    foreach ($root in @('conf', 'lib', 'legal')) {
        Get-ChildItem -LiteralPath (Join-Path $Image $root) -File -Recurse | Where-Object {
            $_.Name -notmatch '\.so(?:\.[0-9]+)*$|\.debuginfo$' -and $_.Name -notin @('src.zip', 'jspawnhelper', 'jexec')
        }
    }
    Get-Item -LiteralPath (Join-Path $Image 'release')
)
$digests = @(
    $names.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Value }
    $dataFiles | Sort-Object FullName | Get-FileHash | ForEach-Object { $_.Hash }
    Get-FileHash -LiteralPath (Join-Path $Image 'bin/java'), (Join-Path $Image 'bin/javac') | ForEach-Object { $_.Hash }
)
$id = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($digests -join ':'))).ToLower()
$manifest = @{
    version = 1
    id = "$Platform-$Abi-$id"
    libraries = @($links.ToArray())
} | ConvertTo-Json -Depth 4 -Compress
$jsonPath = Join-Path $assets "jdk-$Abi.json"
[IO.File]::WriteAllText($jsonPath, $manifest, [Text.UTF8Encoding]::new($false))
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath }
$archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    $entry = $archive.CreateEntry('layout.json')
    $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
    try { $writer.Write($manifest) } finally { $writer.Dispose() }
    foreach ($file in $dataFiles) {
        $relative = [IO.Path]::GetRelativePath($Image, $file.FullName).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $relative) | Out-Null
    }
} finally { $archive.Dispose() }
if ($Platform -eq 'ohos') {
    $hapLibs = Join-Path $repo "ohos/entry/libs/$Abi"
    New-Item -ItemType Directory -Force -Path $hapLibs | Out-Null
    Copy-Item -Path (Join-Path $libraryDir '*.so') -Destination $hapLibs -Force
    Copy-Item -LiteralPath $zipPath -Destination (Join-Path $repo "ohos/entry/src/main/resources/rawfile/jdk-$Abi.zip") -Force
    Copy-Item -LiteralPath $jsonPath -Destination (Join-Path $repo "ohos/entry/src/main/resources/rawfile/jdk-$Abi.json") -Force
}
Write-Output "JDK libraries: $libraryDir"
Write-Output "JDK data archive: $zipPath"
