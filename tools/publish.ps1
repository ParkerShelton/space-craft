# Build the game and the dedicated server, and put both into a shared folder.
#
# The folder is meant to live in Dropbox (or anything else that syncs), so the
# people you play with get each update by doing nothing at all -- which is why
# this writes loose files rather than a zip: a zip has to be re-downloaded and
# re-extracted by hand every time, and it is easy to end up playing an old one.
#
#   powershell -ExecutionPolicy Bypass -File tools\publish.ps1
#   powershell -ExecutionPolicy Bypass -File tools\publish.ps1 -To "D:\somewhere else"

param(
    [string]$To = "$env:USERPROFILE\Dropbox\SpaceCraft",
    [string]$Godot = "$env:USERPROFILE\Desktop\Godot_v4.6-stable_win64.exe\Godot_v4.6-stable_win64_console.exe"
)

$ErrorActionPreference = "Stop"
$proj = Split-Path -Parent $PSScriptRoot
$build = Join-Path $proj "build"

if (-not (Test-Path $Godot)) { throw "Godot not found at $Godot -- pass -Godot <path>" }

Write-Host "exporting..." -ForegroundColor Cyan
# Every target, every time. Publishing a stale binary alongside fresh ones is
# the worst outcome here -- the folder looks updated, and whoever is running the
# server is on old code with no way to tell -- so the old outputs are DELETED
# first and their absence afterwards is treated as a failed build.
$started = Get-Date
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$build\client", "$build\server", "$build\linux"
New-Item -ItemType Directory -Force -Path "$build\client", "$build\server" | Out-Null
& $Godot --headless --path $proj --export-release "Windows Desktop" "$build\client\SpaceCraft.exe" | Out-Null
& $Godot --headless --path $proj --export-release "Windows Server" "$build\server\SpaceCraftServer.exe" | Out-Null
# The Linux server is one self-contained file (the pack is embedded), because it
# gets copied onto a box by hand and a binary that needs its .pck beside it is a
# thing to get wrong at the far end.
New-Item -ItemType Directory -Force -Path "$build\linux" | Out-Null
& $Godot --headless --path $proj --export-release "Linux Server" "$build\linux\SpaceCraftServer.x86_64" | Out-Null
foreach ($f in "$build\client\SpaceCraft.exe", "$build\server\SpaceCraftServer.exe",
        "$build\linux\SpaceCraftServer.x86_64") {
    if (-not (Test-Path $f)) { throw "export produced nothing at $f" }
    $age = (Get-Item $f).LastWriteTime
    if ($age -lt $started) {
        throw "$f was not rebuilt by this run (written $age). Refusing to publish a stale build."
    }
}

# Written into the folder so anyone can see whether they have the newest build
# without asking -- and so "it still does the old thing" is answerable.
$commit = (& git -C $proj rev-parse --short HEAD)
$subject = (& git -C $proj log -1 --format=%s)
$stamp = Get-Date -Format "yyyy-MM-dd HH:mm"

Write-Host "publishing to $To" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path "$To\Game", "$To\Server", "$To\Server-Linux" | Out-Null
Copy-Item "$build\client\SpaceCraft.exe", "$build\client\SpaceCraft.pck" "$To\Game" -Force
Copy-Item "$build\server\SpaceCraftServer.exe", "$build\server\SpaceCraftServer.pck" "$To\Server" -Force
Copy-Item "$build\linux\SpaceCraftServer.x86_64" "$To\Server-Linux" -Force
Copy-Item "$proj\SERVER.md" "$To\Server" -Force
Copy-Item "$proj\SERVER.md" "$To\Server-Linux" -Force
# The hand-written docs live in the repo (dist\), so this script never has to
# hold a copy of them and they can be reviewed like anything else.
Copy-Item "$proj\dist\Game-README.txt" "$To\Game\README.txt" -Force
Copy-Item "$proj\dist\Server-README.txt" "$To\Server\README.txt" -Force
Copy-Item "$proj\dist\START-HERE.txt" "$To\START-HERE.txt" -Force
Copy-Item "$proj\dist\Server-Linux-README.txt" "$To\Server-Linux\README.txt" -Force
# .bat with the Windows build, .sh with the Linux one: shipping both in both
# folders is how somebody ends up running the script that cannot work.
Copy-Item "$proj\dist\start-server.bat" "$To\Server" -Force
Copy-Item "$proj\dist\start-server.sh" "$To\Server-Linux" -Force

"SpaceCraft build $stamp`r`n$commit  $subject`r`n" | Set-Content "$To\VERSION.txt" -Encoding utf8

Write-Host "done -- $stamp ($commit)" -ForegroundColor Green
# Timestamps included so a glance at the summary shows all three binaries were
# refreshed together, rather than leaving it to be taken on trust.
Get-ChildItem $To -Recurse -File | Select-Object @{n='file';e={$_.FullName.Substring($To.Length+1)}},
    @{n='MB';e={[math]::Round($_.Length/1MB,2)}},
    @{n='written';e={$_.LastWriteTime.ToString('MM-dd HH:mm')}} | Format-Table -AutoSize
