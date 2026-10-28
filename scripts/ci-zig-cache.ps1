[CmdletBinding()]
param()
# Print ZIG_GLOBAL_CACHE_DIR and ZIG_LOCAL_CACHE_DIR lines for $GITHUB_ENV,
# pointing at caches that outlive the job's checkout. The global cache is
# shared by every job of one Zig version on this machine. The local cache
# belongs to one workspace path, so two checkouts never share one.
#
# Every build adds to these caches and Zig never removes anything, so each
# run first trims them:
# - caches of other Zig versions are removed;
# - a local cache unused for 2 days, or created more than 7 days ago, is
#   removed;
# - when everything together exceeds ZIGGURAT_CI_CACHE_MAX_MB (default
#   12288), or the disk has less than ZIGGURAT_CI_CACHE_MIN_FREE_MB (default
#   8192) free, the local caches are removed, then the global cache.
$ErrorActionPreference = 'Stop'
$version = '0.17.0'
$maxMb = if ($env:ZIGGURAT_CI_CACHE_MAX_MB) { [long]$env:ZIGGURAT_CI_CACHE_MAX_MB } else { 12288 }
$minFreeMb = if ($env:ZIGGURAT_CI_CACHE_MIN_FREE_MB) { [long]$env:ZIGGURAT_CI_CACHE_MIN_FREE_MB } else { 8192 }
$tools = if ($env:ZIGGURAT_TOOLCACHE) { $env:ZIGGURAT_TOOLCACHE } else { Join-Path $env:LOCALAPPDATA 'ziggurat' }
$ci = Join-Path $tools 'ci'
$root = Join-Path $ci "zig-$version"
$workspace = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
$hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($workspace.ToLowerInvariant()))
$key = (-join ($hash[0..7] | ForEach-Object { $_.ToString('x2') }))
$local = Join-Path $root "local-$key"
New-Item -ItemType Directory -Force -Path $root | Out-Null

function Remove-Cache([string]$Path) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
}
function Get-UsedMb {
    $bytes = (Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    [long](($bytes + 0) / 1MB)
}
function Get-FreeMb {
    [long]([System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($root)).AvailableFreeSpace / 1MB)
}
function Test-Over { (Get-UsedMb) -gt $maxMb -or (Get-FreeMb) -lt $minFreeMb }

Get-ChildItem -LiteralPath $ci -Directory -Filter 'zig-*' | Where-Object { $_.Name -ne "zig-$version" } | ForEach-Object { Remove-Cache $_.FullName }
$now = [DateTime]::UtcNow
Get-ChildItem -LiteralPath $root -Directory -Filter 'local-*' | ForEach-Object {
    $created = Join-Path $_.FullName '.created'
    $used = Join-Path $_.FullName '.used'
    if (!(Test-Path -LiteralPath $created) -or (Get-Item -Force -LiteralPath $created).LastWriteTimeUtc -lt $now.AddDays(-7)) {
        Remove-Cache $_.FullName
    } elseif ($_.Name -ne "local-$key" -and (Test-Path -LiteralPath $used) -and (Get-Item -Force -LiteralPath $used).LastWriteTimeUtc -lt $now.AddDays(-2)) {
        Remove-Cache $_.FullName
    }
}

if (Test-Over) {
    Get-ChildItem -LiteralPath $root -Directory -Filter 'local-*' | Where-Object { $_.Name -ne "local-$key" } | ForEach-Object { Remove-Cache $_.FullName }
}
if (Test-Over) { Remove-Cache $local }
if (Test-Over) { Remove-Cache (Join-Path $root 'global') }
Write-Host "ziggurat CI caches: $(Get-UsedMb) MB in $root, $(Get-FreeMb) MB free"

$stamp = Join-Path $local '.created'
if (!(Test-Path -LiteralPath $stamp)) {
    New-Item -ItemType Directory -Force -Path $local | Out-Null
    New-Item -ItemType File -Force -Path $stamp | Out-Null
}
$usedStamp = Join-Path $local '.used'
if (Test-Path -LiteralPath $usedStamp) { (Get-Item -Force -LiteralPath $usedStamp).LastWriteTimeUtc = $now } else { New-Item -ItemType File -Path $usedStamp | Out-Null }
$global = Join-Path $root 'global'
New-Item -ItemType Directory -Force -Path $global | Out-Null
Write-Output "ZIG_GLOBAL_CACHE_DIR=$global"
Write-Output "ZIG_LOCAL_CACHE_DIR=$local"
