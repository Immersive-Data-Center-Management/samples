# Installs IDTXFlow (Windows + Android) and links the shared AR addons into addons/. Close Godot first (it locks the DLLs).
#   powershell -ExecutionPolicy Bypass -File bootstrap.ps1
& (Join-Path $PSScriptRoot "..\shared\bootstrap.ps1") -Project $PSScriptRoot -Link sample_framework_core, sample_framework_ar, ARCorePlugin -Android
