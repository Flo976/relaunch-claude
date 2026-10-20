# Relaunch Claude — Windows uninstaller
$ErrorActionPreference = 'Stop'

$Dest      = Join-Path $env:LOCALAPPDATA 'relaunch-claude'
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$Settings  = Join-Path $ClaudeDir 'settings.json'

if (Test-Path $Settings) {
    $cfg = Get-Content $Settings -Raw | ConvertFrom-Json
    if ($cfg.PSObject.Properties['hooks']) {
        foreach ($event in 'SessionStart', 'SessionEnd') {
            if (-not $cfg.hooks.PSObject.Properties[$event]) { continue }
            $groups = @()
            foreach ($g in @($cfg.hooks.$event)) {
                $g.hooks = @($g.hooks | Where-Object { $_.command -notlike '*relaunch-claude.ps1*' })
                if ($g.hooks.Count) { $groups += $g }
            }
            if ($groups.Count) { $cfg.hooks.$event = $groups } else { $cfg.hooks.PSObject.Properties.Remove($event) }
        }
    }
    [IO.File]::WriteAllText($Settings, ($cfg | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding $false))
}

foreach ($dir in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Startup')) {
    Remove-Item (Join-Path $dir 'Relaunch Claude.lnk') -ErrorAction SilentlyContinue
}
$Bin = Join-Path $Dest 'bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath) {
    [Environment]::SetEnvironmentVariable('Path', (($userPath -split ';') | Where-Object { $_ -and $_ -ne $Bin }) -join ';', 'User')
}
Remove-Item $Dest, (Join-Path $ClaudeDir 'relaunch-claude') -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Relaunch Claude uninstalled.'
