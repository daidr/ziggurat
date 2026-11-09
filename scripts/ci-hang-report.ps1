# Reports and ends test or smoke processes of this checkout that have run
# for more than $Minutes (the build runner aside), so a hung one fails its build step by name
# instead of holding the job until its timeout. Executables built into the Zig
# caches count too, wherever ZIG_LOCAL_CACHE_DIR and ZIG_GLOBAL_CACHE_DIR put
# them. A compiler process that runs that long is only reported.
param([int]$Minutes = 15)
$root = (Get-Location).Path
$owned = @((Join-Path $root 'zig-out'), (Join-Path $root '.zig-cache'))
foreach ($cache in $env:ZIG_LOCAL_CACHE_DIR, $env:ZIG_GLOBAL_CACHE_DIR) {
    if ($cache) { $owned += [System.IO.Path]::GetFullPath($cache) }
}
$owned = $owned | ForEach-Object { $_.TrimEnd('\') + '\' }
$reported = @{}
while ($true) {
    Start-Sleep -Seconds 60
    $limit = (Get-Date).AddMinutes(-$Minutes)
    Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.CreationDate -lt $limit } | ForEach-Object {
        $path = $_.ExecutablePath
        $built = $owned | Where-Object { $path.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }
        if ($built -and $_.Name -ne 'build.exe' -and $_.Name -ne 'maker.exe') {
            Write-Host "ci-hang-report: ending process $($_.ProcessId) (parent $($_.ParentProcessId)), running since $($_.CreationDate): $($_.CommandLine)"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        } elseif ($_.Name -eq 'zig.exe' -and !$reported.ContainsKey($_.ProcessId)) {
            $reported[$_.ProcessId] = $true
            Write-Host "ci-hang-report: compiler process $($_.ProcessId) running since $($_.CreationDate): $($_.CommandLine)"
        }
    }
}
