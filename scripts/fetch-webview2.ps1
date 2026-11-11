[CmdletBinding()]
param(
    # Where to extract the SDK. The default is the framework's own .deps;
    # an application that fetched the framework passes .deps/webview2 of
    # its own project, which its build.zig reads.
    [string]$Destination
)
$ErrorActionPreference = 'Stop'
$version = '1.0.4258.31'
$expected = '56F7F4B8BF9AEE4B8EFEFBBDD4F67D5F74EBD1B100ED0806DA71BF76AF481AA9'
if ($Destination) {
    # Keep the download beside the destination: a fetched framework package
    # must stay as Zig hashed it.
    $sdk = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
    $deps = Split-Path -Parent $sdk
    $archive = "$sdk.zip"
} else {
    $deps = Join-Path (Split-Path -Parent $PSScriptRoot) '.deps'
    $archive = Join-Path $deps 'webview2.zip'
    $sdk = Join-Path $deps 'webview2'
}
New-Item -ItemType Directory -Force -Path $deps | Out-Null
if (!(Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$version/microsoft.web.webview2.$version.nupkg" -OutFile $archive
}
$actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw "WebView2 SDK checksum mismatch: $actual" }
Expand-Archive -LiteralPath $archive -DestinationPath $sdk -Force
Write-Output "Verified WebView2 SDK $version at $sdk"
