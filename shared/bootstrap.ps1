# Sets up an experiment's addons/ folder. Each experiment's bootstrap.ps1 calls this. Close Godot first (it locks the DLLs).
#   powershell -ExecutionPolicy Bypass -File ..\shared\bootstrap.ps1 -Project . -Link sample_framework_core, sample_framework_aas [-Android]
#
# 1. Downloads the pinned IDTXFlow release into addons/IDTXFlow (Windows binaries).
#    With -Android it also copies the IDTXFlow Android binaries from shared/idtxflow_android
#    (not in the public release yet).
# 2. Links the shared addons named in -Link (folders in shared/addons/) as directory junctions.
#    Junctions need no admin rights and no Developer Mode. The files live once in shared/addons/;
#    edits made in the Godot editor land there directly. All links are gitignored.
# 3. With sample_framework_ar, downloads Google's arcoreimg (image target quality check).
#
# To remove a link and keep the shared files:  cmd /c rmdir addons\<name>
# Never delete a link with Explorer or Remove-Item -Recurse: older tools follow it and delete the shared files.
param(
    [Parameter(Mandatory)][string]$Project,
    [string[]]$Link = @(),
    [switch]$Android
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # the progress bar makes Invoke-WebRequest very slow

$Version = "0.6.0"
$Sha256 = "8DD501616CCCCC7E4CD76AE3AFBE4D75500EFAE381C2A15FA108D9EA1B304EDF"
$Url = "https://github.com/Immersive-Data-Center-Management/idtx-flow/releases/download/v$Version/gdextension-Windows.zip"

$Addons = Join-Path (Resolve-Path $Project) "addons"
New-Item -ItemType Directory -Force $Addons | Out-Null

# --- IDTXFlow ---
$Target = Join-Path $Addons "IDTXFlow"
$Cfg = Join-Path $Target "plugin.cfg"
if ((Test-Path $Cfg) -and (Select-String -Path $Cfg -SimpleMatch "version=""$Version""" -Quiet)) {
    Write-Host "IDTXFlow $Version already installed."
} else {
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
}

if ($Android) {
    # shortcut: Android binaries are committed in shared/idtxflow_android until idtx-flow publishes an Android release;
    # then download them here like the Windows zip.
    Copy-Item -Recurse -Force (Join-Path $PSScriptRoot "idtxflow_android\*") $Target
    Write-Host "Added IDTXFlow Android binaries."
}

# --- shared addons ---
foreach ($Name in $Link) {
    $Source = Join-Path $PSScriptRoot "addons\$Name"
    $Dest = Join-Path $Addons $Name
    if (-not (Test-Path $Source)) { throw "Shared addon not found: $Source" }
    if (Test-Path $Dest) {
        if ((Get-Item $Dest -Force).LinkType) { Write-Host "addons/$Name already linked."; continue }
        throw "$Dest exists and is not a link. Move it away first."
    }
    New-Item -ItemType Junction -Path $Dest -Target $Source | Out-Null
    Write-Host "Linked addons/$Name -> shared/addons/$Name"
}

# --- arcoreimg (editor only: "Evaluate target quality" of ImageTrackedComponent) ---
# Google's tool from the ARCore SDK, under the ARCore Additional Terms of Service, so it is
# downloaded (pinned commit + SHA256) instead of committed. Lands in the shared addon, gitignored.
if ($Link -contains "sample_framework_ar") {
    $ImgTool = Join-Path $PSScriptRoot "addons\sample_framework_ar\tools\arcoreimg.exe"
    $ImgSha256 = "9EAF4D810925D0BFC1BB8C08FA31CD62C9E0696E39169110C1C5C9A1923AAB30"
    $ImgUrl = "https://raw.githubusercontent.com/google-ar/arcore-android-sdk/204ddfd1715eb0cb775bf7528c9aee9d93cd4d4a/tools/arcoreimg/windows/arcoreimg.exe"
    if ((Test-Path $ImgTool) -and (Get-FileHash $ImgTool -Algorithm SHA256).Hash -eq $ImgSha256) {
        Write-Host "arcoreimg already installed."
    } else {
        New-Item -ItemType Directory -Force (Split-Path $ImgTool) | Out-Null
        Write-Host "Downloading arcoreimg (ARCore SDK 1.57.0)..."
        Invoke-WebRequest -Uri $ImgUrl -OutFile $ImgTool
        $Actual = (Get-FileHash $ImgTool -Algorithm SHA256).Hash
        if ($Actual -ne $ImgSha256) {
            Remove-Item $ImgTool
            throw "SHA256 mismatch for $ImgUrl`n expected $ImgSha256`n got      $Actual"
        }
        Write-Host "Installed arcoreimg to $ImgTool"
    }
}
