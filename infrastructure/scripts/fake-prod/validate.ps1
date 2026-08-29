. "$PSScriptRoot/common.ps1"

Assert-Command "aws"

$ecosystemRoot = (
    Resolve-Path (
        Join-Path $PSScriptRoot "../../.."
    )
).Path

$nginxConfiguration = Join-Path `
    $ecosystemRoot `
    "infrastructure/nginx/nginx.conf"

function Get-HttpStatus {

    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [hashtable] $Headers = @{}
    )

    try {

        $response = Invoke-WebRequest `
            -Uri $Uri `
            -Headers $Headers `
            -Method Get

        return [int] $response.StatusCode
    }
    catch {

        if ($_.Exception.Response) {

            return [int] $_.Exception.Response.StatusCode
        }

        throw
    }
}

Write-Host ""
Write-Host "Validating PiscinApp FAKE_PROD..."
Write-Host ""

#
# ECS task exists
#

$taskArns = Get-FakeAwsText -Arguments @(
    "ecs",
    "list-tasks",
    "--cluster",
    $script:ClusterName,
    "--query",
    "taskArns",
    "--output",
    "text"
)

if (
    [string]::IsNullOrWhiteSpace($taskArns) -or
    $taskArns -eq "None"
) {

    throw "No FAKE_PROD ECS task is running."
}

#
# RDS available
#

$rdsStatus = Get-FakeAwsText -Arguments @(
    "rds",
    "describe-db-instances",
    "--db-instance-identifier",
    $script:DbIdentifier,
    "--query",
    "DBInstances[0].DBInstanceStatus",
    "--output",
    "text"
)

if ($rdsStatus -ne "available") {

    throw "RDS PostgreSQL is not available."
}

#
# ECR repositories exist
#

foreach ($repositoryName in @(
    $script:CoreRepositoryName,
    $script:NginxRepositoryName
)) {

    $repositoryUri = Get-FakeAwsText -Arguments @(
        "ecr",
        "describe-repositories",
        "--repository-names",
        $repositoryName,
        "--query",
        "repositories[0].repositoryUri",
        "--output",
        "text"
    )

    if (
        [string]::IsNullOrWhiteSpace($repositoryUri) -or
        $repositoryUri -eq "None"
    ) {

        throw "ECR repository '$repositoryName' is not available."
    }

    Write-Host "- emulated ECR repositories and image delivery"
}

#
# Task contract
#

$taskDefinitionJson = & aws `
    --endpoint-url $script:FlociEndpoint `
    --region $script:AwsRegion `
    ecs `
    describe-task-definition `
    --task-definition $script:TaskFamily `
    --output json

if ($LASTEXITCODE -ne 0) {

    throw "Could not inspect ECS task definition."
}

$taskDefinition = $taskDefinitionJson |
    ConvertFrom-Json

$coreContainer = `
    $taskDefinition.taskDefinition.containerDefinitions |
    Where-Object {
        $_.name -eq "core"
    }

if (-not $coreContainer) {

    throw "Core container was not found in ECS task definition."
}

$environment = @{}

foreach ($entry in $coreContainer.environment) {

    $environment[$entry.name] = $entry.value
}

if ($environment["SPRING_PROFILES_ACTIVE"] -ne "prod") {

    throw "Core is not running with Spring prod profile."
}

if (-not $environment.ContainsKey("DATABASE_URL")) {

    throw "DATABASE_URL is not configured."
}

#
# Nginx Authorization propagation contract
#

$authorizationHeaderConfiguration = Select-String `
    -Path $nginxConfiguration `
    -SimpleMatch `
    'proxy_set_header Authorization $http_authorization;'

if (-not $authorizationHeaderConfiguration) {

    throw "Nginx does not propagate the Authorization header."
}

#
# Wait for public health through Nginx
#

Write-Host "Waiting for Core health through Nginx..."

$healthReady = $false
$lastHealthError = $null

for ($attempt = 1; $attempt -le 120; $attempt++) {

    try {

        $health = Invoke-RestMethod `
            -Uri "http://localhost:8080/actuator/health" `
            -Method Get `
            -ErrorAction Stop

        if ($health.status -eq "UP") {

            $healthReady = $true

            Write-Host "Core health through Nginx: UP"

            break
        }

        $lastHealthError = `
            "Unexpected health status: $($health.status)"
    }
    catch {

        $lastHealthError = $_.Exception.Message
    }

    Start-Sleep -Seconds 1
}

if (-not $healthReady) {

    if ($lastHealthError) {

        Write-Host ""
        Write-Host "Last health error:"
        Write-Host $lastHealthError
    }

    throw "Core did not become healthy through Nginx."
}

#
# PROD restrictions
#

$apiDocsStatus = Get-HttpStatus `
    -Uri "http://localhost:8080/v3/api-docs"

if ($apiDocsStatus -notin @(401, 404)) {

    throw "OpenAPI must not be publicly exposed in FAKE_PROD prod profile. Status: $apiDocsStatus"
}

Write-Host "OpenAPI public exposure blocked: $apiDocsStatus"

$swaggerStatus = Get-HttpStatus `
    -Uri "http://localhost:8080/swagger-ui/index.html"

if ($swaggerStatus -notin @(401, 404)) {

    throw "Swagger UI must not be publicly exposed in FAKE_PROD prod profile. Status: $swaggerStatus"
}

Write-Host "Swagger UI public exposure blocked: $swaggerStatus"

$internalActuatorStatus = Get-HttpStatus `
    -Uri "http://localhost:8080/actuator/env"

if ($internalActuatorStatus -ne 404) {

    throw "Internal Actuator endpoint is exposed. Status: $internalActuatorStatus"
}

#
# Protected request through Nginx
#

$protectedStatus = Get-HttpStatus `
    -Uri "http://localhost:8080/" `
    -Headers @{
        Authorization = "Bearer invalid-fake-prod-token"
    }

if ($protectedStatus -ne 401) {

    throw "Protected Core request should reject an invalid bearer token with 401. Status: $protectedStatus"
}

Write-Host ""
Write-Host "FAKE_PROD validation passed."
Write-Host ""
Write-Host "Validated:"
Write-Host "- emulated ECR images"
Write-Host "- emulated ECS runtime"
Write-Host "- emulated RDS PostgreSQL"
Write-Host "- Core Spring prod profile"
Write-Host "- Nginx -> Core routing"
Write-Host "- health through Nginx"
Write-Host "- Authorization forwarding configuration"
Write-Host "- Swagger/OpenAPI disabled"
Write-Host "- internal Actuator endpoints blocked"
