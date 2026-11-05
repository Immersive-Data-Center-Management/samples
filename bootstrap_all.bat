@echo off
rem Sets up all experiments: downloads IDTXFlow and links the shared addons. Close Godot first (it locks the DLLs).
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference = 'Stop';" ^
  "& .\shared\bootstrap.ps1 -Project Experiment_1 -Link sample_framework_core, sample_framework_aas;" ^
  "& .\shared\bootstrap.ps1 -Project Experiment_2 -Link sample_framework_core, sample_framework_aas, sample_framework_ar, ARCorePlugin -Android;" ^
  "& .\shared\bootstrap.ps1 -Project Experiment_3 -Link sample_framework_core, sample_framework_ar, ARCorePlugin -Android"
if errorlevel 1 (echo. & echo Setup failed, see the error above.) else (echo. & echo Done.)
pause
