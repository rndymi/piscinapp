. "$PSScriptRoot/common.ps1"

Assert-Command "docker"
Assert-Command "aws"

$composeFile = Join-Path `
    $PSScriptRoot `
    "../../floci/docker-compose-floci.yml"

$composeFile = (Resolve-Path $composeFile).Path

Write-Host ""
Write-Host "Starting PiscinApp FAKE_PROD Floci..."
Write-Host ""

docker info *> $null

if ($LASTEXITCODE -ne 0) {

    throw "Docker is not running. Start Docker Desktop and try again."
}

foreach ($requiredPort in @(
    $script:PublicPort,
    8081
)) {

    $portOwners = @(
        docker ps `
            --filter "publish=$requiredPort" `
            --format "{{.Names}}"
    )

    if ($LASTEXITCODE -ne 0) {

        throw "Could not determine whether FAKE_PROD port $requiredPort is available."
    }

    $conflictingContainers = @(
        $portOwners |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                $_ -notmatch '^floci-ecs-.+-(core|nginx)$'
            }
    )

    if ($conflictingContainers.Count -gt 0) {

        $containerNames = $conflictingContainers -join ", "

        throw "FAKE_PROD requires host port $requiredPort, but it is already published by: $containerNames. Stop the conflicting container before running FAKE_PROD."
    }
}

docker compose `
    -f $composeFile `
    up `
    -d `
    --remove-orphans

if ($LASTEXITCODE -ne 0) {

    throw "Floci could not be started."
}

Write-Host ""
Write-Host "Waiting for Floci..."
Write-Host ""

$ready = $false

for ($attempt = 1; $attempt -le 30; $attempt++) {

    & aws `
        --endpoint-url $script:FlociEndpoint `
        --region $script:AwsRegion `
        sts `
        get-caller-identity `
        --output json `
        *> $null

    if ($LASTEXITCODE -eq 0) {

        $ready = $true
        break
    }

    Start-Sleep -Seconds 1
}

if (-not $ready) {

    throw "Floci did not become ready in time."
}

Write-Host "Floci is ready at $script:FlociEndpoint"
