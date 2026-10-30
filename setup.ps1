$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
function New-GiwgPassword {
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}
if (Test-Path '.env') {
    Write-Host '.env already exists; keeping current settings.'
} else {
    $text = "COMPOSE_PROJECT_NAME=giwg`nGIWG_POSTGRES_PASSWORD=$(New-GiwgPassword)`nGIWG_NEO4J_PASSWORD=$(New-GiwgPassword)`nGIWG_POSTGRES_PORT=15432`nGIWG_NEO4J_HTTP_PORT=7474`nGIWG_NEO4J_BOLT_PORT=17687`n"
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot '.env'), $text, (New-Object Text.UTF8Encoding($false)))
    Write-Host 'Created .env with unique local passwords.'
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Install/start Docker Desktop (Linux containers), then run docker compose up -d --build.'
}
docker compose version
if ($LASTEXITCODE -ne 0) { throw 'Docker Compose v2 is required.' }
docker compose config --quiet
if ($LASTEXITCODE -ne 0) { throw 'Compose configuration validation failed.' }
Write-Host 'Ready: docker compose up -d --build'
