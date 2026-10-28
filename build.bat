@echo off
REM Run on Windows with Python 3.11+ and Inno Setup 6 installed.
REM WireGuard and wstunnel are downloaded by Burrow on first run.
cd /d %~dp0
python -m pip install -r requirements.txt pyinstaller || exit /b 1
python app.py --icon
set ICON=
if exist burrow.ico set ICON=--icon burrow.ico
pyinstaller --noconfirm --onefile --windowed --uac-admin --add-data "server-setup.sh;resources" --hidden-import paramiko --collect-data certifi --collect-submodules keyring --copy-metadata keyring --name Burrow %ICON% app.py || exit /b 1
set ISCC="%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
if not exist %ISCC% echo Install Inno Setup 6 from jrsoftware.org, then run this again. & exit /b 1
%ISCC% installer.iss
echo.
echo Done: installer\Burrow-Setup.exe
