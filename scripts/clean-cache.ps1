[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Project', 'Global', 'All')][string]$Scope = 'Project',
    [string]$CacheRoot,
    [ValidateRange(0, 87600)][double]$OlderThanHours = 24,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Preview by default. Only known generated children of cache roots are selected.
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$projectCache = Join-Path $project '.zig-cache'
$generated = @('o', 'h', 'z', 'tmp', 'b')
$cutoff = [DateTime]::UtcNow.AddHours(-$OlderThanHours)

function Get-PlainDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    return $item
}

function Get-CacheChildren([string]$Path) {
    $root = Get-PlainDirectory $Path
    if ($null -eq $root) { return }
    foreach ($name in $generated) {
        $child = Get-PlainDirectory (Join-Path $root.FullName $name)
        if ($null -eq $child) { continue }
        $expected = [IO.Path]::GetFullPath((Join-Path $root.FullName $name))
        if (-not [string]::Equals($child.FullName, $expected, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Cache path escaped its registered parent: $($child.FullName)"
        }
        # Do not traverse junctions/symlinks anywhere inside a removal candidate.
        $stack = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
        $stack.Push($child)
        $recent = $child.LastWriteTimeUtc -gt $cutoff
        $linked = $false
        [long]$bytes = 0
        while ($stack.Count -gt 0 -and -not $recent -and -not $linked) {
            $directory = $stack.Pop()
            if ($directory.LastWriteTimeUtc -gt $cutoff) { $recent = $true }
            foreach ($entry in $directory.EnumerateFileSystemInfos()) {
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { $linked = $true; continue }
                if ($entry.LastWriteTimeUtc -gt $cutoff) { $recent = $true }
                if ($entry -is [IO.DirectoryInfo]) { $stack.Push($entry) }
                else { $bytes += $entry.Length }
            }
        }
        [pscustomobject]@{ Path = $expected; Bytes = $bytes; Recent = $recent; Linked = $linked }
    }
}

$roots = [Collections.Generic.List[string]]::new()
if ($Scope -in @('Project', 'All')) {
    $roots.Add($projectCache)
    $base = Get-PlainDirectory $projectCache
    if ($null -ne $base) {
        foreach ($child in $base.EnumerateDirectories()) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            # Checkpoints, logs, source probes, installed outputs and images are preserved.
            if ($child.Name -like 'checkpoint-*') { continue }
            if ((Test-Path -LiteralPath (Join-Path $child.FullName 'h') -PathType Container) -and
                (Test-Path -LiteralPath (Join-Path $child.FullName 'o') -PathType Container)) { $roots.Add($child.FullName) }
        }
    }
    $managed = $null
    if ($null -ne $base) { $managed = Get-PlainDirectory (Join-Path $projectCache 'managed') }
    if ($null -ne $managed) {
        foreach ($child in $managed.EnumerateDirectories()) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($child.Name -match '^(windows|linux)-.*(cache|global)$') { $roots.Add($child.FullName) }
        }
    }
}
if ($Scope -in @('Global', 'All')) {
    if ([string]::IsNullOrEmpty($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable.' }
    $roots.Add((Join-Path $env:LOCALAPPDATA 'zig'))
}

if ($PSBoundParameters.ContainsKey('CacheRoot')) {
    if ([string]::IsNullOrWhiteSpace($CacheRoot)) { throw 'CacheRoot must name an existing recognized cache.' }
    $requested = [IO.Path]::GetFullPath($CacheRoot)
    $plain = Get-PlainDirectory $requested
    $selectedRoots = @($roots | Select-Object -Unique | Where-Object {
        [string]::Equals([IO.Path]::GetFullPath($_), $requested, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($null -eq $plain -or $selectedRoots.Count -ne 1) { throw 'CacheRoot is not an existing recognized cache in the selected Scope.' }
    $roots.Clear()
    $roots.Add($selectedRoots[0])
}
$candidates = @($roots | Select-Object -Unique | ForEach-Object { Get-CacheChildren $_ })
function Assert-CachesIdle {
    # Windows cannot enumerate WSL ELF processes. Require WSL to be stopped here;
    # Linux cleanup has its own /proc checks and can be run inside WSL instead.
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        $running = @(& wsl.exe --list --running --quiet)
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect running WSL distributions.' }
        if (($running -join '').Replace([string][char]0, '').Trim().Length -gt 0) {
            throw 'WSL is running. Use clean-cache.sh inside WSL, or stop WSL after all builds/tests finish.'
        }
    }
    $processes = @(Get-CimInstance Win32_Process)
    foreach ($process in $processes) {
        if ($process.Name -in @('zig.exe', 'zig')) { throw 'A Zig compiler is running. Wait for builds/tests to finish.' }
        if (-not $process.ExecutablePath) { continue }
        foreach ($root in $roots) {
            if ($process.ExecutablePath.StartsWith($root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar,
                    [StringComparison]::OrdinalIgnoreCase)) { throw 'A cached executable is running. Wait for builds/tests to finish.' }
        }
    }
}
if ($Apply) { Assert-CachesIdle }

[long]$selected = 0
foreach ($candidate in $candidates) {
    if ($candidate.Linked -or $candidate.Recent) {
        Write-Output "KEEP $($candidate.Path) (recent or contains a reparse point)"
        continue
    }
    $selected += $candidate.Bytes
    Write-Output ("{0} {1} ({2:N1} MiB)" -f $(if ($Apply) { 'SELECT' } else { 'PREVIEW' }), $candidate.Path, ($candidate.Bytes / 1MB))
    if ($Apply -and $PSCmdlet.ShouldProcess($candidate.Path, 'Remove generated Zig cache directory')) {
        # Confirmation can take arbitrarily long: repeat the full inspection.
        Assert-CachesIdle
        $fresh = @(Get-CacheChildren (Split-Path -Parent $candidate.Path) | Where-Object { $_.Path -eq $candidate.Path })
        if ($fresh.Count -ne 1 -or $fresh[0].Recent -or $fresh[0].Linked) {
            Write-Output "KEEP $($candidate.Path) (changed during cleanup)"
            continue
        }
        $item = Get-PlainDirectory $candidate.Path
        if ($null -eq $item -or $item.FullName -ne $candidate.Path) { throw 'Cache changed during cleanup.' }
        Assert-CachesIdle
        Remove-Item -LiteralPath $candidate.Path -Recurse -Force
    }
}
Write-Output ("Selected {0:N1} MiB. Mode: {1}." -f ($selected / 1MB), $(if ($Apply) { 'apply' } else { 'preview' }))
