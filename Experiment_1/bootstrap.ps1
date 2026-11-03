# Downloads the pinned IDTXFlow release into addons/IDTXFlow. Close Godot first (it locks the DLLs).
#   powershell -ExecutionPolicy Bypass -File bootstrap.ps1
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # the progress bar makes Invoke-WebRequest very slow

$Version = "0.6.0"
$Sha256 = "8DD501616CCCCC7E4CD76AE3AFBE4D75500EFAE381C2A15FA108D9EA1B304EDF"
$Url = "https://github.com/Immersive-Data-Center-Management/idtx-flow/releases/download/v$Version/gdextension-Windows.zip"

$Addons = Join-Path $PSScriptRoot "addons"
$Target = Join-Path $Addons "IDTXFlow"
$Cfg = Join-Path $Target "plugin.cfg"
if ((Test-Path $Cfg) -and (Select-String -Path $Cfg -SimpleMatch "version=""$Version""" -Quiet)) {
    Write-Host "IDTXFlow $Version already installed."
    exit 0
}

$Zip = Join-Path ([IO.Path]::GetTempPath()) "idtxflow-$Version-windows.zip"
Write-Host "Downloading IDTXFlow $Version..."
Invoke-WebRequest -Uri $Url -OutFile $Zip
$Actual = (Get-FileHash $Zip -Algorithm SHA256).Hash
if ($Actual -ne $Sha256) {
    Remove-Item $Zip
    throw "SHA256 mismatch for $Url`n expected $Sha256`n got      $Actual"
}

if (Test-Path $Target) { Remove-Item -Recurse -Force $Target }
Expand-Archive -Path $Zip -DestinationPath $Addons  # the zip contains IDTXFlow/
Remove-Item $Zip
Write-Host "Installed IDTXFlow $Version to $Target"
