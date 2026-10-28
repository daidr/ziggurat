[CmdletBinding()]
param()
# Print the path of a verified Zig 0.17.0 zig.exe, fetching it into a
# persistent tool cache only when no matching copy exists. A zig on PATH or
# in the cache that reports the pinned version is reused as is, so a
# self-hosted runner downloads it once.
$ErrorActionPreference = 'Stop'
$version = '0.17.0'
$expected = 'B5663F69581DCF391293FBF16C06CB80D81D806545CE618B4D0BAB7F0EB8C428'
$cache = if ($env:ZIGGURAT_TOOLCACHE) { $env:ZIGGURAT_TOOLCACHE } else { Join-Path $env:LOCALAPPDATA 'ziggurat' }
$name = "zig-x86_64-windows-$version"
$destination = Join-Path $cache $name
$zig = Join-Path $destination 'zig.exe'

function Get-ZigVersion([string]$path) {
    try { return (& $path version 2>$null | Out-String).Trim() } catch { return '' }
}

$found = Get-Command zig -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($found -and (Get-ZigVersion $found.Source) -ceq $version) {
    Write-Output $found.Source
    exit 0
}
if (Test-Path -LiteralPath $zig) {
    if ((Get-ZigVersion $zig) -ceq $version) {
        Write-Output $zig
        exit 0
    }
    Write-Warning "Cached Zig at $destination is damaged; fetching it again."
}
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$archive = Join-Path $cache ("zig-download-" + [Guid]::NewGuid().ToString('N') + '.zip')
$staging = Join-Path $cache ("zig-extract-" + [Guid]::NewGuid().ToString('N'))
# The official server first, then community mirrors; the checksum decides.
$mirrors = if ($env:ZIGGURAT_ZIG_MIRRORS) { $env:ZIGGURAT_ZIG_MIRRORS -split '\s+' } else {
    @("https://ziglang.org/download/$version", 'https://pkg.machengine.org/zig', 'https://zig.linus.dev/zig')
}
try {
    $fetched = $false
    foreach ($mirror in $mirrors) {
        try {
            # A stalled server is abandoned instead of holding the job.
            Invoke-WebRequest "$mirror/$name.zip" -OutFile $archive -TimeoutSec 300 -MaximumRetryCount 2 -RetryIntervalSec 5
            $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
            if ($actual -eq $expected) { $fetched = $true; break }
            Write-Warning "Zig archive from $mirror did not verify: $actual"
        } catch {
            Write-Warning "Download from $mirror failed: $($_.Exception.Message)"
        }
    }
    if (!$fetched) { throw "No mirror produced a verified $name." }
    Expand-Archive -LiteralPath $archive -DestinationPath $staging
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    # A concurrent job may have finished first; either verified copy will do.
    if (!(Test-Path -LiteralPath $zig)) { Move-Item -LiteralPath (Join-Path $staging $name) -Destination $destination }
} finally {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
if ((Get-ZigVersion $zig) -cne $version) { throw 'Wrong Zig version.' }
Write-Output $zig
