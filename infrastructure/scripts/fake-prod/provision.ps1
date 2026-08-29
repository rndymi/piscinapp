. "$PSScriptRoot/common.ps1"

Assert-Command "aws"

Write-Host ""
Write-Host "Provisioning PiscinApp FAKE_PROD..."
Write-Host ""

#
# ECR
#

foreach ($repositoryName in @(
    $script:CoreRepositoryName,
    $script:NginxRepositoryName
)) {

    & aws `
        --endpoint-url $script:FlociEndpoint `
        --region $script:AwsRegion `
        ecr `
        describe-repositories `
        --repository-names $repositoryName `
        *> $null

    if ($LASTEXITCODE -ne 0) {

        Write-Host "Creating ECR repository: $repositoryName"

        Invoke-FakeAws -Arguments @(
            "ecr",
            "create-repository",
            "--repository-name",
            $repositoryName
        ) | Out-Null
    }
    else {

        Write-Host "ECR repository already exists: $repositoryName"
    }
}

#
# RDS PostgreSQL
#

$dbInstanceIdentifier = Get-FakeAwsText -Arguments @(
    "rds",
    "describe-db-instances",
    "--query",
    "DBInstances[?DBInstanceIdentifier=='$($script:DbIdentifier)'].DBInstanceIdentifier | [0]",
    "--output",
    "text"
)

$dbExists = (
    -not [string]::IsNullOrWhiteSpace($dbInstanceIdentifier) -and
    $dbInstanceIdentifier -ne "None"
)

if (-not $dbExists) {

    Write-Host ""
    Write-Host "Creating RDS PostgreSQL instance..."
    Write-Host ""

    Invoke-FakeAws -Arguments @(
        "rds",
        "create-db-instance",
        "--db-instance-identifier",
        $script:DbIdentifier,
        "--db-instance-class",
        "db.t3.micro",
        "--engine",
        "postgres",
        "--engine-version",
        "17.11",
        "--allocated-storage",
        "20",
        "--db-name",
        $script:DbName,
        "--master-username",
        $script:DbUsername,
        "--master-user-password",
        $script:DbPassword
    ) | Out-Null
}
else {

    Write-Host "RDS instance already exists: $dbInstanceIdentifier"
}

Write-Host ""
Write-Host "Waiting for RDS PostgreSQL..."
Write-Host ""

$databaseReady = $false
$lastStatus = $null

for ($attempt = 1; $attempt -le 90; $attempt++) {

    $status = Get-FakeAwsText -Arguments @(
        "rds",
        "describe-db-instances",
        "--query",
        "DBInstances[?DBInstanceIdentifier=='$($script:DbIdentifier)'].DBInstanceStatus | [0]",
        "--output",
        "text"
    )

    if (
        -not [string]::IsNullOrWhiteSpace($status) -and
        $status -ne "None" -and
        $status -ne $lastStatus
    ) {

        Write-Host "RDS status: $status"
        $lastStatus = $status
    }

    if ($status -eq "available") {

        $databaseReady = $true
        break
    }

    Start-Sleep -Seconds 1
}

if (-not $databaseReady) {

    $currentInstances = Get-FakeAwsText -Arguments @(
        "rds",
        "describe-db-instances",
        "--output",
        "json"
    )

    Write-Host ""
    Write-Host "Current RDS state:"
    Write-Host $currentInstances
    Write-Host ""

    throw "RDS PostgreSQL did not become available."
}

#
# ECS
#

$clusterStatus = & aws `
    --endpoint-url $script:FlociEndpoint `
    --region $script:AwsRegion `
    ecs `
    describe-clusters `
    --clusters $script:ClusterName `
    --query "clusters[0].status" `
    --output text `
    2>$null

if (
    $LASTEXITCODE -ne 0 -or
    $clusterStatus -ne "ACTIVE"
) {

    Write-Host "Creating ECS cluster: $script:ClusterName"

    Invoke-FakeAws -Arguments @(
        "ecs",
        "create-cluster",
        "--cluster-name",
        $script:ClusterName
    ) | Out-Null
}
else {

    Write-Host "ECS cluster already exists."
}

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

Write-Host ""
Write-Host "FAKE_PROD infrastructure is ready."
Write-Host "RDS endpoint: ${dbAddress}:${dbPort}"
Write-Host "ECS cluster:  $script:ClusterName"
