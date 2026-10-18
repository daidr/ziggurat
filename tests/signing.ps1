#requires -Version 7.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$LicensePath,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../.zig-cache/signing-tests')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Authenticode integration tests require Windows.' }
$signer = Join-Path $PSScriptRoot '../scripts/sign-package.ps1'
$before = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash
$certificate = $null
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('ziggurat-sign-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
$pfx = Join-Path $temporary 'test.pfx'
$extracted = Join-Path $temporary 'signed.exe'
try {
    $certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject ('CN=Ziggurat Signing Test ' + [Guid]::NewGuid().ToString('N')) -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy Exportable -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -NotAfter ([DateTime]::Now.AddDays(1))
    $parameters = @{ Name = 'signing-test'; ExecutablePath = $ExecutablePath; LicensePath = $LicensePath; CertificateThumbprint = $certificate.Thumbprint; OutputDirectory = $OutputDirectory }
    $rejected = $false
    try { & $signer @parameters | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Production signing accepted an untrusted test certificate.' }
    $result = & $signer @parameters -AllowUntrustedTestCertificate
    $report = Get-Content -LiteralPath $result.signature_report -Raw | ConvertFrom-Json
    if ($report.trusted -or -not $report.test_only -or $report.signer_thumbprint -cne $certificate.Thumbprint) { throw 'Signature report invented trust or the signer identity.' }
    $archive = [IO.Compression.ZipFile]::OpenRead($result.archive)
    try {
        $entry = $archive.GetEntry([IO.Path]::GetFileName($ExecutablePath))
        $inputStream = $entry.Open()
        $output = [IO.File]::Create($extracted)
        try { $inputStream.CopyTo($output) } finally { $output.Dispose(); $inputStream.Dispose() }
        $metadataReader = [IO.StreamReader]::new($archive.GetEntry('package.json').Open())
        try { $metadata = $metadataReader.ReadToEnd() | ConvertFrom-Json } finally { $metadataReader.Dispose() }
        $inventory = @($metadata.files | Where-Object path -CEQ ([IO.Path]::GetFileName($ExecutablePath)))
        if ($inventory.Count -ne 1 -or $inventory[0].sha256 -cne $report.signed_executable_sha256) { throw 'Package inventory does not describe the signed payload.' }
    } finally { $archive.Dispose() }
    $signature = Get-AuthenticodeSignature -LiteralPath $extracted
    if ($signature.SignerCertificate.Thumbprint -cne $certificate.Thumbprint -or $signature.Status -in @('NotSigned', 'HashMismatch')) { throw 'Packaged EXE has no intact Authenticode signature.' }
    if ([ZigguratSignatureTrust]::Verify($extracted) -ne -2146762487) { throw 'Unexpected trust result for the untrusted test certificate.' }
    # Change an actual mapped byte in .text, not the excluded PE checksum/security directory.
    $bytes = [IO.File]::ReadAllBytes($extracted)
    $pe = [BitConverter]::ToUInt32($bytes, 0x3c)
    $optionalSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
    $firstSection = $pe + 24 + $optionalSize
    $rawOffset = [BitConverter]::ToUInt32($bytes, $firstSection + 20)
    $bytes[$rawOffset] = $bytes[$rawOffset] -bxor 1
    [IO.File]::WriteAllBytes($extracted, $bytes)
    if ((Get-AuthenticodeSignature -LiteralPath $extracted).Status -ne 'HashMismatch') { throw 'Modified executable digest was not rejected.' }
    $password = ConvertTo-SecureString ([Guid]::NewGuid().ToString('N')) -AsPlainText -Force
    Export-PfxCertificate -Cert $certificate -FilePath $pfx -Password $password | Out-Null
    $pfxResult = & $signer -Name 'signing-pfx-test' -ExecutablePath $ExecutablePath -LicensePath $LicensePath -PfxPath $pfx -PfxPassword $password -AllowUntrustedTestCertificate -OutputDirectory $OutputDirectory
    if ((Get-Content -LiteralPath $pfxResult.signature_report -Raw | ConvertFrom-Json).signer_thumbprint -cne $certificate.Thumbprint) { throw 'Explicit PFX signer mismatch.' }
    if ((Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash -cne $before) { throw 'Signing changed the caller executable.' }
    Write-Host 'Signing tests passed: actual Authenticode via store/PFX, signed ZIP inventory, strict production trust, tamper rejection, original EXE unchanged.'
} finally {
    if ($null -ne $certificate) {
        $thumbprint = $certificate.Thumbprint
        $certificate.Dispose()
        Remove-Item -LiteralPath ("Cert:\CurrentUser\My\" + $thumbprint) -DeleteKey -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath ("Cert:\CurrentUser\My\" + $thumbprint)) { throw 'Temporary signing certificate cleanup failed.' }
    }
    foreach ($path in @($pfx, $extracted)) { if ([IO.File]::Exists($path)) { Remove-Item -LiteralPath $path } }
    [IO.Directory]::Delete($temporary, $false)
}
