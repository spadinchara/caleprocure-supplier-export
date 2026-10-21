# Runs the exporter against a local page that mimics the Cal eProcure flow, in two modes:
#   attachment - the new tab's response is a download, which the browser saves itself
#   inline     - the new tab displays the file (as the live site does), so the exporter
#                must fetch it directly with the browser's session cookie
# Usage: .\test\Test-Export.ps1 [-BrowserPath <path>] [-BrowserArgs <args>]
param(
    [string]$BrowserPath,
    [string[]]$BrowserArgs = @()
)
$ErrorActionPreference = 'Stop'

$port = Get-Random -Minimum 20000 -Maximum 40000
$prefix = "http://127.0.0.1:$port/"
$html = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'mock-site.html'))
$xls = [Text.Encoding]::UTF8.GetBytes('<table><tr><td>Business Name</td><td>Certification</td></tr><tr><td>S&amp;F Cleaning Co. LLC</td><td>SB(Micro)</td></tr></table>')

# Serve the mock site from a background runspace while the exporter runs.
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()
$server = [powershell]::Create()
$null = $server.AddScript({
    param($listener, $html, $xls)
    while ($listener.IsListening) {
        try { $ctx = $listener.GetContext() } catch { break }   # listener stopped
        $req = $ctx.Request
        if ($req.Url.AbsolutePath -like '/files/*') {
            if (-not $req.Cookies['ce_session']) {
                $ctx.Response.StatusCode = 403
                $body = [Text.Encoding]::UTF8.GetBytes('no session')
            } else {
                $ctx.Response.ContentType = 'text/html'
                if ($req.QueryString['mode'] -eq 'attachment') {
                    $ctx.Response.ContentType = 'application/vnd.ms-excel'
                    $ctx.Response.AddHeader('Content-Disposition', 'attachment; filename="Certification_Information_TEST.xls"')
                }
                $body = $xls
            }
        } else {
            $ctx.Response.ContentType = 'text/html'
            $body = $html
        }
        $ctx.Response.OutputStream.Write($body, 0, $body.Length)
        $ctx.Response.Close()
    }
}).AddArgument($listener).AddArgument($html).AddArgument($xls)
$handle = $server.BeginInvoke()

$exporter = Join-Path (Split-Path $PSScriptRoot) 'Export-CaleProcureSuppliers.ps1'
$failed = 0
try {
    Start-Sleep -Seconds 1
    foreach ($mode in 'attachment', 'inline') {
        $outDir = Join-Path ([IO.Path]::GetTempPath()) ("caleprocure-test-" + [guid]::NewGuid())
        try {
            $exportArgs = @{ Url = "${prefix}?delay=2000&mode=$mode"; OutDir = $outDir; TimeoutSeconds = 30; Retries = 0 }
            if ($BrowserPath) { $exportArgs.BrowserPath = $BrowserPath }
            if ($BrowserArgs) { $exportArgs.BrowserArgs = $BrowserArgs }
            & $exporter @exportArgs
            if ($LASTEXITCODE -ne 0) { throw "Exporter exited with code $LASTEXITCODE" }

            $saved = Join-Path $outDir 'Certification_Information_TEST.xls'
            if (-not (Test-Path $saved)) { throw "Expected $saved to exist" }
            if ((Get-Content $saved -Raw) -notmatch 'S&amp;F Cleaning Co\. LLC') { throw 'Saved file has unexpected content' }
            Write-Host "PASS ($mode): searched, waited for both loading overlays, and saved the file" -ForegroundColor Green
        }
        catch {
            Write-Host "FAIL ($mode): $($_.Exception.Message)" -ForegroundColor Red
            $failed++
        }
        finally {
            Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
    $server.Dispose()
}
if ($failed) { exit 1 }
