[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipDistroInstall,
    [switch]$SkipFirewall,
    [switch]$AllowWslShutdown,
    [switch]$PreflightOnly
)

$ErrorActionPreference = 'Stop'
$infraRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $infraRoot
$manifest = Get-Content (Join-Path $infraRoot 'config\media-stack.json') -Raw | ConvertFrom-Json
$distroName = [string]$manifest.distroName
$distroPath = [string]$manifest.distroPath
$mediaRoot = [string]$manifest.mediaRoot
$minimumFreeBytes = 80GB
$lxssRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'

function Get-WslDistroNames {
    @(wsl.exe --list --quiet 2>$null) | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ }
}

function Get-DefaultDistributionName {
    $root = Get-ItemProperty -LiteralPath $lxssRoot
    $defaultId = [string]$root.DefaultDistribution
    foreach ($key in Get-ChildItem -LiteralPath $lxssRoot) {
        if ($key.PSChildName.Trim('{}') -eq $defaultId.Trim('{}')) {
            return [string](Get-ItemProperty -LiteralPath $key.PSPath).DistributionName
        }
    }
    return $null
}

function Set-Wsl2IniValue {
    param([string]$Content, [string]$Key, [string]$Value)
    $sectionPattern = '(?ms)^\[wsl2\]\s*\r?\n(?<body>.*?)(?=^\[|\z)'
    if ($Content -notmatch $sectionPattern) {
        return ($Content.TrimEnd() + "`r`n`r`n[wsl2]`r`n$Key=$Value`r`n")
    }
    $section = $Matches[0]
    $keyPattern = "(?mi)^$([regex]::Escape($Key))\s*=.*$"
    if ($section -match $keyPattern) {
        $newSection = [regex]::Replace($section, $keyPattern, "$Key=$Value")
    } else {
        $newSection = $section.TrimEnd() + "`r`n$Key=$Value`r`n"
    }
    return $Content.Replace($section, $newSection)
}

$drive = [System.IO.DriveInfo]::new(([System.IO.Path]::GetPathRoot($distroPath)))
if ($drive.AvailableFreeSpace -lt $minimumFreeBytes) {
    throw "Distro drive needs at least 80GB free; found $([math]::Round($drive.AvailableFreeSpace/1GB, 1))GB"
}

$existingDistros = Get-WslDistroNames
$targetRegistered = $existingDistros -contains $distroName
$targetExists = Test-Path -LiteralPath $distroPath
$targetNonEmpty = $targetExists -and @(Get-ChildItem -LiteralPath $distroPath -Force -ErrorAction Stop).Count -gt 0
$defaultBefore = Get-DefaultDistributionName

if ($SkipDistroInstall) {
    if (-not $targetRegistered) { throw "$distroName is not registered; cannot skip distro install" }
} else {
    if ($targetRegistered) { throw "$distroName is already registered; rerun with -SkipDistroInstall" }
    if ($targetNonEmpty) { throw "$distroPath exists and is not empty; refusing to reuse it" }
    $online = ((wsl.exe --list --online) -replace "`0", '') -join "`n"
    if ($online -notmatch 'Ubuntu-24\.04') { throw 'Ubuntu-24.04 is not available from wsl --list --online' }
}

if ($PreflightOnly) {
    Write-Output "PASS preflight: $distroName can be installed at $distroPath"
    Write-Output "PASS free space: $([math]::Round($drive.AvailableFreeSpace/1GB, 1))GB"
    Write-Output "PASS current default distro: $defaultBefore"
    return
}

New-Item -ItemType Directory -Path (Split-Path -Parent $distroPath) -Force | Out-Null
$mediaDirectories = @(
    'downloads\torrents\movies', 'downloads\torrents\tv', 'downloads\torrents\music',
    'downloads\usenet\incomplete', 'downloads\usenet\complete\movies',
    'downloads\usenet\complete\tv', 'downloads\usenet\complete\music',
    'library\movies', 'library\tv', 'library\music'
)
foreach ($relative in $mediaDirectories) {
    New-Item -ItemType Directory -Path (Join-Path $mediaRoot $relative) -Force | Out-Null
}

if (-not $SkipDistroInstall -and $PSCmdlet.ShouldProcess($distroPath, 'Install Ubuntu-24.04 as MediaServer')) {
    wsl.exe --install Ubuntu-24.04 --name MediaServer --location $distroPath --no-launch
    if ($LASTEXITCODE -ne 0) { throw "WSL install failed with exit code $LASTEXITCODE" }
}

$distroKey = Get-ChildItem -LiteralPath $lxssRoot | Where-Object {
    (Get-ItemProperty -LiteralPath $_.PSPath).DistributionName -eq $distroName
} | Select-Object -First 1
if (-not $distroKey) { throw "Could not find registry entry for $distroName" }
$registeredBasePath = [string](Get-ItemProperty -LiteralPath $distroKey.PSPath).BasePath
if (-not ([System.IO.Path]::GetFullPath($registeredBasePath).StartsWith([System.IO.Path]::GetFullPath($distroPath), [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "MediaServer BasePath is not under ${distroPath}: $registeredBasePath"
}

$initializerWindows = (Resolve-Path (Join-Path $infraRoot 'linux\initialize-wsl.sh')).Path
$initializerDrive = $initializerWindows.Substring(0, 1).ToLowerInvariant()
$initializerTail = $initializerWindows.Substring(2).Replace('\', '/')
$initializerLinux = '/mnt/' + $initializerDrive + $initializerTail
wsl.exe -d $distroName -u root -- bash $initializerLinux
if ($LASTEXITCODE -ne 0) { throw 'WSL user initialization failed' }
wsl.exe --manage $distroName --set-default-user media
if ($LASTEXITCODE -ne 0) { throw 'Failed to set default WSL user' }

if ($defaultBefore -and (Get-DefaultDistributionName) -ne $defaultBefore) {
    wsl.exe --set-default $defaultBefore
    if ($LASTEXITCODE -ne 0) { throw "Failed to restore default distro $defaultBefore" }
}

$wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
$content = if (Test-Path -LiteralPath $wslConfig) { Get-Content -LiteralPath $wslConfig -Raw } else { '' }
$updated = Set-Wsl2IniValue -Content $content -Key 'networkingMode' -Value 'mirrored'
$updated = Set-Wsl2IniValue -Content $updated -Key 'firewall' -Value 'true'
if ($updated -ne $content -and $PSCmdlet.ShouldProcess($wslConfig, 'Enable mirrored WSL networking')) {
    if (Test-Path -LiteralPath $wslConfig) {
        Copy-Item -LiteralPath $wslConfig -Destination "$wslConfig.$(Get-Date -Format yyyyMMdd-HHmmss).bak"
    }
    Set-Content -LiteralPath $wslConfig -Value $updated -Encoding ASCII
}

$otherRunning = @(wsl.exe --list --running --quiet) |
    ForEach-Object { ($_ -replace "`0", '').Trim() } |
    Where-Object { $_ -and $_ -ne $distroName }
if ($otherRunning.Count -gt 0 -and -not $AllowWslShutdown) {
    throw "A one-time WSL shutdown is required. Running: $($otherRunning -join ', '). Rerun with -AllowWslShutdown."
}
if ($PSCmdlet.ShouldProcess('all WSL distros', 'Apply WSL networking/systemd configuration')) {
    wsl.exe --shutdown
}

Write-Output "PASS installed $distroName at $registeredBasePath"
Write-Output "PASS media root $mediaRoot"
Write-Output "PASS previous default distro $defaultBefore preserved"
