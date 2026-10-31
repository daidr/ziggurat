# Reports and ends test or smoke processes of this checkout that have run
# for more than $Minutes (the build runner aside), so a hung one fails its build step by name
# instead of holding the job until its timeout.
param([int]$Minutes = 15)
$root = (Get-Location).Path
while ($true) {
    Start-Sleep -Seconds 60
    $limit = (Get-Date).AddMinutes(-$Minutes)
    Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and
        ($_.ExecutablePath -like '*\zig-out\*' -or $_.ExecutablePath -like '*\.zig-cache\o\*') -and
        $_.Name -ne 'build.exe' -and $_.CreationDate -lt $limit
    } | ForEach-Object {
        Write-Host "ci-hang-report: ending process $($_.ProcessId) (parent $($_.ParentProcessId)), running since $($_.CreationDate): $($_.CommandLine)"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
