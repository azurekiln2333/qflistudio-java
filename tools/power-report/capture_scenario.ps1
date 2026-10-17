# Read-only device capture helper for the HarmonyOS power/frame verification.
#
# Runs the on-device SmartPerf daemon (SP_daemon) against a package and writes a
# per-scenario capture to tools/power-report/captures/. It changes nothing on the
# device: no install, no uninstall, no settings.
#
# Usage (from the repo root):
#   Open the desired page on the phone first; this script does not navigate it.
#   powershell -File tools/power-report/capture_scenario.ps1 -Scenario list
#
# Notes proven on device 192.168.68.207:46551 (MRT-AL10, API 26):
#   * The working invocation is `hdc -t <t> shell SP_daemon <flags>`.
#   * -f (frames), -c (cpu) and -p (power) CAN be combined in ONE invocation, so
#     one 30 s run yields all three sections on a single, aligned time window.
#   * Not every device supports -p; a missing -p section is reported, not faked.

param(
    [string]$Target = '192.168.68.207:46551',
    [string]$Package = 'com.azurekiln.qfli.java',
    [ValidateSet('list', 'detail', 'copy', 'clear-external', 'offscreen', 'reenter')]
    [string]$Scenario = 'list',
    [ValidateRange(1, 3600)]
    [int]$Seconds = 30
)

$ErrorActionPreference = 'Stop'

function Invoke-SpDaemon {
    param([string[]]$SpArgs)
    # SP_daemon must be run through the device shell; passing its flags straight
    # to hdc would send them to hdc itself.
    & hdc -t $Target shell SP_daemon @SpArgs 2>&1
}

$notes = @{
    'list'           = 'Home -> example list, untouched (no input)'
    'detail'         = 'Example detail, code UNFOCUSED (never tap into the editor)'
    'copy'           = 'Tap copy, then wait for the snackbar to fully dismiss'
    'clear-external' = 'Clear the field, then tap outside to retract the keyboard'
    'offscreen'      = 'Scroll the code box fully out of the viewport'
    'reenter'        = 'Navigate back, then re-enter the example detail'
}

$outDir = Join-Path $PSScriptRoot 'captures'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outFile = Join-Path $outDir "$Scenario-$stamp.txt"

Write-Output "scenario: $Scenario"
Write-Output "note:     $($notes[$Scenario])"
Write-Output "package:  $Package"
Write-Output "duration: ${Seconds}s"
Write-Output "started:  $(Get-Date -Format o)"

# One aligned capture: frames + cpu + power in a single 30 s window.
$raw = Invoke-SpDaemon -SpArgs @(
    '-N', "$Seconds", '-PKG', $Package, '-f', '-c', '-p', '-print'
)

$raw | Set-Content -Path $outFile -Encoding UTF8

# Summarise honestly: report sections that are absent rather than implying zero.
# The section index in `order:<n>` shifts depending on which flags are combined
# (fps is `order:0` alone but `order:131` alongside -c/-p), so match the field
# name only and never the order index.
$fps = @($raw | Select-String -Pattern '(?m)^order:\d+ fps=(\d+)' -AllMatches |
    ForEach-Object { $_.Matches } | ForEach-Object { [int]$_.Groups[1].Value })
$refresh = @($raw | Select-String -Pattern 'refreshrate=(\d+)' -AllMatches |
    ForEach-Object { $_.Matches } | ForEach-Object { [int]$_.Groups[1].Value })
$procCpu = @($raw | Select-String -Pattern 'ProcCpuUsage=([\d.]+)' -AllMatches |
    ForEach-Object { $_.Matches } | ForEach-Object { [double]$_.Groups[1].Value })

# Current and voltage are reported as RAW values, with the official SDK units
# cited alongside. The SDK is the authority; this script does not guess.
#
# Source: D:/ProgramFiles/Huawei/OpenHarmony/Sdk/23/ets/api/@ohos.batteryInfo.d.ts
#   line 84 : "Battery voltage of the current device, in uV."  -> voltage  = uV
#   line 119: "Battery immediate current of the current device, in mA." -> nowCurrent = mA
# (A second DevEco SDK documents mA as well.)
#
# The SP_daemon fields `currentNow` / `voltageNow` are the same physical
# quantities, but SP_daemon's own help text states no units, so a watt figure is
# NOT emitted here: that would require proving the SP fields share the SDK API's
# unit chain end to end. Raw values are saved for re-derivation once confirmed.
#
# Each `currentNow` is paired with the `voltageNow` in its own sample block and
# an unpaired block is rejected, so a short/missing section cannot be silently
# mis-paired by two independent regex arrays.
$powerSamples = @()
$lines = @($raw)
for ($i = 0; $i -lt $lines.Count; $i++) {
    $cm = [regex]::Match($lines[$i], '^order:\d+ currentNow=(-?\d+)')
    if (-not $cm.Success) { continue }
    $currentRaw = [int]$cm.Groups[1].Value
    $voltageRaw = $null
    for ($j = $i + 1; $j -lt [Math]::Min($i + 6, $lines.Count); $j++) {
        if ($lines[$j] -match '^order:\d+ currentNow=') { break }
        $vm = [regex]::Match($lines[$j], '^order:\d+ voltageNow=(\d+)')
        if ($vm.Success) { $voltageRaw = [long]$vm.Groups[1].Value; break }
    }
    if ($null -eq $voltageRaw) { continue }
    if ($voltageRaw -le 0) { continue }
    $powerSamples += [pscustomobject]@{ CurrentRaw = $currentRaw; VoltageRaw = $voltageRaw }
}

Write-Output ''
Write-Output "samples: fps=$($fps.Count) cpu=$($procCpu.Count) powerPairs=$($powerSamples.Count)"
if ($fps.Count -gt 0) {
    Write-Output "SmartPerf FPS reading: min=$($fps | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum) max=$($fps | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum) nonZero=$(@($fps | Where-Object { $_ -ne 0 }).Count)"
    Write-Output 'No surface ID is reported; this alone cannot attribute frames to XComponent.'
} else {
    Write-Output 'fps: no numeric samples - this is not a zero-FPS result'
}
if ($refresh.Count -gt 0) {
    Write-Output "panel refreshrate: $(($refresh | Select-Object -Unique) -join ',') Hz  (display cadence, NOT app activity)"
}
if ($procCpu.Count -gt 0) {
    Write-Output "process cpu %: max=$(($procCpu | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum))"
}
if ($powerSamples.Count -gt 0) {
    $cur = $powerSamples | ForEach-Object { $_.CurrentRaw }
    $volt = $powerSamples | ForEach-Object { $_.VoltageRaw }
    Write-Output "raw currentNow: min=$(($cur | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum)) max=$(($cur | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum)) (n=$($powerSamples.Count))"
    Write-Output "raw voltageNow: min=$(($volt | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum)) max=$(($volt | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum))"
    Write-Output 'Units per SDK (@ohos.batteryInfo.d.ts): voltage uV, nowCurrent mA.'
    Write-Output 'No watt figure is emitted (SP field units not independently proven end to end).'
    Write-Output 'This is the whole device, not app-only consumption.'
} else {
    Write-Output 'power: no valid paired currentNow/voltageNow samples - nothing reported'
}

Write-Output ''
Write-Output "raw captured to: $outFile"
Write-Output "finished: $(Get-Date -Format o)"
