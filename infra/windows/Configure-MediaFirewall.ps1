[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\media-stack.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$ports = @($manifest.publishedLanPorts | ForEach-Object { [string]$_ })
$ruleName = 'MediaServer-WSL-LAN'
$loopbackRuleName = 'MediaServer-WSL-Loopback'
$wslCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'

foreach ($name in @($ruleName, $loopbackRuleName)) {
    if (Get-NetFirewallHyperVRule -Name $name -ErrorAction SilentlyContinue) {
        Remove-NetFirewallHyperVRule -Name $name
    }
}

New-NetFirewallHyperVRule `
    -Name $ruleName `
    -DisplayName 'MediaServer WSL LAN web ports' `
    -Direction Inbound `
    -VMCreatorId $wslCreatorId `
    -Protocol TCP `
    -LocalPorts $ports `
    -RemoteAddresses LocalSubnet `
    -Profiles Private `
    -Action Allow | Out-Null

New-NetFirewallHyperVRule `
    -Name $loopbackRuleName `
    -DisplayName 'MediaServer WSL local browser access' `
    -Direction Inbound `
    -VMCreatorId $wslCreatorId `
    -Protocol TCP `
    -LocalPorts $ports `
    -RemoteAddresses @('127.0.0.1', '::1') `
    -Profiles Any `
    -Action Allow | Out-Null

Write-Output "Hyper-V Firewall allows MediaServer TCP ports: $($ports -join ', ')"
