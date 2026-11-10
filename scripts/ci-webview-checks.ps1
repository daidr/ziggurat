# Runs each named build step on its own, one after another, and reports how
# long each took. WebView2 checks share one machine with a single desktop and
# start real browser processes whose shutdown they wait for: beside compiles
# and other browsers, those waits measure the machine's load, not the code.
# Build every check first, then run them here.
#
# A step still running after $Minutes is ended with its process tree, so a
# hang fails by name and the remaining checks still run. Exits 1 when any
# step failed.
param(
    [Parameter(Mandatory = $true)][string[]]$Steps,
    [string[]]$Options = @(),
    [int]$Minutes = 5
)
$zig = (Get-Command zig -ErrorAction Stop).Source
$results = @()
foreach ($step in $Steps) {
    Write-Host "::group::$step"
    $info = [System.Diagnostics.ProcessStartInfo]::new($zig)
    $info.UseShellExecute = $false
    $info.ArgumentList.Add('build')
    $info.ArgumentList.Add('-j1')
    $info.ArgumentList.Add($step)
    foreach ($option in $Options) { $info.ArgumentList.Add($option) }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $process = [System.Diagnostics.Process]::Start($info)
    $outcome = 'passed'
    if (-not $process.WaitForExit($Minutes * 60 * 1000)) {
        $outcome = 'timed out'
        Write-Host "$step is still running after $Minutes minutes; ending its process tree"
        & taskkill.exe /T /F /PID $process.Id | Out-Host
        $process.WaitForExit()
    } elseif ($process.ExitCode -ne 0) {
        $outcome = "failed ($($process.ExitCode))"
    }
    $clock.Stop()
    Write-Host '::endgroup::'
    $seconds = [math]::Round($clock.Elapsed.TotalSeconds, 1)
    Write-Host "$step $outcome in $seconds s"
    if ($outcome -ne 'passed') { Write-Host "::error::$step $outcome" }
    $results += [pscustomobject]@{ Step = $step; Result = $outcome; Seconds = $seconds }
}
$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
if ($results | Where-Object { $_.Result -ne 'passed' }) { exit 1 }
exit 0
