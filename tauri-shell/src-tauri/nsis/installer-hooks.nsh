; ============================================================
;  installer-hooks.nsh - AwayFromShorts NSIS installer hooks
;
;  Included by tauri's installer.nsi via
;    bundle > windows > nsis > installerHooks
;
;  Hooks:
;    NSIS_HOOK_PREINSTALL     - elevation-context guard (cross-account UAC)
;    NSIS_HOOK_POSTINSTALL    - nsis-install.ps1 orchestration
;    NSIS_HOOK_PREUNINSTALL   - guard check + nsis-uninstall.ps1 cleanup
;    NSIS_HOOK_POSTUNINSTALL  - final log
;
;  AFS_SETUP_DRYRUN=1 in the environment makes the PowerShell helpers
;  skip all globally-visible side effects (used for isolated QA).
;
;  NOTE: keep this file pure ASCII. NSIS/makensis reads .nsh as ANSI.
; ============================================================

!include LogicLib.nsh

Var AfsDryRun
Var AfsPsArgs
Var AfsExitCode
Var AfsCheckResult
Var AfsElevationCmd

; PowerShell -EncodedCommand (UTF-16LE) of the elevation-context check.
; Returns 1 when the elevated process user differs from the interactively
; logged-on user (i.e. UAC used a DIFFERENT admin account), 0 otherwise.
; Fails OPEN (0) when it cannot determine the logon user or when the
; logon name looks like a Microsoft account (name contains '@').
; Plain text:
;   $proc = [Security.Principal.WindowsIdentity]::GetCurrent().Name
;   $logon = ''
;   try { $logon = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch {}
;   if (-not $logon) { exit 0 }
;   if ($logon -like '*@*') { exit 0 }
;   $pn = ($proc -split '\\')[-1]
;   $ln = ($logon -split '\\')[-1]
;   if (-not $pn -or -not $ln) { exit 0 }
;   if ($pn -ne $ln) { exit 1 }
;   exit 0
!define AFS_ELEVATION_CHECK "JABwAHIAbwBjACAAPQAgAFsAUwBlAGMAdQByAGkAdAB5AC4AUAByAGkAbgBjAGkAcABhAGwALgBXAGkAbwBuAGQAb3dzAEkAZABlAG4AdABpAHQAeQBdADoAOgBHAGUAdABDAHUAcgByAGUAbgB0ACgAKQAuAE4AYQBtAGUACgAkAGwAbwBnAG8AbgAgAD0AIAAnACcACgB0AHIAeQAgAHsAIAAkAGwAbwBnAG8AbgAgAD0AIAAoAEcAZQB0AC0AQwBpAG0ASQBuAHMAdABhAG4AYwBlACAAVwBpAG4AMwAyAF8AQwBvAG0AcAB1AHQAZQByAFMAeQBzAHQAZQBtACAALQBFAHIAcgBvAHIAQQBjAHQAaQBvAG4AIABTAHQAbwBwACkALgBVAHMAZQByAE4AYQBtAGUAIAB9ACAAYwBhAHQAYwBoACAAewB9AAoAaQBmACAAKAAtAG4AbwB0ACAAJABsAG8AZwBvAG4AKQAgAHsAIABlAHgAaQB0ACAAMAAgAH0ACgBpAGYAIAAoACQAbABvAGcAbwBuACAALQBsAGkAawBlACAAJwAqAEAAKgAnACkAIAB7ACAAZQB4AGkAdAAgADAAIAB9AAoAJABwAG4AIAA9ACAAKAAkAHAAcgBvAGMAIAAtAHMAcABsAGkAdAAgACcAXABcACcAKQBbAC0AMQBdAAoAJABsAG4AIAA9ACAAKAAkAGwAbwBnAG8AbgAgAC0AcwBwAGwAaQB0ACAAJwBcAFwAJwApAFsALQAxAF0ACgBpAGYAIAAoAC0AbgBvAHQAIAAkAHAAbgAgAC0AbwByACAALQBuAG8AdAAgACQAbABuACkAIAB7ACAAZQB4AGkAdAAgADAAIAB9AAoAaQBmACAAKAAkAHAAbgAgAC0AbgBlACAAJABsAG4AKQAgAHsAIABlAHgAaQB0ACAAMQAgAH0ACgBlAHgAaQB0ACAAMAA="

; Helper: read AFS_SETUP_DRYRUN from the environment into $AfsDryRun (0/1)
!macro AFS_READ_DRYRUN
  StrCpy $AfsDryRun "0"
  ReadEnvStr $AfsPsArgs "AFS_SETUP_DRYRUN"
  ${If} $AfsPsArgs != ""
    StrCpy $AfsDryRun "1"
  ${EndIf}
  StrCpy $AfsPsArgs ""
!macroend

; Helper: append -DryRun to $AfsPsArgs when enabled
!macro AFS_APPEND_DRYRUN
  ${If} $AfsDryRun == "1"
    StrCpy $AfsPsArgs "$AfsPsArgs -DryRun"
  ${EndIf}
!macroend

; ------------------------------------------------------------
!macro NSIS_HOOK_PREINSTALL
  !insertmacro AFS_READ_DRYRUN

  ; Cross-account UAC guard.
  ; RequestExecutionLevel admin + currentUser: if the user answers the UAC
  ; prompt with a DIFFERENT administrator account, $LOCALAPPDATA points at
  ; that other account's profile and we would install into the wrong place.
  ; Abort early (before any file is copied) in that case.
  nsExec::ExecToStack 'powershell.exe -NoProfile -WindowStyle Hidden -EncodedCommand ${AFS_ELEVATION_CHECK}'
  Pop $AfsExitCode
  Pop $AfsCheckResult
  ${If} $AfsExitCode == "1"
    MessageBox MB_OK|MB_ICONSTOP "AwayFromShorts setup was elevated with a different administrator account.$\n$\nPlease run the installer again using the administrator rights of the CURRENTLY logged-on account, so the app installs into your own %LOCALAPPDATA% folder."
    Abort
  ${EndIf}
  ; exit codes other than 0/1 mean the check itself failed -> fail open.
!macroend

; ------------------------------------------------------------
!macro NSIS_HOOK_POSTINSTALL
  StrCpy $AfsPsArgs '-AppDir "$INSTDIR"'
  !insertmacro AFS_APPEND_DRYRUN
  DetailPrint "Running AwayFromShorts post-install (dryrun=$AfsDryRun)..."
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\nsis-install.ps1" $AfsPsArgs'
  Pop $AfsExitCode
  DetailPrint "post-install exit: $AfsExitCode"
  ${If} $AfsExitCode == "3"
    MessageBox MB_OK|MB_ICONEXCLAMATION "Failed to register the AwayFromShorts scheduled task. Blocking may not work. Re-run the installer as administrator."
  ${EndIf}
!macroend

; ------------------------------------------------------------
!macro NSIS_HOOK_PREUNINSTALL
  !insertmacro AFS_READ_DRYRUN

  ; Step 1: read-only Force Mode guard. exit 1 => Abort the whole uninstall.
  nsExec::ExecToStack 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\nsis-uninstall.ps1" -AppDir "$INSTDIR" -CheckOnly'
  Pop $AfsExitCode
  Pop $AfsCheckResult
  ${If} $AfsExitCode == "1"
    MessageBox MB_OK|MB_ICONSTOP "AwayFromShorts uninstall is blocked by Force Mode (currently inside a blocking window).$\n$\nNothing was changed. Please wait until the blocking period ends and try again."
    Abort
  ${EndIf}

  ; Step 2: cleanup (self-elevating if needed). Never let a failed cleanup
  ; block file removal, but surface it to the user.
  StrCpy $AfsPsArgs '-AppDir "$INSTDIR" -Cleanup'
  !insertmacro AFS_APPEND_DRYRUN
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\nsis-uninstall.ps1" $AfsPsArgs'
  Pop $AfsExitCode
  DetailPrint "pre-uninstall cleanup exit: $AfsExitCode"
  ${If} $AfsExitCode == "5"
    MessageBox MB_OK|MB_ICONEXCLAMATION "Administrator rights were denied. Scheduled tasks and hosts entries may remain; please remove them manually or run the uninstaller again as administrator."
  ${EndIf}
!macroend

; ------------------------------------------------------------
!macro NSIS_HOOK_POSTUNINSTALL
  DetailPrint "AwayFromShorts uninstall finished. Install directory removed by NSIS."
!macroend
