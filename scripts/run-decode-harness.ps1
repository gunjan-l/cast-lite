<#
Decode harness: proves the HLS served by MirrorSession decodes with real ffmpeg (podman, local only).

Rerun:  powershell -File scripts\run-decode-harness.ps1
Needs:  podman (machine running), network access to pull swift:5.10 and alpine:3.20.
Steps:  1. ffmpeg container generates 1280x720 H.264 (1s GOP, no B-frames, headers repeated per keyframe).
        2. swift container runs CastLiteHarness: splits it into access units (90 kHz PTS) and feeds
           MirrorSession browser-only in real time.
        3. a sibling ffmpeg container on the same podman network fetches playlist + segments and decodes.
Fails on: any ffmpeg decoder error/warning, frame count below 80% of the completed GOPs, PTS going backwards.
Exit code is non-zero on failure.
#>
param([int]$Seconds = 5, [int]$Fps = 25)
$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$work = Join-Path ([IO.Path]::GetTempPath()) "castlite-harness"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null

$net = "castlite-harness-net"
$server = "castlite-harness-server"
$alpine = "docker.io/library/alpine:3.20"
$swift = "docker.io/library/swift:5.10"

if (-not (podman info 2>$null)) { podman machine start }
podman rm -f $server 2>$null | Out-Null
podman network exists $net 2>$null; if ($LASTEXITCODE -ne 0) { podman network create $net | Out-Null }

$exit = 1
try {
    Write-Host "Generating test stream..." -ForegroundColor Cyan
    podman run --rm -v "${work}:/work:z" $alpine sh -c "apk add --no-cache ffmpeg >/dev/null && ffmpeg -v error -f lavfi -i testsrc2=size=1280x720:rate=$Fps -t $Seconds -c:v libx264 -preset ultrafast -bf 0 -g $Fps -x264-params 'keyint=${Fps}:min-keyint=${Fps}:scenecut=0:repeat-headers=1:aud=0' -pix_fmt yuv420p -f h264 /work/in.h264"
    if ($LASTEXITCODE -ne 0) { throw "stream generation failed" }

    Write-Host "Building harness (swift container)..." -ForegroundColor Cyan
    podman run --rm -v "${repoRoot}:/workspace:z" -v castlite-harness-build:/build -w /workspace $swift swift build --scratch-path /build --product CastLiteHarness
    if ($LASTEXITCODE -ne 0) { throw "swift build failed" }

    Write-Host "Starting MirrorSession server (swift container)..." -ForegroundColor Cyan
    podman run -d --name $server --network $net -v "${repoRoot}:/workspace:z" -v "${work}:/work:z" -v castlite-harness-build:/build -w /workspace $swift `
        swift run --scratch-path /build CastLiteHarness /work/in.h264 $Fps 8080 ([int]($Seconds + 15)) | Out-Null

    # Wait for the build + feed to start; the fetcher polls the playlist itself.
    $poll = $Seconds + 3
    $minFrames = [int](0.8 * ($Seconds - 1) * $Fps)
    Write-Host "Fetching and decoding (sibling ffmpeg container)..." -ForegroundColor Cyan
    podman run --rm --network $net -v "${work}:/work:z" -v "${repoRoot}\scripts\harness:/harness:ro,z" $alpine sh -c "apk add --no-cache ffmpeg curl >/dev/null && sh /harness/fetch-and-decode.sh http://${server}:8080 $minFrames $poll"
    $exit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = "Continue"
    Write-Host "--- server log ---"; podman logs $server 2>$null | Select-Object -Last 15
    podman rm -f $server 2>$null | Out-Null
    podman network rm $net 2>$null | Out-Null
}
if ($exit -eq 0) { Write-Host "Decode harness PASSED" -ForegroundColor Green } else { Write-Host "Decode harness FAILED" -ForegroundColor Red }
exit $exit