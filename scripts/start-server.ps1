# Run Cast-Lite live streaming server inside Podman and map port 8080 to host
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
Write-Host "Starting Cast-Lite streaming server in Podman on port 8080..." -ForegroundColor Cyan
Write-Host "Open http://localhost:8080/view in Chrome or Edge when ready.`n" -ForegroundColor Green
podman run -it --rm -p 8080:8080 -v "${repoRoot}:/workspace:z" -w /workspace docker.io/library/swift:5.10 swift run CastLiteServer
