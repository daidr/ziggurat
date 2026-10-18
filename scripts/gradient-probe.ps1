param(
    [string]$SdkVersion = '10.0.26100.0',
    [string]$Zig = 'zig'
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10'
$compiler = Join-Path $sdkRoot "bin/$SdkVersion/x64/fxc.exe"
$includes = Join-Path $sdkRoot "Include/$SdkVersion/um"
if (!(Test-Path -LiteralPath $compiler) -or !(Test-Path -LiteralPath (Join-Path $includes 'd2d1effecthelpers.hlsli'))) { throw "Windows SDK $SdkVersion shader compiler/headers are required for this offline probe." }
$output = Join-Path $taskRoot '.zig-cache/gradient-probe'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$header = Join-Path $output 'gradient_probe_shader.h'
$shader = Join-Path $taskRoot 'tests/gradient_effect_probe.hlsl'
& $compiler /nologo /Ges /Gis /O3 /T ps_4_0 /E main /I $includes /Fh $header /Vn gradient_probe_shader $shader
if ($LASTEXITCODE -ne 0) { throw 'Shader compilation failed.' }
$executable = Join-Path $output 'gradient-effect-probe.exe'
& $Zig cc -std=c11 -O2 '-ffp-contract=off' '-I' $output (Join-Path $taskRoot 'tests/gradient_effect_probe.c') -ld3d11 -ldxgi -ld2d1 -lgdi32 -luser32 '-o' $executable
if ($LASTEXITCODE -ne 0) { throw 'Native probe compilation failed.' }
$metadata = [ordered]@{ schema = 1; sdk = $SdkVersion; compiler_version = (Get-Item -LiteralPath $compiler).VersionInfo.FileVersion; source_sha256 = (Get-FileHash -LiteralPath $shader -Algorithm SHA256).Hash.ToLowerInvariant(); generated_header_sha256 = (Get-FileHash -LiteralPath $header -Algorithm SHA256).Hash.ToLowerInvariant(); flags = @('/Ges','/Gis','/O3','/T','ps_4_0','/E','main') }
$metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'build.json') -Encoding utf8NoBOM
& $executable
if ($LASTEXITCODE -ne 0) { throw "Native probe failed: $LASTEXITCODE" }
