<#
.SYNOPSIS
  Build the backend + frontend images for linux/amd64 on THIS machine and export
  them as .tar files to carry into the air-gapped OpenShift environment.

.DESCRIPTION
  Run from the repository root (the folder containing docker-compose.yml):
      .\openshift\build-images.ps1
  Optional:
      .\openshift\build-images.ps1 -Tag 1.0 -OutDir openshift\images

  Requires Docker Desktop (verified with 29.x + buildx). Produces:
      <OutDir>\onboarding-backend-<Tag>.tar
      <OutDir>\onboarding-frontend-<Tag>.tar

  These tars contain everything (Node 24 runtime, all npm deps, compiled
  better-sqlite3, generated Prisma client, the built Vite bundle, nginx) — no
  npm install or internet access is needed on the air-gapped side.
#>
param(
  [string]$Tag = "1.0",
  [string]$OutDir = "openshift\images"
)

$ErrorActionPreference = "Stop"

# Resolve repo root as the parent of this script's folder, and run from there so
# the Docker build context (".") matches docker-compose.
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if (-not (Test-Path "docker-compose.yml")) {
  throw "Run this from the repository root (docker-compose.yml not found in $repoRoot)."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$backendImage  = "onboarding-backend:$Tag"
$frontendImage = "onboarding-frontend:$Tag"
$backendTar    = Join-Path $OutDir "onboarding-backend-$Tag.tar"
$frontendTar   = Join-Path $OutDir "onboarding-frontend-$Tag.tar"

# --provenance=false keeps each image a single-platform artifact (no attestation
# manifest list), so docker load / skopeo docker-archive on the air-gapped side
# import it cleanly.
Write-Host "==> Building $backendImage (linux/amd64)"
docker build --platform linux/amd64 --provenance=false -f backend/Dockerfile -t $backendImage .
if ($LASTEXITCODE -ne 0) { throw "Backend build failed." }

Write-Host "==> Building $frontendImage (linux/amd64)"
docker build --platform linux/amd64 --provenance=false -f frontend/Dockerfile -t $frontendImage .
if ($LASTEXITCODE -ne 0) { throw "Frontend build failed." }

Write-Host "==> Saving $backendTar"
docker save $backendImage -o $backendTar
if ($LASTEXITCODE -ne 0) { throw "docker save (backend) failed." }

Write-Host "==> Saving $frontendTar"
docker save $frontendImage -o $frontendTar
if ($LASTEXITCODE -ne 0) { throw "docker save (frontend) failed." }

Write-Host ""
Write-Host "Done. Copy these into the air-gapped environment:"
Get-Item $backendTar, $frontendTar | Select-Object Name, @{N="SizeMB";E={[math]::Round($_.Length/1MB,1)}}
