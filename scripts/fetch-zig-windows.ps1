[CmdletBinding()]
param()
# Fetch and verify Zig 0.15.2 into a persistent tool cache and print the zig.exe
# path. A self-hosted runner reuses the verified copy across jobs.
$ErrorActionPreference = 'Stop'
$version = '0.15.2'
$expected = '3A0ED1E8799A2F8CE2A6E6290A9FF22E6906F8227865911FB7DDEDC3CC14CB0C'
$cache = if ($env:ZIGGURAT_TOOLCACHE) { $env:ZIGGURAT_TOOLCACHE } else { Join-Path $env:LOCALAPPDATA 'ziggurat' }
$name = "zig-x86_64-windows-$version"
$destination = Join-Path $cache $name
$zig = Join-Path $destination 'zig.exe'
if (Test-Path -LiteralPath $zig) {
    if ((& $zig version) -cne $version) { throw "Cached Zig at $destination is not $version." }
    Write-Output $zig
    exit 0
}
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$archive = Join-Path $cache ("zig-download-" + [Guid]::NewGuid().ToString('N') + '.zip')
$staging = Join-Path $cache ("zig-extract-" + [Guid]::NewGuid().ToString('N'))
try {
    Invoke-WebRequest "https://ziglang.org/download/$version/$name.zip" -OutFile $archive
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw "Zig archive checksum mismatch: $actual" }
    Expand-Archive -LiteralPath $archive -DestinationPath $staging
    # A concurrent job may have finished first; keep its verified copy.
    if (!(Test-Path -LiteralPath $zig)) { Move-Item -LiteralPath (Join-Path $staging $name) -Destination $destination }
} finally {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
if ((& $zig version) -cne $version) { throw 'Wrong Zig version.' }
Write-Output $zig
