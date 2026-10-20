# Relaunch Claude — Windows installer
param([switch]$Autostart)
$ErrorActionPreference = 'Stop'

$Src       = $PSScriptRoot
$Dest      = Join-Path $env:LOCALAPPDATA 'relaunch-claude'
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$Settings  = Join-Path $ClaudeDir 'settings.json'
$Script    = Join-Path $Dest 'relaunch-claude.ps1'

New-Item -ItemType Directory -Force -Path $Dest, $ClaudeDir | Out-Null
Copy-Item (Join-Path $Src 'relaunch-claude.ps1') $Script -Force
Copy-Item (Join-Path $Src '..\assets\icon.ico') (Join-Path $Dest 'icon.ico') -Force

# 1. Register the hook in Claude Code settings (merged, idempotent, backed up).
$hookCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Script`" -Hook"
$cfg = [pscustomobject]@{}
if ((Test-Path $Settings) -and (Get-Content $Settings -Raw).Trim()) {
    Copy-Item $Settings "$Settings.bak-relaunch-claude" -Force
    $cfg = Get-Content $Settings -Raw | ConvertFrom-Json
}
if (-not $cfg.PSObject.Properties['hooks']) { $cfg | Add-Member hooks ([pscustomobject]@{}) }
foreach ($event in 'SessionStart', 'SessionEnd') {
    if (-not $cfg.hooks.PSObject.Properties[$event]) { $cfg.hooks | Add-Member $event @() }
    $groups = @($cfg.hooks.$event)
    $present = $groups | ForEach-Object { $_.hooks } | Where-Object { $_.command -like '*relaunch-claude.ps1*' }
    if (-not $present) {
        $groups += [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $hookCmd; timeout = 15 }) }
    }
    $cfg.hooks.$event = $groups
}
$json = $cfg | ConvertTo-Json -Depth 32
[IO.File]::WriteAllText($Settings, $json, (New-Object Text.UTF8Encoding $false))

# 2. `reclaude` terminal command (cmd, PowerShell and Windows Terminal).
$Bin = Join-Path $Dest 'bin'
New-Item -ItemType Directory -Force -Path $Bin | Out-Null
$cmdBody = "@echo off`r`n" +
    "if /i `"%~1`"==`"list`" (powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Script`" -List & exit /b)`r`n" +
    "if /i `"%~1`"==`"--dry-run`" (powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Script`" -DryRun & exit /b)`r`n" +
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Script`" -Console`r`n"
[IO.File]::WriteAllText((Join-Path $Bin 'reclaude.cmd'), $cmdBody)
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $Bin) {
    $newPath = if ($userPath) { "$($userPath.TrimEnd(';'));$Bin" } else { $Bin }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
}

# 3. Shortcuts: desktop + Start menu (+ Startup folder with -Autostart).
$shell = New-Object -ComObject WScript.Shell
$targets = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))
if ($Autostart) { $targets += [Environment]::GetFolderPath('Startup') }
foreach ($dir in $targets) {
    $lnk = $shell.CreateShortcut((Join-Path $dir 'Relaunch Claude.lnk'))
    $lnk.TargetPath       = 'powershell.exe'
    $lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`""
    $lnk.IconLocation     = (Join-Path $Dest 'icon.ico')
    $lnk.Description      = 'Reopen and resume every interrupted Claude Code session'
    $lnk.WorkingDirectory = $env:USERPROFILE
    $lnk.Save()
}

Write-Host 'Relaunch Claude installed.'
Write-Host '  - Sessions started from now on are tracked (already open ones: restart them once).'
Write-Host '  - After a reboot, double-click the "Relaunch Claude" icon, or run: reclaude'
Write-Host '  - Open a new terminal first so it picks up the updated PATH.'
