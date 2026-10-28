[CmdletBinding()]
param()
# Print ZIG_GLOBAL_CACHE_DIR and ZIG_LOCAL_CACHE_DIR lines for $GITHUB_ENV,
# pointing at caches that outlive the job's checkout. The global cache is
# shared by every job of one Zig version on this machine. The local cache
# belongs to one workspace path, so two checkouts never share one, and it is
# emptied once a week so it cannot grow without bound.
$ErrorActionPreference = 'Stop'
$version = '0.17.0'
$tools = if ($env:ZIGGURAT_TOOLCACHE) { $env:ZIGGURAT_TOOLCACHE } else { Join-Path $env:LOCALAPPDATA 'ziggurat' }
$root = Join-Path $tools "ci\zig-$version"
$workspace = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
$hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($workspace.ToLowerInvariant()))
$key = (-join ($hash[0..7] | ForEach-Object { $_.ToString('x2') }))
$local = Join-Path $root "local-$key"
$stamp = Join-Path $local '.created'
if ((Test-Path -LiteralPath $stamp) -and ((Get-Item -LiteralPath $stamp).LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-7))) {
    Remove-Item -LiteralPath $local -Recurse -Force
}
if (!(Test-Path -LiteralPath $stamp)) {
    New-Item -ItemType Directory -Force -Path $local | Out-Null
    New-Item -ItemType File -Force -Path $stamp | Out-Null
}
$global = Join-Path $root 'global'
New-Item -ItemType Directory -Force -Path $global | Out-Null
Write-Output "ZIG_GLOBAL_CACHE_DIR=$global"
Write-Output "ZIG_LOCAL_CACHE_DIR=$local"
