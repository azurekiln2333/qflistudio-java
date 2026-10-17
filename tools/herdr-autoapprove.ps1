<#
herdr-autoapprove.ps1

Continuously watches the qfli_java Herdr workspace (wE) for blocked codex agents
and auto-confirms every yes/no approval prompt by sending an Enter key.

Scope:
  - ONLY workspace wE (label: qfli_java)
  - ONLY agents of kind "codex"
  - ONLY when agent_status == "blocked"

It never touches pi agents, other workspaces, or non-blocked panes.

Usage:
  pwsh -NoProfile -File tools\herdr-autoapprove.ps1
  pwsh -NoProfile -File tools\herdr-autoapprove.ps1 -IntervalSeconds 3
  pwsh -NoProfile -File tools\herdr-autoapprove.ps1 -DryRun        # log only, no keys
  pwsh -NoProfile -File tools\herdr-autoapprove.ps1 -SelfTest      # single pass then exit

Stop with Ctrl+C.
#>

[CmdletBinding()]
param(
    [string]$Herdr   = "D:\ProgramFiles\herdr-windows-x86_64\herdr.exe",
    [string]$WorkspaceId = "wE",
    [int]$IntervalSeconds = 3,
    [int]$CooldownSeconds = 6,
    [switch]$DryRun,
    [switch]$SelfTest
)

$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir
$LogPath   = Join-Path $RepoRoot "herdr-autoapprove.log"

# Per-pane cooldown so we never spam Enter on the same pane.
$script:LastSent = @{}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line  = "[$stamp] [$Level] $Message"
    Write-Host $line
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8BOM
    } catch { }
}

function Invoke-Herdr {
    param([string[]]$HerdrArgs)
    try {
        $prev = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        try {
            $raw = & $Herdr @HerdrArgs 2>&1 | Out-String
        } finally {
            [Console]::OutputEncoding = $prev
        }
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-BlockedCodexPanes {
    $resp = Invoke-Herdr @("agent", "list")
    if ($null -eq $resp -or $null -eq $resp.result -or $null -eq $resp.result.agents) {
        return @()
    }
    $resp.result.agents |
        Where-Object {
            $_.agent -eq "codex" -and
            $_.workspace_id -eq $WorkspaceId -and
            $_.agent_status -eq "blocked"
        }
}

# Read the visible screen; returns the raw screen text (agent read prints plain text).
function Get-PaneScreen {
    param([string]$PaneId)
    try {
        $prev = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        try {
            return (& $Herdr agent read $PaneId --source visible --lines 60 2>&1 | Out-String)
        } finally {
            [Console]::OutputEncoding = $prev
        }
    } catch {
        return ""
    }
}

# Returns $true when the visible screen looks like a codex yes/no approval UI.
function Test-ApprovalPrompt {
    param([string]$PaneId)
    $text = Get-PaneScreen -PaneId $PaneId
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }

    # Codex approval UIs contain one of these markers.
    return (
        $text -match "Yes, proceed" -or
        $text -match "Would you like to" -or
        $text -match "Press enter to confirm" -or
        $text -match "esc to cancel"
    )
}

function Confirm-Pane {
    param([string]$PaneId, [string]$Title)

    $now = Get-Date
    if ($script:LastSent.ContainsKey($PaneId)) {
        $elapsed = ($now - $script:LastSent[$PaneId]).TotalSeconds
        if ($elapsed -lt $CooldownSeconds) {
            return
        }
    }

    if (-not (Test-ApprovalPrompt -PaneId $PaneId)) {
        Write-Log "pane $PaneId blocked but no approval markers on screen; skipping" "WARN"
        $script:LastSent[$PaneId] = $now
        return
    }

    if ($DryRun) {
        Write-Log "DRYRUN would send Enter to $PaneId ($Title)" "DRYRUN"
        $script:LastSent[$PaneId] = $now
        return
    }

    $send = Invoke-Herdr @("agent", "send-keys", $PaneId, "enter")
    $script:LastSent[$PaneId] = $now

    if ($null -ne $send -and $send.result -and $send.result.type -eq "ok") {
        Write-Log "approved (Enter) -> $PaneId | $Title" "ACTION"
    } else {
        Write-Log "send-keys failed for ${PaneId}: $($send | ConvertTo-Json -Compress)" "ERROR"
    }
}

# --- main -----------------------------------------------------------------

Write-Log "=== herdr-autoapprove started (workspace=$WorkspaceId, interval=${IntervalSeconds}s, cooldown=${CooldownSeconds}s, dryrun=$DryRun) ===" "START"
Write-Log "log file: $LogPath"

if (-not (Test-Path -LiteralPath $Herdr)) {
    Write-Log "herdr binary not found: $Herdr" "FATAL"
    exit 2
}
if ($env:HERDR_ENV -ne "1") {
    Write-Log "HERDR_ENV != 1 - not running inside a Herdr pane; herdr API may target the wrong session" "WARN"
}

$pass = 0
try {
    while ($true) {
        $pass++
        $blocked = @(Get-BlockedCodexPanes)
        foreach ($agent in $blocked) {
            Confirm-Pane -PaneId $agent.pane_id -Title $agent.terminal_title_stripped
        }

        if ($SelfTest) {
            Write-Log "self-test pass $pass complete; blocked-codex count=$($blocked.Count); exiting" "INFO"
            break
        }

        Start-Sleep -Seconds $IntervalSeconds
    }
} catch {
    Write-Log "loop error: $($_.Exception.Message)" "ERROR"
    exit 1
} finally {
    if (-not $SelfTest) {
        Write-Log "=== herdr-autoapprove stopped ===" "STOP"
    }
}
