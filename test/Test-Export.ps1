# Runs the exporter against a local page that mimics the Cal eProcure flow.
# Usage: .\test\Test-Export.ps1 [-BrowserPath <path>] [-BrowserArgs <args>]
param(
    [string]$BrowserPath,
    [string[]]$BrowserArgs = @()
)
$ErrorActionPreference = 'Stop'

$port = Get-Random -Minimum 20000 -Maximum 40000
$prefix = "http://127.0.0.1:$port/"
$html = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'mock-site.html'))
$csv = [Text.Encoding]::UTF8.GetBytes("Business Name,Certification`nS&F Cleaning Co. LLC,SB(Micro)`n")

# Serve the mock site from a background runspace while the exporter runs.
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()
$server = [powershell]::Create()
$null = $server.AddScript({
    param($listener, $html, $csv)
    while ($listener.IsListening) {
        try { $ctx = $listener.GetContext() } catch { break }   # listener stopped
        if ($ctx.Request.Url.AbsolutePath -eq '/file') {
            $ctx.Response.ContentType = 'text/csv'
            $ctx.Response.AddHeader('Content-Disposition', 'attachment; filename="SupplierSearchResults.csv"')
            $body = $csv
        } else {
            $ctx.Response.ContentType = 'text/html'
            $body = $html
        }
        $ctx.Response.OutputStream.Write($body, 0, $body.Length)
        $ctx.Response.Close()
    }
}).AddArgument($listener).AddArgument($html).AddArgument($csv)
$handle = $server.BeginInvoke()

$outDir = Join-Path ([IO.Path]::GetTempPath()) ("caleprocure-test-" + [guid]::NewGuid())
try {
    Start-Sleep -Seconds 1
    $exporter = Join-Path (Split-Path $PSScriptRoot) 'Export-CaleProcureSuppliers.ps1'
    $exportArgs = @{ Url = "${prefix}?delay=2000"; OutDir = $outDir; TimeoutSeconds = 30; Retries = 0 }
    if ($BrowserPath) { $exportArgs.BrowserPath = $BrowserPath }
    if ($BrowserArgs) { $exportArgs.BrowserArgs = $BrowserArgs }
    & $exporter @exportArgs
    if ($LASTEXITCODE -ne 0) { throw "Exporter exited with code $LASTEXITCODE" }

    $saved = Join-Path $outDir 'SupplierSearchResults.csv'
    if (-not (Test-Path $saved)) { throw "Expected $saved to exist" }
    if ((Get-Content $saved -Raw) -notmatch 'S&F Cleaning Co\. LLC') { throw 'Saved file has unexpected content' }
    Write-Host 'PASS: searched, waited for both loading overlays, and saved the attachment' -ForegroundColor Green
}
catch {
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    $listener.Stop()
    $listener.Close()
    $server.Dispose()
    Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue
}
