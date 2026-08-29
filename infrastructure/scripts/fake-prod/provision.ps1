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

& aws `
    --endpoint-url $script:FlociEndpoint `
    --region $script:AwsRegion `
    rds `
    describe-db-instances `
    --db-instance-identifier $script:DbIdentifier `
    *> $null

if ($LASTEXITCODE -ne 0) {

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

    Write-Host "RDS instance already exists."
}

Write-Host ""
Write-Host "Waiting for RDS PostgreSQL..."
Write-Host ""

$databaseReady = $false

for ($attempt = 1; $attempt -le 90; $attempt++) {

    $status = & aws `
        --endpoint-url $script:FlociEndpoint `
        --region $script:AwsRegion `
        rds `
        describe-db-instances `
        --db-instance-identifier $script:DbIdentifier `
        --query "DBInstances[0].DBInstanceStatus" `
        --output text `
        2>$null

    if ($LASTEXITCODE -eq 0 -and $status -eq "available") {

        $databaseReady = $true
        break
    }

    Start-Sleep -Seconds 1
}

if (-not $databaseReady) {

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
