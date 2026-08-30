param(

    [string] $CoreRepositoryPath = "",

    [string] $DeploymentTag = ""
)

. "$PSScriptRoot/common.ps1"

Assert-Command "aws"
Assert-Command "docker"
Assert-Command "git"
Assert-Command "keytool"

$ecosystemRoot = (
    Resolve-Path (
        Join-Path $PSScriptRoot "../../.."
    )
).Path

if ([string]::IsNullOrWhiteSpace($CoreRepositoryPath)) {

    $workspaceRoot = Split-Path `
        $ecosystemRoot `
        -Parent

    $CoreRepositoryPath = Join-Path `
        $workspaceRoot `
        "piscinapp-core"
}

if (-not (Test-Path $CoreRepositoryPath)) {

    throw "Core repository was not found at: $CoreRepositoryPath"
}

$CoreRepositoryPath = (
    Resolve-Path $CoreRepositoryPath
).Path

$nginxPath = Join-Path `
    $ecosystemRoot `
    "infrastructure/nginx"

$coreCommit = (
    & git `
        -C $CoreRepositoryPath `
        rev-parse `
        --short=12 `
        HEAD
).Trim()

if ($LASTEXITCODE -ne 0) {

    throw "Could not resolve the Core Git revision."
}

if ([string]::IsNullOrWhiteSpace($DeploymentTag)) {

    $DeploymentTag = "core-$coreCommit"
}

Write-Host ""
Write-Host "Deploying Core revision: $coreCommit"
Write-Host "Deployment tag:         $DeploymentTag"
Write-Host ""

#
# Resolve ECR repositories
#

$coreRepositoryUri = Get-FakeAwsText -Arguments @(
    "ecr",
    "describe-repositories",
    "--repository-names",
    $script:CoreRepositoryName,
    "--query",
    "repositories[0].repositoryUri",
    "--output",
    "text"
)

$nginxRepositoryUri = Get-FakeAwsText -Arguments @(
    "ecr",
    "describe-repositories",
    "--repository-names",
    $script:NginxRepositoryName,
    "--query",
    "repositories[0].repositoryUri",
    "--output",
    "text"
)

$registryHost = (
    $coreRepositoryUri -split "/"
)[0]

#
# Authenticate Docker against emulated ECR
#

$loginPassword = Get-FakeAwsText -Arguments @(
    "ecr",
    "get-login-password"
)

$loginPassword |
    docker login `
        --username AWS `
        --password-stdin `
        $registryHost `
        *> $null

if ($LASTEXITCODE -ne 0) {

    throw "Docker could not authenticate against Floci ECR."
}

#
# Core image
#

Write-Host "Building Core image..."

docker build `
    -t "piscinapp-core:$DeploymentTag" `
    $CoreRepositoryPath

if ($LASTEXITCODE -ne 0) {

    throw "Core Docker image build failed."
}

$coreImage = "${coreRepositoryUri}:$DeploymentTag"

docker tag `
    "piscinapp-core:$DeploymentTag" `
    $coreImage

docker push $coreImage

if ($LASTEXITCODE -ne 0) {

    throw "Core image push to emulated ECR failed."
}

#
# Nginx image
#

Write-Host ""
Write-Host "Building Nginx image..."

docker build `
    -t "piscinapp-nginx:$DeploymentTag" `
    $nginxPath

if ($LASTEXITCODE -ne 0) {

    throw "Nginx Docker image build failed."
}

$nginxImage = "${nginxRepositoryUri}:$DeploymentTag"

docker tag `
    "piscinapp-nginx:$DeploymentTag" `
    $nginxImage

docker push $nginxImage

if ($LASTEXITCODE -ne 0) {

    throw "Nginx image push to emulated ECR failed."
}

#
# Stop an older task when redeploying locally
#

$previousTasks = Get-FakeAwsText -Arguments @(
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
    $previousTasks -and
    $previousTasks -ne "None"
) {

    foreach ($taskArn in ($previousTasks -split "\s+")) {

        if (-not [string]::IsNullOrWhiteSpace($taskArn)) {

            Invoke-FakeAws -Arguments @(
                "ecs",
                "stop-task",
                "--cluster",
                $script:ClusterName,
                "--task",
                $taskArn
            ) | Out-Null
        }
    }

    Start-Sleep -Seconds 2
}

#
# Resolve RDS endpoint
#

$dbAddress = Get-FakeAwsText -Arguments @(
    "rds",
    "describe-db-instances",
    "--db-instance-identifier",
    $script:DbIdentifier,
    "--query",
    "DBInstances[0].Endpoint.Address",
    "--output",
    "text"
)

$dbPort = Get-FakeAwsText -Arguments @(
    "rds",
    "describe-db-instances",
    "--db-instance-identifier",
    $script:DbIdentifier,
    "--query",
    "DBInstances[0].Endpoint.Port",
    "--output",
    "text"
)

$databaseUrl = `
    "jdbc:postgresql://${dbAddress}:${dbPort}/$($script:DbName)"

#
# Generate ephemeral FAKE_PROD JWT material
#

$runtimeDirectory = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    "piscinapp-fake-prod"

New-Item `
    -ItemType Directory `
    -Path $runtimeDirectory `
    -Force `
    *> $null

$keyStorePath = Join-Path `
    $runtimeDirectory `
    "piscinapp-core-fake-prod.p12"

$taskDefinitionPath = Join-Path `
    $runtimeDirectory `
    "task-definition.json"

Remove-Item `
    $keyStorePath `
    -Force `
    -ErrorAction SilentlyContinue

$jwtPassword = "piscinapp-fake-prod"
$jwtAlias = "piscinapp-core-fake-prod"
$jwtKeyId = "piscinapp-core-fake-prod"

& keytool `
    -genkeypair `
    -alias $jwtAlias `
    -keyalg RSA `
    -keysize 2048 `
    -validity 30 `
    -storetype PKCS12 `
    -keystore $keyStorePath `
    -storepass $jwtPassword `
    -keypass $jwtPassword `
    -dname "CN=PiscinApp FAKE_PROD, OU=Development, O=PiscinApp, C=ES" `
    -noprompt

if ($LASTEXITCODE -ne 0) {

    throw "Could not generate the temporary FAKE_PROD JWT keystore."
}

$jwtKeyStoreBase64 = [Convert]::ToBase64String(
    [IO.File]::ReadAllBytes($keyStorePath)
)

#
# ECS task definition
#

$taskDefinition = @{

    family = $script:TaskFamily

    networkMode = "bridge"

    containerDefinitions = @(

        @{

            name = "core"

            image = $coreImage

            essential = $true

            environment = @(

                @{
                    name  = "SPRING_PROFILES_ACTIVE"
                    value = "prod"
                },

                @{
                    name  = "SERVER_PORT"
                    value = "8081"
                },

                @{
                    name  = "DATABASE_URL"
                    value = $databaseUrl
                },

                @{
                    name  = "DATABASE_USERNAME"
                    value = $script:DbUsername
                },

                @{
                    name  = "DATABASE_PASSWORD"
                    value = $script:DbPassword
                },

                @{
                    name  = "PISCINAPP_BOOTSTRAP_ADMIN_USERNAME"
                    value = $script:BootstrapAdminUsername
                },

                @{
                    name  = "PISCINAPP_BOOTSTRAP_ADMIN_PASSWORD"
                    value = $script:BootstrapAdminPassword
                },

                @{
                    name  = "PISCINAPP_SECURITY_ISSUER"
                    value = "http://localhost:8080"
                },

                @{
                    name  = "JWT_KEYSTORE_BASE64"
                    value = $jwtKeyStoreBase64
                },

                @{
                    name  = "JWT_KEYSTORE_PASSWORD"
                    value = $jwtPassword
                },

                @{
                    name  = "JWT_KEY_PASSWORD"
                    value = $jwtPassword
                },

                @{
                    name  = "JWT_KEY_ALIAS"
                    value = $jwtAlias
                },

                @{
                    name  = "JWT_KEY_ID"
                    value = $jwtKeyId
                }
            )

            portMappings = @(

                @{
                    containerPort = 8081
                    hostPort      = 8081
                    protocol      = "tcp"
                }
            )
        },

        @{

            name = "nginx"

            image = $nginxImage

            essential = $true

            portMappings = @(

                @{
                    containerPort = 8080
                    hostPort      = 8080
                    protocol      = "tcp"
                }
            )
        }
    )
}

try {

    $taskDefinition |
        ConvertTo-Json `
            -Depth 20 |
        Set-Content `
            -Path $taskDefinitionPath `
            -Encoding ascii

    $taskDefinitionArn = Get-FakeAwsText -Arguments @(
        "ecs",
        "register-task-definition",
        "--cli-input-json",
        "file://$taskDefinitionPath",
        "--query",
        "taskDefinition.taskDefinitionArn",
        "--output",
        "text"
    )

    Write-Host ""
    Write-Host "Registered ECS task:"
    Write-Host $taskDefinitionArn
    Write-Host ""

    $taskArn = Get-FakeAwsText -Arguments @(
        "ecs",
        "run-task",
        "--cluster",
        $script:ClusterName,
        "--task-definition",
        $taskDefinitionArn,
        "--count",
        "1",
        "--query",
        "tasks[0].taskArn",
        "--output",
        "text"
    )

    if (
        [string]::IsNullOrWhiteSpace($taskArn) -or
        $taskArn -eq "None"
    ) {

        throw "Floci ECS did not start the PiscinApp task."
    }

    Write-Host "FAKE_PROD ECS task started:"
    Write-Host $taskArn
}
finally {

    Remove-Item `
        $keyStorePath `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        $taskDefinitionPath `
        -Force `
        -ErrorAction SilentlyContinue
}
