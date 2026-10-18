[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$version = '1.6.0'
$expected = 'E4AB7009BF0629FD11982D4C2AA83964CF244CFFBA7347ECD39019A9E38C4564'
$root = Split-Path -Parent $PSScriptRoot
$deps = Join-Path $root '.deps'
$archive = Join-Path $deps "libwebp-$version.tar.gz"
New-Item -ItemType Directory -Force -Path $deps | Out-Null
if (!(Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$version.tar.gz" -OutFile $archive
}
$actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw "WebP source checksum mismatch: $actual" }
& tar -xzf $archive -C $deps
if ($LASTEXITCODE -ne 0) { throw 'WebP source extraction failed' }
Write-Output "Verified libwebp $version source at $(Join-Path $deps "libwebp-$version")"
