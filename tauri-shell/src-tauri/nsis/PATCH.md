# Tauri NSIS Template Patch

`installer.nsi` in this folder is a copy of the official `tauri-bundler`
**v2.10.4** NSIS template, with one approved change.

## Upstream source

- Package: `tauri-bundler` v2.10.4
- File: `src/bundle/windows/nsis/installer.nsi`
- Path on this machine: `~\.cargo\registry\src\index.crates.io-*\tauri-bundler-2.10.4\src\bundle\windows\nsis\installer.nsi`
- **Upstream SHA256**: `D00089D3B1A2C4A30D7B6E098079100CB8F25E980F84D4515ACA4597B95E967D`
- Upstream line count: 1022

This copy:

- **Patched SHA256**: `B9B84D5620C36FB873D3239681DB6FFC01D03091DC3082A77EFFEDD0A64A2BE1`
- Patched line count: 1026 (upstream + 4 comment lines)

## The only change

In the `currentUser` branch (upstream L110-112):

```nsis
!if "${INSTALLMODE}" == "currentUser"
  RequestExecutionLevel user     ; <-- upstream
!endif
```

becomes

```nsis
!if "${INSTALLMODE}" == "currentUser"
  ; ...4 AFS comment lines...
  RequestExecutionLevel admin    ; <-- patched
!endif
```

### Why

- `installMode: currentUser` keeps `$INSTDIR = $LOCALAPPDATA\AwayFromShorts`
  (pure ASCII, avoids the WebView2 non-ASCII-path crash, matches the original
  install.bat location, and keeps HKCU registry + current-user shortcuts).
- But hosts backup and scheduled-task registration need administrator rights.
- Upstream hardcodes `RequestExecutionLevel user` for currentUser, so the
  installer would not be elevated. Changing it to `admin` gives one UAC prompt
  for the whole install and lets every `ExecWait` PowerShell call inherit admin.
- No PREINSTALL `$INSTDIR` hack needed: `$INSTDIR` stays consistent from
  `.onInit` through `WriteUninstaller`, registry `InstallLocation`, shortcuts
  and the uninstaller.

Everything else is byte-for-byte upstream. `installer-hooks.nsh` (a separate
file wired via `bundle > windows > nsis > installerHooks`) carries all custom
logic, so the template copy stays minimal.

## Drift check (run after upgrading Tauri)

```powershell
cd tauri-shell\src-tauri\nsis
powershell -ExecutionPolicy Bypass -File check-template-drift.ps1
# If the bundler version changed, point it at the new template explicitly:
powershell -ExecutionPolicy Bypass -File check-template-drift.ps1 -Upstream <path-to-installer.nsi>
```

It reverse-applies the patch (removes the 4 comment lines, restores `user`)
and compares line-by-line with upstream. Any output other than
`OK: ... No drift.` means you must re-sync.

**On a Tauri upgrade:** re-copy the new upstream `installer.nsi`, re-apply the
single `user` -> `admin` change, update the two SHA256 values above, then run
the drift check. Do not let an old template silently pin the bundler version.

## Limitations

- `RequestExecutionLevel admin` + currentUser: if UAC is answered with a
  **different administrator account**, `$LOCALAPPDATA` resolves to that
  account's profile and files would land in the wrong place.
  `installer-hooks.nsh` PREINSTALL runs a fail-open check comparing the
  elevated process user with the interactive logon user and aborts with an
  explanatory message on mismatch. See README.md.
