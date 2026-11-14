# Run tests inside Podman container without host dependencies
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
Write-Host "Running Swift tests inside Podman container..." -ForegroundColor Cyan
podman run --rm -v "${repoRoot}:/workspace:z" -w /workspace docker.io/library/swift:5.10 swift test
