<#
.SYNOPSIS
    Downloads the full Cal eProcure certified supplier list (MB, SB, SB-PW, DVBE, NVSA, NP).

.DESCRIPTION
    Drives Microsoft Edge (or Chrome) through the DevTools protocol, so nothing needs to be
    installed beyond Windows PowerShell 5.1 and the browser that ships with Windows.

    Flow, mirroring the manual process:
      1. Open the public supplier search page.
      2. Leave every criterion blank and click "Search".
      3. Wait for the "Loading..." overlay to clear and the results toolbar to appear.
      4. Click "Download" in the results toolbar and wait for the overlay again.
      5. In the "Your file is ready." modal, click "Download Attachment".
      6. Save the file under the server's default file name.

.EXAMPLE
    .\Export-CaleProcureSuppliers.ps1 -OutDir C:\Data\CaleProcure

.EXAMPLE
    .\Export-CaleProcureSuppliers.ps1 -Headed      # watch the browser while it runs
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $PSScriptRoot 'downloads'),
    # The unfiltered search and the export each build ~22k records server-side, so allow minutes.
    [int]$TimeoutSeconds = 600,
    [int]$Retries = 2,
    [switch]$Headed,
    [string]$BrowserPath,
    [string[]]$BrowserArgs = @(),
    [string]$Url = 'https://caleprocure.ca.gov/pages/PublicSearch/supplier-search.aspx?psNewWin=true'
)

$ErrorActionPreference = 'Stop'

function Write-Log([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line }
}

function Find-Browser {
    if ($BrowserPath) {
        if (-not (Test-Path $BrowserPath)) { throw "Browser not found at $BrowserPath" }
        return $BrowserPath
    }
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path $path)) { return $path }
    }
    throw 'Could not find Microsoft Edge or Google Chrome. Pass -BrowserPath.'
}

# ---------------------------------------------------------------------------------------------
# Minimal DevTools protocol client over a single browser-level WebSocket.

function Connect-Cdp([string]$WsUrl) {
    $script:Ws = New-Object System.Net.WebSockets.ClientWebSocket
    $script:Ws.Options.Proxy = $null   # 127.0.0.1 must never go through a corporate proxy
    $script:CdpId = 0
    $script:RecvBuffer = New-Object byte[] 1048576
    $script:RecvStream = New-Object System.IO.MemoryStream
    $script:RecvTask = $null
    $script:Download = $null
    $script:TabUrls = @{}
    $script:Ws.ConnectAsync([Uri]$WsUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
}

# Returns the next complete message, or $null if none arrives within $TimeoutMs.
# A receive that times out stays pending and is picked up by the next call.
function Read-CdpMessage([int]$TimeoutMs) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ($true) {
        if (-not $script:RecvTask) {
            $segment = New-Object System.ArraySegment[byte] -ArgumentList @(, $script:RecvBuffer)
            $script:RecvTask = $script:Ws.ReceiveAsync($segment, [Threading.CancellationToken]::None)
        }
        $remaining = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
        if (-not $script:RecvTask.Wait($remaining)) { return $null }
        $result = $script:RecvTask.Result
        $script:RecvTask = $null
        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            throw 'The browser closed the DevTools connection'
        }
        $script:RecvStream.Write($script:RecvBuffer, 0, $result.Count)
        if ($result.EndOfMessage) {
            $text = [Text.Encoding]::UTF8.GetString($script:RecvStream.ToArray())
            $script:RecvStream.SetLength(0)
            return $text | ConvertFrom-Json
        }
    }
}

# Tracks downloads and new tabs so the log shows what the attachment click actually did.
function Receive-CdpEvent($Message) {
    $p = $Message.params
    switch ($Message.method) {
        'Browser.downloadWillBegin' {
            $script:Download = @{ Guid = $p.guid; Name = $p.suggestedFilename; State = 'inProgress' }
            Write-Log "Download started: $($p.suggestedFilename) from $($p.url)"
        }
        'Browser.downloadProgress' {
            if ($script:Download -and $p.guid -eq $script:Download.Guid -and $p.state -ne 'inProgress') {
                $script:Download.State = $p.state
                Write-Log ("Download {0} ({1:N0} bytes)" -f $p.state, $p.receivedBytes)
            }
        }
        { $_ -eq 'Target.targetCreated' -or $_ -eq 'Target.targetInfoChanged' } {
            $info = $p.targetInfo
            if ($info.type -eq 'page' -and $info.targetId -ne $script:TargetId -and $info.url -and $info.url -ne 'about:blank' -and
                $script:TabUrls[$info.targetId] -ne $info.url) {
                $script:TabUrls[$info.targetId] = $info.url
                Write-Log "Other tab is at: $($info.url)"
            }
        }
    }
}

# Processes incoming events for up to $Milliseconds.
function Watch-CdpEvents([int]$Milliseconds) {
    $deadline = (Get-Date).AddMilliseconds($Milliseconds)
    while ((Get-Date) -lt $deadline) {
        $msg = Read-CdpMessage ([int][Math]::Max(1, ($deadline - (Get-Date)).TotalMilliseconds))
        if ($msg -and $msg.method) { Receive-CdpEvent $msg }
    }
}

function Invoke-Cdp([string]$Method, [hashtable]$Params = @{}, [string]$SessionId, [int]$TimeoutMs = 60000) {
    $script:CdpId++
    $id = $script:CdpId
    $message = @{ id = $id; method = $Method; params = $Params }
    if ($SessionId) { $message.sessionId = $SessionId }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($message | ConvertTo-Json -Depth 10 -Compress))
    $segment = New-Object System.ArraySegment[byte] -ArgumentList @(, $bytes)
    $script:Ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
        [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ($true) {
        $reply = Read-CdpMessage ([int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds))
        if (-not $reply) { throw "Timed out waiting for the browser to answer $Method" }
        if ($reply.method) { Receive-CdpEvent $reply; continue }
        if ($reply.id -eq $id) {
            if ($reply.error) { throw "$Method failed: $($reply.error.message)" }
            return $reply.result
        }
    }
}

# Helpers injected into the page on every call, since navigation clears them.
# They search the main document and any same-origin frames.
$script:PageHelpers = @'
(function () {
  function docs() {
    var out = [document];
    for (var i = 0; i < out.length; i++) {
      var frames = out[i].querySelectorAll('iframe, frame');
      for (var j = 0; j < frames.length; j++) {
        try { if (frames[j].contentDocument) out.push(frames[j].contentDocument); } catch (e) {}
      }
    }
    return out;
  }
  function visible(el) {
    var r = el.getBoundingClientRect();
    var s = el.ownerDocument.defaultView.getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
  }
  function norm(t) { return (t || '').replace(/\s+/g, ' ').trim().toLowerCase(); }
  window.__ce = {
    // Visible button/link whose text is exactly `name`. When several match, prefer one
    // that sits near `near` text (e.g. the form's Search button next to "Clear Criteria").
    find: function (name, near) {
      name = norm(name);
      var hits = [];
      docs().forEach(function (d) {
        var els = d.querySelectorAll('button, a, [role=button], input[type=button], input[type=submit]');
        for (var i = 0; i < els.length; i++) {
          var el = els[i];
          var text = norm(el.tagName === 'INPUT' ? el.value : el.innerText);
          if (text === name && visible(el)) hits.push(el);
        }
      });
      if (near && hits.length > 1) {
        var n = norm(near);
        for (var i = 0; i < hits.length; i++) {
          var p = hits[i];
          for (var k = 0; k < 4 && p; k++) {
            p = p.parentElement;
            if (p && norm(p.innerText).indexOf(n) >= 0) return hits[i];
          }
        }
      }
      return hits[0] || null;
    },
    // Centre of the button in top-level page coordinates, for a real mouse click. Returns
    // null if the button is missing or something else is covering it.
    point: function (name, near) {
      var el = this.find(name, near);
      if (!el) return null;
      el.scrollIntoView({ block: 'center' });
      var r = el.getBoundingClientRect();
      var x = r.left + r.width / 2, y = r.top + r.height / 2;
      var hit = el.ownerDocument.elementFromPoint(x, y);
      if (!hit || !(hit === el || el.contains(hit) || hit.contains(el))) return null;
      var win = el.ownerDocument.defaultView;
      while (win.frameElement) {
        var f = win.frameElement.getBoundingClientRect();
        x += f.left; y += f.top;
        win = win.parent;
      }
      return { x: x, y: y };
    },
    click: function (name, near) {
      var el = this.find(name, near);
      if (!el) return false;
      el.scrollIntoView({ block: 'center' });
      el.click();
      return true;
    },
    loading: function () {
      var ds = docs();
      for (var i = 0; i < ds.length; i++) {
        var walker = ds[i].createTreeWalker(ds[i].body || ds[i], NodeFilter.SHOW_TEXT);
        var node;
        while ((node = walker.nextNode())) {
          if (node.nodeValue.indexOf('Loading...') >= 0 && node.parentElement && visible(node.parentElement)) return true;
        }
      }
      return false;
    },
    summary: function () {
      var m = (document.body.innerText || '').match(/\d+\s*-\s*\d+\s+of\s+\d+/);
      return m ? m[0] : '';
    }
  };
})();
'@

function Invoke-Page([string]$Expression) {
    $result = Invoke-Cdp 'Runtime.evaluate' @{
        expression    = "$script:PageHelpers`n$Expression"
        returnByValue = $true
        userGesture   = $true
    } -SessionId $script:Session
    if ($result.exceptionDetails) { return $null }
    return $result.result.value
}

function ConvertTo-JsString([string]$Value) { return ($Value | ConvertTo-Json) }

function Wait-Until([scriptblock]$Condition, [int]$Seconds, [string]$What) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $value = $null
        try { $value = & $Condition } catch { }   # page may be mid-navigation
        if ($value) { return $value }
        Start-Sleep -Milliseconds 1000
    }
    throw "Timed out after $Seconds s waiting for $What"
}

# Clicks a button, waits out any "Loading..." overlay, then waits for the next button to show.
function Invoke-Step([string]$Button, [string]$Near, [string]$NextButton) {
    $name = ConvertTo-JsString $Button
    $nearJs = if ($Near) { ConvertTo-JsString $Near } else { 'null' }
    Wait-Until { Invoke-Page "!!window.__ce.find($name, $nearJs)" } 120 "the '$Button' button" | Out-Null
    Write-Log "Clicking '$Button'"
    # A real mouse click counts as a user gesture, so the browser allows any popup or
    # download it starts. A script click (the fallback) does not.
    $point = Invoke-Page "window.__ce.point($name, $nearJs)"
    if ($point) {
        foreach ($type in 'mouseMoved', 'mousePressed', 'mouseReleased') {
            Invoke-Cdp 'Input.dispatchMouseEvent' @{
                type = $type; x = $point.x; y = $point.y; button = 'left'; clickCount = 1
            } -SessionId $script:Session | Out-Null
        }
    }
    elseif (-not (Invoke-Page "window.__ce.click($name, $nearJs)")) { throw "Could not click '$Button'" }
    if ($NextButton) {
        $next = ConvertTo-JsString $NextButton
        Wait-Until { Invoke-Page "!window.__ce.loading() && !!window.__ce.find($next, null)" } `
            $TimeoutSeconds "loading to finish and '$NextButton' to appear" | Out-Null
    }
}

function Wait-ForDownload([string]$Dir) {
    # Chrome writes *.crdownload until the transfer completes, then renames it.
    # Accept the file once no partial remains and its size is unchanged across two checks.
    # The browser's own download events, when it sends them, settle it sooner.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastSize = -1
    while ((Get-Date) -lt $deadline) {
        Watch-CdpEvents 1000
        if ($script:Download -and $script:Download.State -eq 'canceled') {
            throw "The browser canceled the download of $($script:Download.Name)"
        }
        $partial = Get-ChildItem -Path $Dir -File -Filter '*.crdownload'
        $file = Get-ChildItem -Path $Dir -File |
            Where-Object { $_.Name -notlike '*.crdownload' -and $_.Name -notlike '*.tmp' } |
            Select-Object -First 1
        if ($file -and -not $partial) {
            $completed = $script:Download -and $script:Download.State -eq 'completed'
            if ($completed -or $file.Length -eq $lastSize) { return $file }
            $lastSize = $file.Length
        }
    }
    if (-not $script:Download) {
        throw "No download started within $TimeoutSeconds s of clicking 'Download Attachment'"
    }
    throw "Timed out after $TimeoutSeconds s waiting for $($script:Download.Name) to finish downloading"
}

# Records what the browser was showing when a run failed: a screenshot of each open tab,
# their addresses, and anything left in the download folder.
function Save-Diagnostics([string]$StagingDir) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    try {
        $tabs = (Invoke-Cdp 'Target.getTargets' -TimeoutMs 10000).targetInfos | Where-Object { $_.type -eq 'page' }
        $n = 0
        foreach ($tab in $tabs) {
            $n++
            Write-Log "Open tab ${n}: $($tab.url)"
            if ($tab.url -eq 'about:blank') { continue }
            try {
                # Only the tab in front renders, so bring each one forward before capturing it.
                Invoke-Cdp 'Target.activateTarget' @{ targetId = $tab.targetId } -TimeoutMs 10000 | Out-Null
                $sid = (Invoke-Cdp 'Target.attachToTarget' @{ targetId = $tab.targetId; flatten = $true } -TimeoutMs 10000).sessionId
                $shot = Invoke-Cdp 'Page.captureScreenshot' @{ format = 'png' } -SessionId $sid -TimeoutMs 30000
                $png = Join-Path $OutDir "failure-$stamp-tab$n.png"
                [IO.File]::WriteAllBytes($png, [Convert]::FromBase64String($shot.data))
                Write-Log "Screenshot saved: $png"
            } catch { Write-Log "Could not screenshot tab ${n}: $($_.Exception.Message)" }
        }
    } catch { Write-Log "Could not list browser tabs: $($_.Exception.Message)" }
    $left = @(Get-ChildItem -Path $StagingDir -File -ErrorAction SilentlyContinue)
    if ($left) {
        foreach ($f in $left) { Write-Log ("Download folder holds: {0} ({1:N0} bytes)" -f $f.Name, $f.Length) }
    } else {
        Write-Log 'Download folder is empty'
    }
}

# ---------------------------------------------------------------------------------------------

function Invoke-Export {
    $browser = Find-Browser
    $profileDir = Join-Path ([IO.Path]::GetTempPath()) ("caleprocure-profile-" + [guid]::NewGuid())
    $stagingDir = Join-Path ([IO.Path]::GetTempPath()) ("caleprocure-download-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $profileDir, $stagingDir | Out-Null

    $launchArgs = @(
        "--user-data-dir=`"$profileDir`"",
        '--remote-debugging-port=0',
        '--no-first-run', '--no-default-browser-check', '--disable-extensions',
        '--window-size=1400,1000'
    ) + $BrowserArgs
    if (-not $Headed) { $launchArgs += '--headless=new' }
    $launchArgs += 'about:blank'

    Write-Log "Starting $browser"
    $proc = Start-Process -FilePath $browser -ArgumentList $launchArgs -PassThru
    try {
        # With port 0 the browser picks a free port and writes it to DevToolsActivePort.
        $portFile = Join-Path $profileDir 'DevToolsActivePort'
        Wait-Until { Test-Path $portFile } 60 'the browser to start' | Out-Null
        $lines = Wait-Until {
            $l = @(Get-Content $portFile -ErrorAction SilentlyContinue)
            if ($l.Count -ge 2) { , $l }
        } 30 'the DevTools port'
        Connect-Cdp ("ws://127.0.0.1:{0}{1}" -f $lines[0], $lines[1])

        Invoke-Cdp 'Browser.setDownloadBehavior' @{
            behavior = 'allow'; downloadPath = $stagingDir; eventsEnabled = $true
        } | Out-Null
        Invoke-Cdp 'Target.setDiscoverTargets' @{ discover = $true } | Out-Null

        $target = Invoke-Cdp 'Target.createTarget' @{ url = 'about:blank' }
        $script:TargetId = $target.targetId
        $script:Session = (Invoke-Cdp 'Target.attachToTarget' @{ targetId = $target.targetId; flatten = $true }).sessionId

        # Headless browsers advertise "HeadlessChrome"; present a normal user agent instead.
        $ua = (Invoke-Cdp 'Browser.getVersion').userAgent -replace 'HeadlessChrome', 'Chrome'
        Invoke-Cdp 'Network.setUserAgentOverride' @{ userAgent = $ua } -SessionId $script:Session | Out-Null

        Write-Log "Opening $Url"
        Invoke-Cdp 'Page.navigate' @{ url = $Url } -SessionId $script:Session | Out-Null

        Invoke-Step -Button 'Search' -Near 'Clear Criteria' -NextButton 'Download'
        $summary = Invoke-Page 'window.__ce.summary()'
        if ($summary) { Write-Log "Results: $summary" }

        Invoke-Step -Button 'Download' -NextButton 'Download Attachment'
        Invoke-Step -Button 'Download Attachment'

        $file = Wait-ForDownload $stagingDir
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
        $dest = Join-Path $OutDir $file.Name
        Move-Item -Path $file.FullName -Destination $dest -Force
        Write-Log ("Saved {0} ({1:N0} bytes)" -f $dest, (Get-Item $dest).Length)
        return $dest
    }
    catch {
        if ($script:Ws) { Save-Diagnostics $stagingDir }
        throw
    }
    finally {
        try { Invoke-Cdp 'Browser.close' -TimeoutMs 5000 | Out-Null } catch { }
        if ($script:Ws) { $script:Ws.Dispose(); $script:Ws = $null }
        Start-Sleep -Seconds 2
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        # The profile can stay locked briefly after the browser exits.
        foreach ($dir in $profileDir, $stagingDir) {
            for ($i = 0; $i -lt 5 -and (Test-Path $dir); $i++) {
                Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path $dir) { Start-Sleep -Seconds 2 }
            }
        }
    }
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$script:LogFile = Join-Path $OutDir 'export.log'

for ($attempt = 1; ; $attempt++) {
    try {
        $saved = Invoke-Export
        exit 0
    }
    catch {
        Write-Log "Attempt $attempt failed: $($_.Exception.Message)"
        if ($attempt -gt $Retries) { exit 1 }
        Start-Sleep -Seconds (30 * $attempt)
    }
}
