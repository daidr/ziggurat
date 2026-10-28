param([string] $ZigPath = 'zig')
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$zig = (Get-Command $ZigPath -ErrorAction Stop).Source
if ((& $zig version | Out-String).Trim() -cne '0.17.0' -or $LASTEXITCODE -ne 0) { throw 'Header cache regression requires Zig 0.17.0.' }
$work = Join-Path $project ('.zig-cache/managed/native-header-check-' + [Guid]::NewGuid().ToString('N'))
$fixture = Join-Path $work 'fixture'
New-Item -ItemType Directory -Path $fixture | Out-Null
Copy-Item -LiteralPath (Join-Path $project 'build_support/native.zig') -Destination (Join-Path $work 'native.zig')
Copy-Item -LiteralPath (Join-Path $project 'build_support/native_header_fixture.zig') -Destination (Join-Path $work 'build.zig')
foreach ($name in @('helper.zig', 'main.zig', 'value.c', 'first.h', 'second.h')) {
    Copy-Item -LiteralPath (Join-Path $project "tests/native_header_cache/$name") -Destination (Join-Path $fixture $name)
}
$cache = Join-Path $project '.zig-cache/managed/native-header-check-cache'
# Zig 0.17 takes the global cache only from the environment.
if (!$env:ZIG_GLOBAL_CACHE_DIR) { $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $project '.zig-cache/managed/windows-global' }
Push-Location -LiteralPath $work
try {
    foreach ($linkage in @('object', 'archive')) {
        foreach ($expected in @(17, 29)) {
            [IO.File]::WriteAllText((Join-Path $fixture 'second.h'), "#define ZIGGURAT_HEADER_VALUE $expected`n", [Text.UTF8Encoding]::new($false))
            $archive = if ($linkage -eq 'archive') { 'true' } else { 'false' }
            $output = & $zig build run "-Darchive=$archive" -j1 --cache-dir $cache --summary all 2>&1
            $code = $LASTEXITCODE
            $output | Out-File -LiteralPath (Join-Path $work "$linkage-value-$expected.log") -Encoding utf8
            if ($code -ne 0) { throw "Native $linkage header build failed; inspect $work" }
            if (($output | Out-String) -notmatch "(?m)^native_header_value=$expected\r?$") {
                throw "Indirect $linkage header was stale; expected $expected; inspect $work"
            }
        }
    }
} finally {
    Pop-Location
}
Write-Output "Indirect native header rebuild passed for object and archive (17 -> 29), evidence: $work"
