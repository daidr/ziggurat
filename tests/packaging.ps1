[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$LicensePath,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../.zig-cache/packaging-tests'),
    [switch]$WebView
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$packager = Join-Path $PSScriptRoot '../scripts/package.ps1'
$arguments = @{ Name = 'packaging-test'; ExecutablePath = $ExecutablePath; LicensePath = $LicensePath; WebView = $WebView }
$first = & $packager @arguments -OutputDirectory (Join-Path $OutputDirectory 'first')
$second = & $packager @arguments -OutputDirectory (Join-Path $OutputDirectory 'second')
if ($first.sha256 -cne $second.sha256) { throw 'Repeated packaging produced different archive hashes.' }
$archive = [IO.Compression.ZipFile]::OpenRead($first.archive)
try {
    $entryNames = [string[]]@($archive.Entries.FullName)
    $sorted = [string[]]$entryNames.Clone()
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    if (($entryNames -join '|') -cne ($sorted -join '|')) { throw 'ZIP entries are not in ordinal order.' }
    $metadataEntry = $archive.GetEntry('package.json')
    $reader = [IO.StreamReader]::new($metadataEntry.Open())
    try { $metadata = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    if ([bool]$metadata.webview2.runtime_included) { throw 'Package incorrectly claims to include the WebView2 Runtime.' }
    if ([bool]$metadata.webview2.loader_included -ne [bool]$WebView) { throw 'WebView2 dependency metadata is wrong.' }
    foreach ($file in $metadata.files) {
        $entry = $archive.GetEntry($file.path)
        if ($null -eq $entry -or $entry.Length -ne $file.bytes) { throw "Bad payload inventory: $($file.path)" }
        $stream = $entry.Open()
        try { $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() } finally { $stream.Dispose() }
        if ($hash -cne $file.sha256) { throw "Bad payload SHA-256: $($file.path)" }
        if ($entry.LastWriteTime.Year -ne 1980) { throw 'ZIP timestamps are not fixed.' }
    }
    if ($archive.Entries.Count -ne @($metadata.files).Count + 1) { throw 'ZIP contains a file outside the inventory.' }
    if ($null -eq $archive.GetEntry('LICENSE.txt')) { throw 'Application license is missing.' }
    $licenseStream = $archive.GetEntry('LICENSE.txt').Open()
    try { $licenseHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($licenseStream)) } finally { $licenseStream.Dispose() }
    if ($licenseHash -cne (Get-FileHash -LiteralPath $LicensePath -Algorithm SHA256).Hash) { throw 'Packaged license differs from the selected license.' }
    if (-not $WebView -and $null -ne $archive.GetEntry('WebView2Loader.dll')) { throw 'Native package unexpectedly includes a WebView2 dependency.' }
    $sidecar = [IO.File]::ReadAllText($first.archive + '.sha256')
    if (-not $sidecar.StartsWith($first.sha256 + '  ', [StringComparison]::Ordinal)) { throw 'Archive SHA-256 sidecar mismatch.' }
} finally { $archive.Dispose() }
$rejected = $false
try { & $packager @arguments -OutputDirectory $OutputDirectory -Version '99.99.99.99' | Out-Null } catch { $rejected = $true }
if (-not $rejected) { throw 'Packager accepted an incorrect declared version.' }
Write-Host "packaging tests passed: deterministic ZIP, payload hashes, metadata, license and dependency boundary; SHA256=$($first.sha256)"
