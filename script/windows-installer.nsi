Unicode True
!include "MUI2.nsh"
Name "Noise ${VERSION}"
OutFile "${OUTPUT}"
InstallDir "$LOCALAPPDATA\Programs\Noise"
RequestExecutionLevel user
SetCompressor /SOLID lzma
!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\Noise.exe"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
Section "Noise"
  SetOutPath "$INSTDIR"
  File /r "${STAGE}\*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Noise"
  CreateShortcut "$SMPROGRAMS\Noise\Noise.lnk" "$INSTDIR\Noise.exe"
  CreateShortcut "$SMPROGRAMS\Noise\Uninstall.lnk" "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Noise" "DisplayName" "Noise"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Noise" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Noise" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Noise" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Noise" "NoRepair" 1
SectionEnd
Section "Uninstall"
  MessageBox MB_OKCANCEL "Restore filtered apps to Default output in Windows Volume mixer before uninstalling Noise. Your virtual audio drivers and saved preferences are managed separately." IDOK +2
  Abort
  RMDir /r "$SMPROGRAMS\Noise"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Noise"
SectionEnd
