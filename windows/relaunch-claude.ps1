<#
  Relaunch Claude — reopen every interrupted Claude Code session and resume it.

    relaunch-claude.ps1 -Hook     called by Claude Code (SessionStart / SessionEnd)
    relaunch-claude.ps1           called by the desktop shortcut
    relaunch-claude.ps1 -List     show the registry
    relaunch-claude.ps1 -DryRun   print what would be launched
    reclaude [list|--dry-run]     same, from any terminal (tabs open in the current window)
#>
param([switch]$Hook, [switch]$List, [switch]$DryRun, [switch]$Console)

$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".claude" }
$Registry  = Join-Path $ClaudeDir "relaunch-claude\sessions"
$Config    = Join-Path $ClaudeDir "relaunch-claude\config.json"
$StaleDays = 30

# Flags carried over to the resumed session; prompt, --resume, --continue… are dropped.
$KeepBool  = @('--dangerously-skip-permissions', '--allow-dangerously-skip-permissions', '--verbose', '--chrome', '--ide')
$KeepValue = @('--permission-mode', '--model', '--add-dir', '--agent', '--settings', '--mcp-config', '--fallback-model', '--effort')

# ------------------------------------------------------------------ hook side

function Get-ClaudeAncestor {
    $id = $PID
    for ($i = 0; $i -lt 8; $i++) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if (-not $p) { break }
        if ($p.Name -match '^claude' -or $p.CommandLine -match '[\\/]claude(\.exe|\.cmd)?["\s]|@anthropic-ai[\\/]claude-code') { return $p }
        $id = $p.ParentProcessId
        if ($id -le 4) { break }
    }
    return $null
}

function Get-CarriedFlags([string]$cmdLine) {
    $out = @()
    if (-not $cmdLine) { return $out }
    $tokens = [regex]::Matches($cmdLine, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') }
    for ($i = 1; $i -lt $tokens.Count; $i++) {
        $name = $tokens[$i].Split('=')[0]
        if ($KeepBool -contains $name) { $out += $tokens[$i] }
        elseif ($KeepValue -contains $name) {
            if ($tokens[$i].Contains('=')) { $out += $tokens[$i] }
            elseif ($i + 1 -lt $tokens.Count) { $out += $tokens[$i], $tokens[$i + 1]; $i++ }
        }
    }
    return $out
}

function Invoke-Hook {
    try {
        $data = [Console]::In.ReadToEnd() | ConvertFrom-Json
        if (-not $data.session_id) { return }
        $entry = Join-Path $Registry "$($data.session_id).json"
        if ($data.hook_event_name -eq 'SessionEnd') {
            # "other" = interrupted (terminal closed, shutdown). Explicit exits are forgotten.
            if ($data.reason -ne 'other') { Remove-Item $entry -ErrorAction SilentlyContinue }
            return
        }
        if ($data.hook_event_name -eq 'SessionStart') {
            $proc = Get-ClaudeAncestor
            New-Item -ItemType Directory -Force -Path $Registry | Out-Null
            [ordered]@{
                session_id      = $data.session_id
                cwd             = if ($data.cwd) { $data.cwd } else { (Get-Location).Path }
                transcript_path = $data.transcript_path
                pid             = if ($proc) { $proc.ProcessId } else { $null }
                args            = @(Get-CarriedFlags $(if ($proc) { $proc.CommandLine }))
                claude_bin      = (Get-Command claude -ErrorAction SilentlyContinue).Source
                updated_at      = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            } | ConvertTo-Json | Set-Content -Path $entry -Encoding UTF8
        }
    } catch { }  # a hook must never get in Claude Code's way
}

# -------------------------------------------------------------- relaunch side

function Get-Entries {
    if (-not (Test-Path $Registry)) { return @() }
    Get-ChildItem $Registry -Filter *.json | ForEach-Object {
        try {
            $e = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $e | Add-Member -NotePropertyName _file -NotePropertyValue $_.FullName
            $e
        } catch { Remove-Item $_.FullName -ErrorAction SilentlyContinue }
    }
}

function Test-StillRunning($e) {
    if (-not $e.pid) { return $false }
    $p = Get-Process -Id $e.pid -ErrorAction SilentlyContinue
    return [bool]($p -and ($p.ProcessName -match 'claude|node'))
}

function Show-Message([string]$msg) {
    Write-Host $msg
    if ($DryRun -or $Console) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon = [System.Drawing.SystemIcons]::Information
        $n.Visible = $true
        $n.ShowBalloonTip(6000, 'Relaunch Claude', $msg, 'Info')
        Start-Sleep -Seconds 6
        $n.Dispose()
    } catch { }
}

function Invoke-Relaunch {
    $cfg = @{}
    if (Test-Path $Config) { try { $cfg = Get-Content $Config -Raw | ConvertFrom-Json } catch { } }
    $extra = @($cfg.claude_args | Where-Object { $_ })
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    $shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $done = 0; $skipped = @(); $todo = @()

    foreach ($e in Get-Entries) {
        if ($now - [int64]$e.updated_at -gt $StaleDays * 86400) { Remove-Item $e._file; continue }
        if (Test-StillRunning $e) { continue }
        if (-not $e.cwd -or -not (Test-Path $e.cwd -PathType Container)) {
            $skipped += $(if ($e.cwd) { $e.cwd } else { $e.session_id }); Remove-Item $e._file; continue
        }
        $todo += $e
    }
    if ($todo) { Write-Host "$([char]0x21BB) $($todo.Count) interrupted session(s) found" }

    foreach ($e in $todo) {
        $claude = if ($e.claude_bin -and (Test-Path $e.claude_bin)) { $e.claude_bin } else { 'claude' }
        $claudeArgs = @()
        $shown = @('claude')
        if ($e.transcript_path -and (Test-Path $e.transcript_path)) {
            $claudeArgs += '--resume', $e.session_id
            $shown += '--resume', ($e.session_id.Substring(0, 4) + [char]0x2026)
        }
        $flags = @(@($e.args) + $extra | Where-Object { $_ })
        $claudeArgs += $flags
        $cwdShown = $e.cwd -replace ('^' + [regex]::Escape($env:USERPROFILE)), '~'
        $line = '{0,-24} {1}' -f $cwdShown, (($shown + $flags) -join ' ')
        $quoted = ($claudeArgs | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }) -join ' '
        # A tab opened from another Claude session inherits CLAUDE_CODE_CHILD_SESSION,
        # which silently disables transcript writing.
        $inner = "Remove-Item Env:CLAUDE_CODE_CHILD_SESSION -ErrorAction SilentlyContinue; " +
                 "`$env:CLAUDE_CODE_FORCE_SESSION_PERSISTENCE='1'; & '$claude' $quoted"

        if ($wt) {
            # -w names one window so every session lands in it as a tab (0 = the current one).
            # wt treats ';' as its own separator, hence the escaping.
            $window = if ($Console) { '0' } else { 'relaunch-claude' }
            $wtArgs = "-w $window new-tab -d `"$($e.cwd)`" $shell -NoExit -Command `"$($inner -replace ';', '\;')`""
            if ($DryRun) { Write-Host "  $([char]0x2192) $line`n      wt.exe $wtArgs"; $done++; continue }
            Start-Process wt.exe -ArgumentList $wtArgs
        } else {
            if ($DryRun) { Write-Host "  $([char]0x2192) $line`n      $shell -NoExit -Command $inner"; $done++; continue }
            Start-Process $shell -WorkingDirectory $e.cwd -ArgumentList '-NoExit', '-Command', $inner
        }
        Write-Host "  $([char]0x2713) $line"
        Remove-Item $e._file   # the resumed session registers itself again on start
        $done++
        Start-Sleep -Milliseconds 700
    }

    if ($DryRun) { return }
    $msg = if ($done) { "$done session(s) relaunched." } else { "No interrupted Claude Code session to relaunch." }
    if ($skipped) { $msg += " Skipped (folder gone): $($skipped -join ', ')" }
    Show-Message $msg
}

if ($Hook) { Invoke-Hook }
elseif ($List) {
    foreach ($e in Get-Entries) {
        $state = if (Test-StillRunning $e) { 'running' } else { 'interrupted' }
        '{0,-12} {1}  {2}' -f $state, $e.session_id, $e.cwd
    }
}
else { Invoke-Relaunch }
