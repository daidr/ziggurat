#Requires -Version 7
# Install, launch, upgrade, refuse downgrade, uninstall and purge a fixture
# through the real setup program. LOCALAPPDATA and APPDATA point into a private
# temporary directory; the only shared state is one HKCU uninstall key with a
# test identity, which the uninstaller removes and `finally` double-checks.
# Run after `zig build build-setup-smoke`.
param([string]$Bin = 'zig-out/bin')
$ErrorActionPreference = 'Stop'
$Bin = (Resolve-Path $Bin).Path
$id = 'org.ziggurat.SetupSmoke'
$key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$id"
$work = Join-Path ([IO.Path]::GetTempPath()) ("ziggurat-setup-smoke-" + [Guid]::NewGuid().ToString('N'))
$savedLocal = $env:LOCALAPPDATA
$savedRoaming = $env:APPDATA

function Invoke-Checked([string]$File, [string[]]$Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File $($Arguments -join ' ') exited with $LASTEXITCODE" }
}
function Wait-Until([scriptblock]$Condition, [string]$What) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (& $Condition)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw "timed out waiting for $What" }
        Start-Sleep -Milliseconds 200
    }
}

try {
    New-Item -ItemType Directory -Path $work, "$work/v1", "$work/v2", "$work/local", "$work/roaming" | Out-Null
    $env:LOCALAPPDATA = "$work/local"
    $env:APPDATA = "$work/roaming"
    Copy-Item "$Bin/setup-fixture-1.0.0.exe" "$work/v1/fixture.exe"
    Copy-Item "$Bin/setup-fixture-1.1.0.exe" "$work/v2/fixture.exe"
    Set-Content -NoNewline -Path "$work/LICENSE.txt" -Value 'Test fixture only.'
    foreach ($pair in @(@('v1', '1.0.0.0'), @('v2', '1.1.0.0'))) {
        Invoke-Checked "$Bin/ziggurat-update.exe" @('pack', "$work/$($pair[0]).zip", 'Setup Smoke', $id, 'windows-x86_64', $pair[1], 'fixture.exe', "$work/$($pair[0])/fixture.exe", "$work/LICENSE.txt")
        Invoke-Checked "$Bin/ziggurat.exe" @('package', 'setup', '--zip', "$work/$($pair[0]).zip", '--stub', "$Bin/ziggurat-setup.exe", '--publisher', 'Ziggurat tests', '--output', "$work/setup-$($pair[0]).exe")
    }
    $root = "$work/local/Programs/$id"
    $shortcut = "$work/roaming/Microsoft/Windows/Start Menu/Programs/Setup Smoke.lnk"

    New-Item -ItemType Directory -Path "$work/occupied" | Out-Null
    Set-Content -Path "$work/occupied/file.txt" -Value 'keep'
    & "$work/setup-v1.exe" --silent --dir "$work/occupied"
    if ($LASTEXITCODE -eq 0 -or (Test-Path "$work/occupied/install.json") -or -not (Test-Path "$work/occupied/file.txt")) { throw 'installed into a non-empty directory' }

    Invoke-Checked "$work/setup-v1.exe" @('--silent')
    foreach ($path in @("$root/fixture.exe", "$root/uninstall.exe", "$root/releases/windows-x86_64-1.0.0.0/fixture.exe", $shortcut)) {
        if (-not (Test-Path $path)) { throw "missing $path" }
    }
    $entry = Get-ItemProperty $key
    if ($entry.DisplayVersion -ne '1.0.0.0' -or $entry.DisplayName -ne 'Setup Smoke' -or $entry.Publisher -ne 'Ziggurat tests') { throw 'unexpected uninstall entry' }
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
    if ([IO.Path]::GetFullPath($link.TargetPath) -ne [IO.Path]::GetFullPath("$root/fixture.exe")) { throw "shortcut targets $($link.TargetPath)" }

    $env:ZIGGURAT_SETUP_SMOKE_OUT = "$work/out.txt"
    Invoke-Checked "$root/fixture.exe" @('hello', 'two words')
    Wait-Until { Test-Path "$work/out.txt" } 'the launched fixture'
    Wait-Until { (Get-Content -Raw "$work/out.txt").Trim() -eq '1.0.0 hello two words' } 'fixture output'

    Invoke-Checked "$work/setup-v2.exe" @('--silent')
    if ((Get-ItemProperty $key).DisplayVersion -ne '1.1.0.0') { throw 'upgrade did not update the uninstall entry' }
    Remove-Item "$work/out.txt"
    Invoke-Checked "$root/fixture.exe" @('again')
    Wait-Until { (Test-Path "$work/out.txt") -and (Get-Content -Raw "$work/out.txt").Trim() -eq '1.1.0 again' } 'upgraded fixture output'
    & "$work/setup-v1.exe" --silent
    if ($LASTEXITCODE -eq 0) { throw 'downgrade was accepted' }
    if (-not (Test-Path "$root/archives/windows-x86_64-1.1.0.0.zip")) { throw 'retained archive missing' }

    New-Item -ItemType Directory -Path "$work/local/$id/settings" | Out-Null
    Invoke-Checked "$root/uninstall.exe" @('--silent')
    Wait-Until { -not (Test-Path $root) } 'uninstall'
    if ((Test-Path $key) -or (Test-Path $shortcut)) { throw 'uninstall left integration behind' }
    if (-not (Test-Path "$work/local/$id/settings")) { throw 'uninstall removed user data without --purge' }
    Invoke-Checked "$work/setup-v2.exe" @('--silent')
    Invoke-Checked "$root/uninstall.exe" @('--silent', '--purge')
    Wait-Until { -not (Test-Path $root) -and -not (Test-Path "$work/local/$id") } 'purge'
    if (Test-Path $key) { throw 'purge left the uninstall entry' }

    # install.ps1 downloads the newest installer, checks it against
    # SHA256SUMS and runs it silently, in Windows PowerShell 5.1 and in
    # PowerShell 7; a wrong SHA-256 installs nothing.
    New-Item -ItemType Directory -Path "$work/serve" | Out-Null
    $served = 'fixture-1.1.0.0-windows-x86_64-setup.exe'
    Copy-Item "$work/setup-v2.exe" "$work/serve/$served"
    $sum = (Get-FileHash -Algorithm SHA256 "$work/serve/$served").Hash.ToLowerInvariant()
    Set-Content -NoNewline -Path "$work/serve/SHA256SUMS" -Value "$sum  $served`n"
    Invoke-Checked "$Bin/ziggurat.exe" @('package', 'install-ps1', '--zip', "$work/v2.zip", '--output', "$work/install.ps1")
    $port = Get-Random -Minimum 20000 -Maximum 40000
    $server = Start-Process -PassThru -WindowStyle Hidden -FilePath python -ArgumentList @('-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', "$work/serve")
    try {
        Wait-Until { try { (Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$port/SHA256SUMS").StatusCode -eq 200 } catch { $false } } 'the download server'
        $env:FIXTURE_DOWNLOAD_URL = "http://127.0.0.1:$port/"
        $env:FIXTURE_NO_OPEN = '1'
        foreach ($shell in @('powershell.exe', 'pwsh')) {
            & $shell -NoProfile -ExecutionPolicy Bypass -File "$work/install.ps1"
            if ($LASTEXITCODE -ne 0) { throw "install.ps1 failed in $shell" }
            if (-not (Test-Path "$root/fixture.exe") -or (Get-ItemProperty $key).DisplayVersion -ne '1.1.0.0') { throw "install.ps1 did not install in $shell" }
            Invoke-Checked "$root/uninstall.exe" @('--silent', '--purge')
            Wait-Until { -not (Test-Path $root) } "uninstall after $shell"
        }
        Set-Content -NoNewline -Path "$work/serve/SHA256SUMS" -Value ('0' * 64 + "  $served`n")
        & pwsh -NoProfile -File "$work/install.ps1"
        if ($LASTEXITCODE -eq 0 -or (Test-Path "$root/fixture.exe")) { throw 'install.ps1 installed an installer with the wrong SHA-256' }
        # The expected failure must not become the exit code of the step.
        $global:LASTEXITCODE = 0
    } finally {
        Remove-Item Env:FIXTURE_DOWNLOAD_URL, Env:FIXTURE_NO_OPEN -ErrorAction SilentlyContinue
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
    Write-Output 'setup smoke passed'
} finally {
    $env:LOCALAPPDATA = $savedLocal
    $env:APPDATA = $savedRoaming
    Remove-Item -ErrorAction SilentlyContinue -Recurse -Force $key
    Remove-Item -ErrorAction SilentlyContinue -Recurse -Force $work
}
