# Exports the animations, the mannequin and the motion matching setup from Unreal's Game Animation Sample,
# imports them into this Godot project and builds the pose search databases. Needs Unreal Engine 5.8 and
# the sample project (free on Fab), opened once in the editor so its shaders and assets are cached.
#
#   .\tools\extract_gasp.ps1 -UnrealProject "C:\Users\you\Documents\Unreal Projects\GameAnimationSample\GameAnimationSample.uproject" -Godot "C:\Godot\Godot_v4.7-stable_win64.exe"
#   .\tools\extract_gasp.ps1 -UnrealProject <...> -Godot <...> -Limit 5      # quick test: 5 assets of each kind
param(
    [Parameter(Mandatory = $true)][string]$UnrealProject,
    [Parameter(Mandatory = $true)][string]$Godot,
    [string]$UnrealEditor = "C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe",
    [int]$Limit = 0
)
$ErrorActionPreference = "Stop"

$meshImport = @'
[remap]

importer="scene"
importer_version=1

[params]

nodes/import_as_skeleton_bones=false
meshes/ensure_tangents=true
skins/use_named_skins=true
animation/import=false
fbx/importer=0
fbx/embedded_image_handling=1
fbx/naming_version=2
'@

function Write-ImportFiles([string]$dir) {
    $template = @'
[remap]

importer="animation_library"
importer_version=1

[params]

animation/import=true
animation/fps=30
animation/trimming=false
animation/remove_immutable_tracks=false
import_script/path="res://tools/import/clip_post_import.gd"
fbx/importer=0
'@
    $n = 0
    Get-ChildItem $dir -Recurse -Filter *.fbx | ForEach-Object {
        $imp = $_.FullName + ".import"
        if (-not (Test-Path $imp)) { [System.IO.File]::WriteAllText($imp, $template); $n++ }
    }
    "$n import files written"
}

# Godot is a GUI program, so PowerShell's & doesn't wait for it; Start-Process -Wait does.
# (Windows PowerShell doesn't quote arguments with spaces itself, so paths are passed quoted.)
function Invoke-Godot([string[]]$arguments, [string]$log) {
    Start-Process -FilePath $Godot -ArgumentList $arguments -Wait -NoNewWindow -RedirectStandardOutput $log -RedirectStandardError ($log + ".err")
}

$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "extracted"
if (-not (Test-Path $UnrealProject)) { throw "Unreal project not found: $UnrealProject" }
if (-not (Test-Path $UnrealEditor)) { throw "UnrealEditor-Cmd.exe not found: $UnrealEditor (pass -UnrealEditor)" }
if (-not (Test-Path $Godot)) { throw "Godot not found: $Godot" }

# 1. Unreal, headless: clips (FBX), the UEFN mannequin (glTF, its skeleton is used for clip math), every motion matching asset and blueprint as text, then JSON.
New-Item -ItemType Directory -Force $out | Out-Null
$env:GASP_OUT = $out
$env:GASP_LIMIT = "$Limit"
$log = Join-Path $out "export.log"
Write-Host "1/4 Exporting from Unreal (about 5 minutes)..."
& $UnrealEditor $UnrealProject -run=pythonscript "-script=$(Join-Path $PSScriptRoot 'unreal\export_gasp.py')" -unattended -nop4 -nosplash -nullrhi -stdout *> $log
$manifest = Join-Path $out "manifest.json"
if (-not (Test-Path $manifest)) { throw "Export did not finish. See $log" }
$m = Get-Content $manifest -Raw | ConvertFrom-Json
$m.counts.PSObject.Properties | ForEach-Object { "  {0,-28} {1}" -f $_.Name, $_.Value }
"  {0} files written, {1} errors" -f $m.files.Count, $m.errors.Count
if ($m.errors.Count) { $m.errors | Select-Object -First 20 }
foreach ($p in @("data\sequences.json", "data\retarget.json", "audio\foley_bank.json")) {
    if (-not (Test-Path (Join-Path $out $p))) { throw "extracted\$p is missing. See $log" }
}

# 2. Unreal again, in the full editor (a window opens and closes): Manny as FBX. The FBX exporter needs a
#    renderer, so this step can't run headless.
Write-Host "2/4 Exporting Manny from the Unreal editor (about 2 minutes)..."
$gui = Join-Path (Split-Path -Parent $UnrealEditor) "UnrealEditor.exe"
$mannyLog = Join-Path $out "export_manny.log"
Start-Process -FilePath $gui -ArgumentList @("`"$UnrealProject`"", "-ExecutePythonScript=`"$(Join-Path $PSScriptRoot 'unreal\export_manny.py')`"", "-unattended", "-nosplash", "-nop4", "-abslog=`"$mannyLog`"") -Wait
$manny = Join-Path $out "mesh\SKM_Manny_Simple.fbx"
if (-not (Test-Path $manny)) { throw "Manny export failed. See $mannyLog" }
if (-not (Test-Path ($manny + ".import"))) { [System.IO.File]::WriteAllText($manny + ".import", $meshImport) }

# 3. Godot import. The text dumps are large and not resources: keep Godot from scanning them.
Write-Host "3/4 Importing into Godot (about 3 minutes)..."
New-Item -ItemType File -Force (Join-Path $out "t3d\.gdignore") | Out-Null
Write-ImportFiles (Join-Path $out "anims")
Invoke-Godot @("--headless", "--path", "`"$root`"", "--import") (Join-Path $out "import.log")

# 4. Pose search databases.
Write-Host "4/4 Building the pose search databases (about 1 minute)..."
Invoke-Godot @("--headless", "--path", "`"$root`"", "--script", "res://tools/bake/bake_databases.gd") (Join-Path $out "bake.log")
Select-String -Path (Join-Path $out "bake.log") -Pattern "^BAKED" | ForEach-Object { "  " + $_.Line }
if (-not (Test-Path (Join-Path $root "databases\MotionMatchingData"))) { throw "The databases were not built. See the logs in $out" }
if (Select-String -Path (Join-Path $out "bake.log.err") -Pattern "SCRIPT ERROR" -Quiet) { throw "Build failed. See $(Join-Path $out 'bake.log.err')" }
Write-Host "Done. Open the project in Godot and press Play."
exit 0  # Unreal's exit code is 1 whenever it logged an error, even a harmless one
