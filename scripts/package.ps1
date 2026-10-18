[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')][string]$Name,
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$LicensePath,
    [ValidateSet('x86_64', 'aarch64', 'x86')][string]$Architecture = 'x86_64',
    [string]$Version,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../zig-out/packages'),
    [switch]$WebView,
    [string]$WebViewLoaderPath,
    [string]$WebViewLicensePath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-InputFile([string]$Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer) { throw "Expected a file: $Path" }
    return $item.FullName
}

function Read-PeArchitecture([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) { throw 'Executable has no DOS header.' }
        $stream.Position = 0x3c
        $offset = $reader.ReadUInt32()
        if ($offset -gt $stream.Length - 6) { throw 'Executable PE offset is invalid.' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw 'Executable has no PE signature.' }
        switch ($reader.ReadUInt16()) {
            0x8664 { return 'x86_64' }
            0xaa64 { return 'aarch64' }
            0x014c { return 'x86' }
            default { throw 'Unsupported executable architecture.' }
        }
    } finally { $reader.Dispose() }
}

if (-not ('ZigguratPackageResources' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class ZigguratPackageResources {
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr FindResourceW(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32", SetLastError=true)] static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32", SetLastError=true)] static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32")] static extern IntPtr LockResource(IntPtr resource);
    [DllImport("kernel32")] static extern bool FreeLibrary(IntPtr module);
    public static byte[] Manifest(string path) {
        IntPtr module = LoadLibraryExW(path, IntPtr.Zero, 0x22);
        if (module == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            IntPtr resource = FindResourceW(module, new IntPtr(1), new IntPtr(24));
            if (resource == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            uint size = SizeofResource(module, resource);
            IntPtr loaded = LoadResource(module, resource);
            IntPtr data = LockResource(loaded);
            if (size == 0 || data == IntPtr.Zero) throw new InvalidOperationException("Empty manifest resource.");
            byte[] bytes = new byte[size]; Marshal.Copy(data, bytes, 0, checked((int)size)); return bytes;
        } finally { FreeLibrary(module); }
    }
}
'@
}

$executable = Resolve-InputFile $ExecutablePath
$license = Resolve-InputFile $LicensePath
if ([IO.Path]::GetExtension($executable) -ine '.exe') { throw 'ExecutablePath must name a Windows .exe.' }
if ((Read-PeArchitecture $executable) -cne $Architecture) { throw 'Executable architecture does not match Architecture.' }
$embedded = [Diagnostics.FileVersionInfo]::GetVersionInfo($executable)
$embeddedVersion = $embedded.FileVersion
if ($embeddedVersion -notmatch '^\d{1,5}\.\d{1,5}\.\d{1,5}\.\d{1,5}$') { throw 'Executable needs a four-component VERSIONINFO FileVersion.' }
foreach ($component in $embeddedVersion.Split('.')) { if ([int]$component -gt 65535) { throw 'Version component exceeds 65535.' } }
if ($Version -and $Version -cne $embeddedVersion) { throw 'Version does not match the embedded FileVersion.' }
$Version = $embeddedVersion
$manifestBytes = [ZigguratPackageResources]::Manifest($executable)
$settings = [Xml.XmlReaderSettings]::new()
$settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
$settings.XmlResolver = $null
$textReader = [IO.StringReader]::new([Text.UTF8Encoding]::new($false, $true).GetString($manifestBytes))
$xmlReader = [Xml.XmlReader]::Create($textReader, $settings)
$manifest = [Xml.XmlDocument]::new()
$manifest.XmlResolver = $null
try { $manifest.Load($xmlReader) } finally { $xmlReader.Dispose(); $textReader.Dispose() }
$ns = [Xml.XmlNamespaceManager]::new($manifest.NameTable)
$ns.AddNamespace('asm', 'urn:schemas-microsoft-com:asm.v1')
$identity = $manifest.SelectSingleNode('/asm:assembly/asm:assemblyIdentity', $ns)
if ($null -eq $identity -or $identity.GetAttribute('version') -cne $Version) { throw 'Embedded manifest identity/version does not match VERSIONINFO.' }

$payload = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
$payload.Add([IO.Path]::GetFileName($executable), $executable)
$payload.Add('LICENSE.txt', $license)
if ($WebView) {
    if (-not $WebViewLoaderPath) { $WebViewLoaderPath = Join-Path ([IO.Path]::GetDirectoryName($executable)) 'WebView2Loader.dll' }
    if (-not $WebViewLicensePath) { $WebViewLicensePath = Join-Path ([IO.Path]::GetDirectoryName($executable)) 'WebView2-SDK-LICENSE.txt' }
    $loader = Resolve-InputFile $WebViewLoaderPath
    if ((Read-PeArchitecture $loader) -cne $Architecture) { throw 'WebView2 Loader architecture does not match Architecture.' }
    $payload.Add('WebView2Loader.dll', $loader)
    $payload.Add('WebView2-SDK-LICENSE.txt', (Resolve-InputFile $WebViewLicensePath))
} elseif ($WebViewLoaderPath -or $WebViewLicensePath) { throw 'WebView dependency paths require -WebView.' }

$entryNames = [string[]]@($payload.Keys)
[Array]::Sort($entryNames, [StringComparer]::Ordinal)
$inventory = @($entryNames | ForEach-Object {
    [ordered]@{ path = $_; bytes = (Get-Item -LiteralPath $payload[$_]).Length; sha256 = (Get-FileHash -LiteralPath $payload[$_] -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$signature = Get-AuthenticodeSignature -LiteralPath $executable
$metadata = [ordered]@{
    schema_version = 1
    name = $Name
    identity = $identity.GetAttribute('name')
    display_name = $embedded.ProductName
    version = $Version
    target = "windows-$Architecture"
    executable = [IO.Path]::GetFileName($executable)
    authenticode_status = $signature.Status.ToString()
    webview2 = [ordered]@{ required = [bool]$WebView; loader_included = [bool]$WebView; runtime_included = $false }
    inventory_scope = 'Payload files; package.json is covered by the archive SHA-256.'
    files = $inventory
}
$metadataBytes = [Text.UTF8Encoding]::new($false).GetBytes((($metadata | ConvertTo-Json -Depth 8).Replace("`r`n", "`n")) + "`n")
$output = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($output)
$archiveName = "$Name-$Version-windows-$Architecture.zip"
$archivePath = Join-Path $output $archiveName
$temporaryPath = Join-Path $output ('.package-' + [Guid]::NewGuid().ToString('N') + '.tmp')
$zipStream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $zip = [IO.Compression.ZipArchive]::new($zipStream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        $allEntries = [string[]]@($entryNames + 'package.json')
        [Array]::Sort($allEntries, [StringComparer]::Ordinal)
        foreach ($entryName in $allEntries) {
            $entry = $zip.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $entryStream = $entry.Open()
            try {
                if ($entryName -ceq 'package.json') { $entryStream.Write($metadataBytes, 0, $metadataBytes.Length) }
                else { $inputStream = [IO.File]::OpenRead($payload[$entryName]); try { $inputStream.CopyTo($entryStream) } finally { $inputStream.Dispose() } }
            } finally { $entryStream.Dispose() }
        }
    } finally { $zip.Dispose() }
} catch {
    $zipStream.Dispose()
    Remove-Item -LiteralPath $temporaryPath -ErrorAction SilentlyContinue
    throw
} finally { $zipStream.Dispose() }
try { [IO.File]::Move($temporaryPath, $archivePath, $true) }
finally { if ([IO.File]::Exists($temporaryPath)) { Remove-Item -LiteralPath $temporaryPath } }
$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($archivePath + '.sha256', "$hash  $archiveName`n", [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ archive = $archivePath; sha256 = $hash; files = $allEntries }
