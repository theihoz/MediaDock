Unicode True
RequestExecutionLevel admin

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "nsDialogs.nsh"
!include "x64.nsh"

!ifndef STAGE_DIR
  !error "STAGE_DIR is required"
!endif
!ifndef SOURCE_DIR
  !error "SOURCE_DIR is required"
!endif
!ifndef OUTPUT_FILE
  !define OUTPUT_FILE "install.exe"
!endif

Name "Media Control"
OutFile "${OUTPUT_FILE}"
InstallDir "$PROGRAMFILES64\Media Control"
InstallDirRegKey HKLM "Software\MediaControl" "InstallDir"
ShowInstDetails show
ShowUninstDetails show

!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

Var ConfirmInput

Function .onInit
  SetShellVarContext all
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "Media Control yêu cầu Windows 64-bit."
    Abort
  ${EndIf}
  InitPluginsDir
  SetOutPath "$PLUGINSDIR"
  File /oname=install-local.ps1 "${SOURCE_DIR}\scripts\install-local.ps1"
  ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\install-local.ps1" -PreflightOnly' $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "Thiếu WSL2, Ubuntu, Docker Desktop, Visual C++ Runtime hoặc dung lượng ổ D. Xem chi tiết phía trên rồi chạy lại install.exe."
    Abort
  ${EndIf}
FunctionEnd

Section "Media Control" SEC_MAIN
  SetOutPath "$INSTDIR"
  File /r "${STAGE_DIR}\app\*"
  SetOutPath "$APPDATA\MediaControl\stack"
  File /r "${STAGE_DIR}\stack\*"

  ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$APPDATA\MediaControl\stack\scripts\install-local.ps1" -ProjectDir "$APPDATA\MediaControl\stack" -AppDir "$INSTDIR"' $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "Không thể chuẩn bị Media Control. Không có container nào được khởi động."
    Abort
  ${EndIf}

  FileOpen $1 "$APPDATA\MediaControl\stack\.installation-id" r
  FileRead $1 $2
  FileClose $1
  ${If} $2 == ""
    MessageBox MB_ICONSTOP "Không thể tạo installation ID."
    Abort
  ${EndIf}

  WriteUninstaller "$INSTDIR\uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Media Control"
  CreateShortcut "$SMPROGRAMS\Media Control\Media Control.lnk" "$INSTDIR\media_control.exe"
  CreateShortcut "$SMPROGRAMS\Media Control\Gỡ Media Control.lnk" "$INSTDIR\uninstall.exe"
  CreateShortcut "$DESKTOP\Media Control.lnk" "$INSTDIR\media_control.exe"

  WriteRegStr HKLM "Software\MediaControl" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\MediaControl" "ProjectDir" "$APPDATA\MediaControl\stack"
  WriteRegStr HKLM "Software\MediaControl" "MediaRoot" "D:\Media"
  WriteRegStr HKLM "Software\MediaControl" "InstallationId" "$2"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MediaControl" "DisplayName" "Media Control"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MediaControl" "DisplayVersion" "0.1.0"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MediaControl" "Publisher" "Media Control"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MediaControl" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MediaControl" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MediaControl" "NoModify" 1
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MediaControl" "NoRepair" 1
SectionEnd

UninstPage custom un.ConfirmDeletePage un.ConfirmDeleteLeave
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Function un.onInit
  SetShellVarContext all
  IfSilent block_silent_uninstall allow_interactive_uninstall
  block_silent_uninstall:
    MessageBox MB_ICONSTOP "Silent uninstall bị vô hiệu hóa vì D:\Media chỉ được xóa sau khi nhập XOA TOAN BO."
    Abort
  allow_interactive_uninstall:
FunctionEnd

Function un.ConfirmDeletePage
  nsDialogs::Create 1018
  Pop $0
  ${If} $0 == error
    Abort
  ${EndIf}
  ${NSD_CreateLabel} 0 0 100% 42u "Gỡ cài đặt sẽ xóa vĩnh viễn ứng dụng, containers, database, phim, TV Show, download, phụ đề, backup và toàn bộ D:\Media.$\r$\n$\r$\nNhập XOA TOAN BO để xác nhận:"
  Pop $0
  ${NSD_CreateText} 0 48u 100% 14u ""
  Pop $ConfirmInput
  nsDialogs::Show
FunctionEnd

Function un.ConfirmDeleteLeave
  ${NSD_GetText} $ConfirmInput $0
  ${If} $0 != "XOA TOAN BO"
    MessageBox MB_ICONEXCLAMATION "Nội dung xác nhận không đúng."
    Abort
  ${EndIf}
FunctionEnd

Section "Uninstall"
  ReadRegStr $0 HKLM "Software\MediaControl" "InstallationId"
  ${If} $0 == ""
    MessageBox MB_ICONSTOP "Không tìm thấy installation ID; từ chối xóa D:\Media."
    Quit
  ${EndIf}
  ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$APPDATA\MediaControl\stack\scripts\uninstall-cleanup.ps1" -MediaRoot "D:\Media" -ProjectDir "$APPDATA\MediaControl\stack" -ExpectedInstallationId "$0"' $1
  ${If} $1 != 0
    MessageBox MB_ICONSTOP "Không thể dọn Docker hoặc xác minh dữ liệu. Chưa xóa thư mục cài đặt; hãy sửa lỗi và chạy uninstall.exe lại."
    Quit
  ${EndIf}

  Delete "$DESKTOP\Media Control.lnk"
  RMDir /r "$SMPROGRAMS\Media Control"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\MediaControl"
  DeleteRegKey HKLM "Software\MediaControl"
  RMDir /r "$APPDATA\MediaControl"
  RMDir /r "$INSTDIR"
SectionEnd
