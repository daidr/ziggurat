[CmdletBinding()]
param([string]$ToolPath = (Join-Path $PSScriptRoot '../zig-out/bin/ziggurat-update.exe'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tool = (Get-Item -LiteralPath $ToolPath).FullName
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$temporary = Join-Path $temporaryBase ('ziggurat-update-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)

function Invoke-Update([string[]]$Arguments) {
    $result = & $tool @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Update tool failed: $($Arguments[0])" }
    return $result
}
function Assert-Rejected([string[]]$Arguments) {
    & $tool @Arguments 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { throw "Update tool accepted invalid input: $($Arguments[0])" }
}
try {
    $seed = Join-Path $temporary 'signing.seed'
    $public = Join-Path $temporary 'public.key'
    Invoke-Update @('keygen', $seed, $public)
    if ((Get-Item -LiteralPath $seed).Length -ne 32 -or (Get-Item -LiteralPath $public).Length -ne 32) { throw 'Invalid generated key files.' }
    Assert-Rejected @('keygen', $seed, $public)
    $license = Join-Path $temporary 'fixture-license.txt'
    [IO.File]::WriteAllText($license, 'Test fixture only; no project license is granted by this file.')
    $packages = Join-Path $temporary 'packages'
    $originalHash = (Get-FileHash -LiteralPath $tool).Hash
    & (Join-Path $PSScriptRoot '../scripts/package.ps1') -Name update-fixture -ExecutablePath $tool -LicensePath $license -OutputDirectory $packages | Out-Null
    $zip = (Get-ChildItem -LiteralPath $packages -Filter '*.zip').FullName
    $manifest = Join-Path $temporary 'update.json'
    $identity = 'org.ziggurat.ziggurat-update'
    $target = 'windows-x86_64'
    Invoke-Update @('sign', $zip, $manifest, $seed, $identity, $target, '0.1.0.0', 'https://updates.example.invalid/update.zip')
    Invoke-Update @('verify', $manifest, $public, $identity, $target, '0.0.0.0') | Out-Null
    Assert-Rejected @('verify', $manifest, $public, $identity, 'windows-aarch64', '0.0.0.0')
    Assert-Rejected @('verify', $manifest, $public, $identity, $target, '0.1.0.0')
    Assert-Rejected @('verify', $manifest, $public, $identity, $target, '1.0.0.0')
    $changedManifest = Join-Path $temporary 'changed.json'
    [IO.File]::WriteAllText($changedManifest, ([IO.File]::ReadAllText($manifest)).Replace('https://updates.example.invalid/update.zip', 'https://updates.example.invalid/other.zip'))
    Assert-Rejected @('verify', $changedManifest, $public, $identity, $target, '0.0.0.0')
    $badZip = Join-Path $temporary 'bad.zip'
    $bytes = [IO.File]::ReadAllBytes($zip)
    $bytes[0] = $bytes[0] -bxor 1
    [IO.File]::WriteAllBytes($badZip, $bytes)
    $root = Join-Path $temporary 'installation'
    [void][IO.Directory]::CreateDirectory($root)
    [IO.File]::WriteAllText((Join-Path $root 'user-data.txt'), 'keep')
    Assert-Rejected @('publish', $manifest, $public, $identity, $target, '0.0.0.0', $badZip, $root)
    if (Test-Path -LiteralPath (Join-Path $root 'current.json')) { throw 'Tampered archive published a marker.' }
    $relative = Invoke-Update @('publish', $manifest, $public, $identity, $target, '0.0.0.0', $zip, $root)
    $resolved = Invoke-Update @('current', $root, $identity, $target)
    if ($resolved -cne $relative) { throw 'Published and resolved paths differ.' }
    $installed = [IO.Path]::GetFullPath((Join-Path $root $relative))
    $rootPrefix = [IO.Path]::GetFullPath($root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $installed.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Resolved path escaped the managed root.' }
    if ((Get-FileHash -LiteralPath $installed).Hash -cne $originalHash) { throw 'Installed executable differs from signed package.' }
    # Execute the actual newly published CLI with a bounded read-only command.
    $childResult = & $installed current $root $identity $target
    if ($LASTEXITCODE -ne 0 -or $childResult -cne $relative) { throw 'Published executable did not start successfully.' }
    Assert-Rejected @('publish', $manifest, $public, $identity, $target, '0.0.0.0', $zip, $root)
    if ([IO.File]::ReadAllText((Join-Path $root 'user-data.txt')) -cne 'keep') { throw 'Publication changed application data.' }
    if ((Get-FileHash -LiteralPath $tool).Hash -cne $originalHash) { throw 'Original executable changed.' }
    Write-Output 'Update package smoke passed: signed metadata, real deflated package, tamper/downgrade rejection, immutable publication and actual new executable launch.'
} finally {
    $resolvedTemporary = [IO.Path]::GetFullPath($temporary)
    if (-not $resolvedTemporary.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedTemporary) -notmatch '^ziggurat-update-test-[0-9a-f]{32}$') { throw 'Unsafe temporary cleanup target.' }
    Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
}
