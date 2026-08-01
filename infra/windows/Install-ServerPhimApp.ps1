[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ReleasePath,
    [string]$InstallPath = 'D:\WSL\ServerPhimApp'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $ReleasePath) {
    $ReleasePath = Join-Path $repoRoot 'app\server_phim\build\windows\x64\runner\Release'
}
$exeSource = Join-Path $ReleasePath 'server_phim.exe'
if (-not (Test-Path -LiteralPath $exeSource)) { throw "Release executable missing: $exeSource" }

$backupPath = "$InstallPath.previous"
if ($PSCmdlet.ShouldProcess($InstallPath, 'Install Server Phim Windows app')) {
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Recurse -Force
    }
    if (Test-Path -LiteralPath $InstallPath) {
        Move-Item -LiteralPath $InstallPath -Destination $backupPath
    }
    try {
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
        Copy-Item -Path (Join-Path $ReleasePath '*') -Destination $InstallPath -Recurse -Force
        $installedExe = Join-Path $InstallPath 'server_phim.exe'
        if (-not (Test-Path -LiteralPath $installedExe)) { throw 'Installed executable is missing' }

        $shell = New-Object -ComObject WScript.Shell
        $desktopShortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Server Phim.lnk'))
        $desktopShortcut.TargetPath = $installedExe
        $desktopShortcut.WorkingDirectory = $InstallPath
        $desktopShortcut.Description = 'Quản lý media server cục bộ'
        $desktopShortcut.Save()

        $startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Server Phim'
        New-Item -ItemType Directory -Path $startMenu -Force | Out-Null
        $menuShortcut = $shell.CreateShortcut((Join-Path $startMenu 'Server Phim.lnk'))
        $menuShortcut.TargetPath = $installedExe
        $menuShortcut.WorkingDirectory = $InstallPath
        $menuShortcut.Description = 'Quản lý media server cục bộ'
        $menuShortcut.Save()
    } catch {
        if (Test-Path -LiteralPath $InstallPath) {
            Remove-Item -LiteralPath $InstallPath -Recurse -Force
        }
        if (Test-Path -LiteralPath $backupPath) {
            Move-Item -LiteralPath $backupPath -Destination $InstallPath
        }
        throw
    }
}

Write-Output "PASS installed Server Phim at $InstallPath"
Write-Output 'PASS Desktop and Start Menu shortcuts created; autostart unchanged'
