# herdr-autoapprove

Watcher that auto-confirms every yes/no prompt from **codex** agents in the
**qfli_java** Herdr workspace (`wE`), and writes a log of every action.

## What it does

- Polls `herdr agent list` every few seconds.
- Selects only agents where: `agent == codex`, `workspace_id == wE`, `agent_status == blocked`.
- Reads the pane screen and confirms it really is an approval UI
  (`Yes, proceed` / `Would you like to` / `Press enter to confirm`).
- Sends `Enter` via `herdr agent send-keys <pane> enter`.
- Logs every start/stop, every approval, and any anomaly.

It never touches `pi` agents, other workspaces, or non-blocked panes.

## Files

| File | Purpose |
|---|---|
| `tools/herdr-autoapprove.ps1` | the watcher script |
| `herdr-autoapprove.log` | **authoritative log** (UTF-8, correct CJK) |
| `herdr-autoapprove.out.log` | stdout mirror (may show mojibake; ignore) |
| `herdr-autoapprove.err.log` | stderr mirror |
| `.herdr-autoapprove.pid` | PID of the running watcher |

## Start

```powershell
$args = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','D:\MyNewProjects\qfli_java\tools\herdr-autoapprove.ps1')
Start-Process -FilePath 'pwsh' -ArgumentList $args -WindowStyle Hidden `
  -RedirectStandardOutput 'D:\MyNewProjects\qfli_java\herdr-autoapprove.out.log' `
  -RedirectStandardError  'D:\MyNewProjects\qfli_java\herdr-autoapprove.err.log'
```

## Stop

```powershell
$id = (Get-Content D:\MyNewProjects\qfli_java\.herdr-autoapprove.pid).Trim()
Stop-Process -Id $id -Force
# or kill every instance:
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
  Where-Object { $_.CommandLine -like '*-File*herdr-autoapprove.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

## Verify it is alive

```powershell
$id = (Get-Content D:\MyNewProjects\qfli_java\.herdr-autoapprove.pid).Trim()
Get-Process -Id $id
Get-Content D:\MyNewProjects\qfli_java\herdr-autoapprove.log -Tail 20
```

## Options

```powershell
pwsh -NoProfile -File tools\herdr-autoapprove.ps1 -IntervalSeconds 3 -CooldownSeconds 6
pwsh -NoProfile -File tools\herdr-autoapprove.ps1 -DryRun     # log only, send no keys
pwsh -NoProfile -File tools\herdr-autoapprove.ps1 -SelfTest   # one pass, then exit
pwsh -NoProfile -File tools\herdr-autoapprove.ps1 -WorkspaceId wE
```

## Warning

This approves **everything** without risk judgement, by design (per user request).
It will confirm file overwrites, deletes, git operations, and shell commands.
