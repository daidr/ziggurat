#requires -Version 7.1
[CmdletBinding()]
param(
    [ValidateSet('gdi', 'hardware', 'warp')][string[]]$Renderer = @('gdi', 'hardware', 'warp'),
    [ValidateRange(1, 100)][int]$Repetitions = 3,
    [ValidateRange(1, 120000)][int]$IdleMilliseconds = 500,
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')][string]$Optimize = 'ReleaseFast',
    [string]$ZigPath = 'zig',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../zig-out/benchmarks'),
    [switch]$Visible
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'This driver measures the Windows workload; use the Linux workload on Linux.' }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($output)
$zig = (Get-Command $ZigPath -ErrorAction Stop).Source
$version = (& $zig version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $version -cne '0.17.0') { throw 'Benchmark requires Zig 0.17.0.' }
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$system = Get-CimInstance Win32_ComputerSystem
$graphics = @(Get-CimInstance Win32_VideoController | ForEach-Object { [ordered]@{ name = $_.Name; driver_version = $_.DriverVersion } })
$sourcePaths = @('tools/benchmark_windows.zig', 'src/ui/root.zig', 'src/ui/windows.zig', 'src/ui/d3d11.zig', 'src/ui/d3d11.c', 'src/platform/windows.zig', 'src/root.zig', 'build.zig')
$sources = @($sourcePaths | ForEach-Object { [ordered]@{ path = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash.ToLowerInvariant() } })
$runs = [Collections.Generic.List[object]]::new()
$prefix = Join-Path $output ('bin-' + $Optimize)
Push-Location -LiteralPath $root
try {
    foreach ($mode in $Renderer) {
        for ($iteration = 1; $iteration -le $Repetitions; $iteration++) {
            $path = Join-Path $output ("$mode-$iteration.json")
            $arguments = @('build', 'benchmark', '-Dgpu=true', "-Doptimize=$Optimize", '--prefix', $prefix, '--', '--output', $path, '--idle-ms', $IdleMilliseconds.ToString([Globalization.CultureInfo]::InvariantCulture))
            if ($mode -ceq 'gdi') { $arguments += '--software' }
            if ($mode -ceq 'warp') { $arguments += '--warp' }
            if ($Visible) { $arguments += '--visible' }
            $log = & $zig @arguments 2>&1
            if ($LASTEXITCODE -ne 0) { $log | ForEach-Object { Write-Host $_ }; throw "Benchmark failed for $mode, iteration $iteration." }
            $sample = [IO.File]::ReadAllText($path) | ConvertFrom-Json
            if ($sample.schema -ne 1 -or $sample.os -cne 'windows' -or $sample.display_latency_measured -or $sample.visible -ne [bool]$Visible) { throw 'Unexpected benchmark schema or measurement claims.' }
            if ($sample.idle_wall_ns -le 0 -or $sample.paint_submission_p50_ns -gt $sample.paint_submission_p95_ns -or $sample.paint_submission_p95_ns -gt $sample.paint_submission_p99_ns) { throw 'Invalid benchmark sample.' }
            if ($sample.requested_idle_ms -ne $IdleMilliseconds -or $sample.idle_wall_ns -lt ([long]$IdleMilliseconds * 1000000)) { throw 'Benchmark did not measure the requested idle duration.' }
            if ($sample.draw_callbacks -lt $sample.workload_draw_callbacks) { throw 'Total draw count is smaller than the recorded workload.' }
            $executable = Join-Path $prefix 'bin/benchmark.exe'
            $runs.Add([ordered]@{
                renderer = $mode
                iteration = $iteration
                command = @($zig) + $arguments
                executable_sha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
                sample_file = [IO.Path]::GetFileName($path)
                idle_cpu_fraction_one_core = [double]$sample.idle_cpu_ns / [double]$sample.idle_wall_ns
                measurements = $sample
            })
            Write-Host ("{0} #{1}: submit p50={2}ns p95={3}ns; GPU={4} GDI={5} fallback={6} deferred={7} busy={8}" -f $mode, $iteration, $sample.paint_submission_p50_ns, $sample.paint_submission_p95_ns, $sample.gpu_frames, $sample.gdi_frames, $sample.fallbacks, $sample.deferred_frames, $sample.busy_presents)
        }
    }
} finally { Pop-Location }
foreach ($source in $sources) {
    if ((Get-FileHash -LiteralPath (Join-Path $root $source.path) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $source.sha256) {
        throw 'Benchmark sources changed during measurement; rerun with stable sources.'
    }
}
$report = [ordered]@{
    schema_version = 1
    measured_at_utc = [DateTime]::UtcNow.ToString('o')
    revision = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { $null }
    toolchain = [ordered]@{ zig_version = $version; zig_path = $zig; optimize = $Optimize; gpu_compiled = $true }
    environment = [ordered]@{
        os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        processor = $cpu.Name
        logical_processors = [Environment]::ProcessorCount
        physical_memory_bytes = $system.TotalPhysicalMemory
        graphics = $graphics
        powershell = $PSVersionTable.PSVersion.ToString()
    }
    visible = [bool]$Visible
    requested_idle_ms = $IdleMilliseconds
    display_latency_measured = $false
    measurement_scope = 'CPU time to synchronously submit WM_PAINT, including command generation/replay or deferred-frame merge. Counters distinguish actual drawn frames, fallback, and backpressure; these samples do not measure presentation or input-to-display latency.'
    idle_scope = 'Process CPU over an event-loop interval after 200 ms settling; fraction is relative to one CPU core. One owned worker waits for the UI start acknowledgement, sleeps for the requested interval, then posts stop. Workload and whole-run draw counters are recorded separately.'
    sources = $sources
    source_hash_scope = 'Selected build and rendering source files; executable SHA-256 identifies each measured compiled artifact.'
    runs = $runs.ToArray()
}
$reportPath = Join-Path $output 'benchmark.json'
[IO.File]::WriteAllText($reportPath, (($report | ConvertTo-Json -Depth 12).Replace("`r`n", "`n")) + "`n", [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ report = $reportPath; runs = $runs.Count; display_latency_measured = $false }
