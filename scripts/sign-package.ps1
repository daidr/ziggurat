#requires -Version 7.1
[CmdletBinding(DefaultParameterSetName = 'Store')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')][string]$Name,
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$LicensePath,
    [Parameter(Mandatory, ParameterSetName = 'Store')][ValidatePattern('^[0-9A-Fa-f]{40}$')][string]$CertificateThumbprint,
    [Parameter(Mandatory, ParameterSetName = 'Pfx')][string]$PfxPath,
    [Parameter(ParameterSetName = 'Pfx')][Security.SecureString]$PfxPassword,
    [ValidateSet('x86_64', 'aarch64', 'x86')][string]$Architecture = 'x86_64',
    [string]$Version,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../zig-out/packages'),
    [uri]$TimestampServer,
    [switch]$WebView,
    [string]$WebViewLoaderPath,
    [string]$WebViewLicensePath,
    [switch]$AllowUntrustedTestCertificate
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Authenticode signing requires Windows.' }

# ZIP files are not Authenticode subjects. Sign a private EXE copy before packaging.
if (-not ('ZigguratSignatureTrust' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ZigguratSignatureTrust {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct FileInfo {
        public uint size; [MarshalAs(UnmanagedType.LPWStr)] public string path;
        public IntPtr file, knownSubject;
    }
    [StructLayout(LayoutKind.Sequential)] struct TrustData {
        public uint size; public IntPtr policy, sip; public uint ui, revocation, choice;
        public IntPtr file; public uint stateAction; public IntPtr state, url;
        public uint flags, context;
    }
    [DllImport("wintrust", ExactSpelling=true, CharSet=CharSet.Unicode)]
    static extern int WinVerifyTrust(IntPtr hwnd, ref Guid action, ref TrustData data);
    public static int Verify(string path) {
        FileInfo file = new FileInfo { size=(uint)Marshal.SizeOf<FileInfo>(), path=path };
        IntPtr pointer = Marshal.AllocHGlobal(Marshal.SizeOf<FileInfo>());
        try {
            Marshal.StructureToPtr(file, pointer, false);
            TrustData data = new TrustData { size=(uint)Marshal.SizeOf<TrustData>(), ui=2,
                choice=1, file=pointer, flags=0x1000 }; // Cache-only URL retrieval; no network trust fetches.
            Guid action = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");
            return WinVerifyTrust(new IntPtr(-1), ref action, ref data);
        } finally { Marshal.DestroyStructure<FileInfo>(pointer); Marshal.FreeHGlobal(pointer); }
    }
}
'@
}

$executable = (Get-Item -LiteralPath $ExecutablePath).FullName
$license = (Get-Item -LiteralPath $LicensePath).FullName
if ([IO.Path]::GetExtension($executable) -ine '.exe') { throw 'ExecutablePath must name a Windows .exe.' }
if ((Get-Item -LiteralPath $license).PSIsContainer) { throw 'LicensePath must name the caller-provided application license.' }
if ($TimestampServer -and (-not $TimestampServer.IsAbsoluteUri -or $TimestampServer.Scheme -notin @('http', 'https'))) {
    throw 'TimestampServer must be an explicit absolute HTTP or HTTPS URL.'
}

$certificate = $null
$staging = $null
$stagedExecutable = $null
try {
    if ($PSCmdlet.ParameterSetName -eq 'Pfx') {
        $pfx = (Get-Item -LiteralPath $PfxPath).FullName
        $load = @{ LiteralPath = $pfx; NoPromptForPassword = $true }
        if ($null -ne $PfxPassword) { $load.Password = $PfxPassword }
        $certificate = Get-PfxCertificate @load
    } else {
        $certificate = Get-Item -LiteralPath ("Cert:\CurrentUser\My\" + $CertificateThumbprint)
    }
    if (-not $certificate.HasPrivateKey) { throw 'The selected certificate has no private signing key.' }
    if ([DateTime]::Now -lt $certificate.NotBefore -or [DateTime]::Now -gt $certificate.NotAfter) { throw 'The selected certificate is outside its validity period.' }
    $codeSigning = $false
    foreach ($extension in $certificate.Extensions) {
        if ($extension -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]) {
            foreach ($usage in $extension.EnhancedKeyUsages) { if ($usage.Value -eq '1.3.6.1.5.5.7.3.3') { $codeSigning = $true } }
        }
    }
    if (-not $codeSigning) { throw 'The selected certificate must explicitly permit code signing.' }
    if ($AllowUntrustedTestCertificate -and $certificate.Subject -cne $certificate.Issuer) {
        throw 'The test-only trust exception requires an explicitly selected self-signed certificate.'
    }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $staging = Join-Path $tempRoot ('ziggurat-sign-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($staging)
    $stagedExecutable = Join-Path $staging ([IO.Path]::GetFileName($executable))
    Copy-Item -LiteralPath $executable -Destination $stagedExecutable
    $sign = @{ LiteralPath = $stagedExecutable; Certificate = $certificate; HashAlgorithm = 'SHA256'; IncludeChain = 'NotRoot' }
    if ($TimestampServer) { $sign.TimestampServer = $TimestampServer.AbsoluteUri }
    $signed = Set-AuthenticodeSignature @sign
    $verified = Get-AuthenticodeSignature -LiteralPath $stagedExecutable
    $trust = [ZigguratSignatureTrust]::Verify($stagedExecutable)
    # CERT_E_UNTRUSTEDROOT is the only accepted test exception. Expiry, revocation,
    # a broken digest, a missing signature, or a different signer still fail.
    $testUntrusted = $AllowUntrustedTestCertificate -and $trust -eq -2146762487
    if (($trust -ne 0 -or $verified.Status -ne 'Valid') -and -not $testUntrusted) {
        throw "Authenticode verification failed: $($verified.Status), WinVerifyTrust=$trust."
    }
    if ($null -eq $verified.SignerCertificate -or $verified.SignerCertificate.Thumbprint -cne $certificate.Thumbprint) { throw 'Authenticode signer does not match the selected certificate.' }
    if ($TimestampServer -and $null -eq $verified.TimeStamperCertificate) { throw 'Requested timestamp was not attached to the signature.' }
    $package = @{ Name = $Name; ExecutablePath = $stagedExecutable; LicensePath = $license; Architecture = $Architecture; OutputDirectory = $OutputDirectory; WebView = $WebView }
    if ($Version) { $package.Version = $Version }
    if ($WebView) {
        # Resolve defaults relative to the original EXE, before moving it to staging.
        $directory = [IO.Path]::GetDirectoryName($executable)
        $package.WebViewLoaderPath = if ($WebViewLoaderPath) { $WebViewLoaderPath } else { Join-Path $directory 'WebView2Loader.dll' }
        $package.WebViewLicensePath = if ($WebViewLicensePath) { $WebViewLicensePath } else { Join-Path $directory 'WebView2-SDK-LICENSE.txt' }
    } elseif ($WebViewLoaderPath -or $WebViewLicensePath) { throw 'WebView dependency paths require -WebView.' }
    $result = & (Join-Path $PSScriptRoot 'package.ps1') @package
    $report = [ordered]@{
        schema_version = 1
        archive_sha256 = $result.sha256
        executable = [IO.Path]::GetFileName($executable)
        signed_executable_sha256 = (Get-FileHash -LiteralPath $stagedExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
        signer_subject = $verified.SignerCertificate.Subject
        signer_thumbprint = $verified.SignerCertificate.Thumbprint
        digest_algorithm = 'SHA256'
        authenticode_status = $verified.Status.ToString()
        win_verify_trust = $trust
        trusted = $trust -eq 0
        test_only = [bool]$AllowUntrustedTestCertificate
        timestamped = $null -ne $verified.TimeStamperCertificate
        timestamp_server = if ($TimestampServer) { $TimestampServer.AbsoluteUri } else { $null }
    }
    $reportPath = $result.archive + '.signature.json'
    [IO.File]::WriteAllText($reportPath, (($report | ConvertTo-Json -Depth 5).Replace("`r`n", "`n")) + "`n", [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ archive = $result.archive; sha256 = $result.sha256; signature_report = $reportPath; trusted = $report.trusted; test_only = $report.test_only }
} finally {
    if ($null -ne $certificate) { $certificate.Dispose() }
    # Delete only the one known private copy; never recursively traverse a caller path.
    if ($stagedExecutable -and [IO.File]::Exists($stagedExecutable)) { Remove-Item -LiteralPath $stagedExecutable }
    if ($staging -and [IO.Directory]::Exists($staging)) { [IO.Directory]::Delete($staging, $false) }
}
