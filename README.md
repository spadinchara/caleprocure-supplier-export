# Cal eProcure supplier export

Downloads the full list of certified suppliers (MB, SB, SB-PW, DVBE, NVSA, NP) from the
public [Cal eProcure supplier search](https://caleprocure.ca.gov/pages/PublicSearch/supplier-search.aspx?psNewWin=true).

It's a single PowerShell script with **nothing to install**. It runs on Windows PowerShell 5.1
(built into Windows 10/11) and drives Microsoft Edge, which ships with Windows. Chrome works too.

## What it does

It follows the same steps as a person, in a hidden Edge window:

1. Opens the supplier search page.
2. Clicks **Search** with every criterion left blank, so all suppliers are returned (about 22,000).
3. Waits for the **Loading...** overlay to clear and the results toolbar to appear.
4. Clicks **Download** and waits for the overlay again while the file is built.
5. Clicks **Download Attachment** in the "Your file is ready." modal.
6. Saves the file under the server's default name (what the Save As dialog would offer).

Each wait looks for the overlay to clear or the next button to appear, not a fixed delay. If any
step fails, the whole run is retried in a fresh browser. The browser uses its own temporary
profile, so it doesn't touch your normal Edge windows, bookmarks or sign-ins.

## Run it

Copy the `caleprocure-supplier-export` folder to the machine, then in PowerShell:

```powershell
cd C:\path\to\caleprocure-supplier-export
powershell -ExecutionPolicy Bypass -File .\Export-CaleProcureSuppliers.ps1
```

The file is saved to `.\downloads`. Each run adds a line to `downloads\export.log`.

```powershell
# Save somewhere else
.\Export-CaleProcureSuppliers.ps1 -OutDir 'C:\Data\CaleProcure'

# Watch the browser while it runs (recommended for the first run)
.\Export-CaleProcureSuppliers.ps1 -Headed
```

| Parameter | Default | Meaning |
|---|---|---|
| `-OutDir` | `.\downloads` | Folder for the saved file and `export.log` |
| `-TimeoutSeconds` | 600 | Longest wait for each loading step |
| `-Retries` | 2 | Extra attempts after a failure |
| `-Headed` | off | Show the browser window |
| `-BrowserPath` | Edge, then Chrome | Use a specific browser executable |
| `-Url` | Cal eProcure search page | Starting page |

If a file with the same name is already in `-OutDir`, the new download replaces it. The script
exits with code 0 on success and 1 if every attempt fails.

`-ExecutionPolicy Bypass` applies only to this one run. If your organization blocks it, ask IT
to allow or sign the script. Running it with `-File` from a shell they approve also works.

## Schedule it (Windows Task Scheduler)

Run this once in PowerShell to create a daily 6:00 AM job (change the paths and time as needed):

```powershell
$script = 'C:\path\to\caleprocure-supplier-export\Export-CaleProcureSuppliers.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -OutDir `"C:\Data\CaleProcure`""
$trigger = New-ScheduledTaskTrigger -Daily -At 6:00AM
Register-ScheduledTask -TaskName 'CaleProcure Supplier Export' -Action $action -Trigger $trigger
```

## Power Automate Desktop alternative

If you'd rather not run a script, build the same flow in Power Automate Desktop:

1. **Launch new Microsoft Edge**: the URL above.
2. **Press button on web page**: the **Search** button next to *Clear Criteria*.
3. **Wait for web page content**: wait until the text *Download* appears (set a timeout of
   10 minutes or more).
4. **Press button on web page**: **Download**.
5. **Wait for web page content**: wait until the text *Download Attachment* appears.
6. **Download from web** or **Press button on web page**: **Download Attachment**, saving to a folder.
7. **Close web browser**.

Power Automate Desktop needs a signed-in Windows session to run unattended on a schedule.
The PowerShell script doesn't.

## Test

```powershell
.\test\Test-Export.ps1
```

The test serves `test/mock-site.html`, a local page that copies the search, both loading
overlays, the modal and the file download, and runs the exporter against it. It checks the
clicking, waiting and saving logic. It doesn't check the live site.
