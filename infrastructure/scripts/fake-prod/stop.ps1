. "$PSScriptRoot/common.ps1"

Assert-Command "docker"

$composeFile = Join-Path `
    $PSScriptRoot `
    "../../floci/docker-compose-floci.yml"

$composeFile = (Resolve-Path $composeFile).Path

Write-Host ""
Write-Host "Stopping PiscinApp FAKE_PROD..."
Write-Host ""

if (Get-Command "aws" -ErrorAction SilentlyContinue) {

    & aws `
        --endpoint-url $script:FlociEndpoint `
        --region $script:AwsRegion `
        sts `
        get-caller-identity `
        *> $null

    if ($LASTEXITCODE -eq 0) {

        $taskArns = & aws `
            --endpoint-url $script:FlociEndpoint `
            --region $script:AwsRegion `
            ecs `
            list-tasks `
            --cluster $script:ClusterName `
            --query "taskArns" `
            --output text `
            2>$null

        if ($LASTEXITCODE -eq 0 -and $taskArns) {

            foreach ($taskArn in ($taskArns -split "\s+")) {

                if (-not [string]::IsNullOrWhiteSpace($taskArn)) {

                    & aws `
                        --endpoint-url $script:FlociEndpoint `
                        --region $script:AwsRegion `
                        ecs `
                        stop-task `
                        --cluster $script:ClusterName `
                        --task $taskArn `
                        *> $null
                }
            }
        }

        & aws `
            --endpoint-url $script:FlociEndpoint `
            --region $script:AwsRegion `
            rds `
            delete-db-instance `
            --db-instance-identifier $script:DbIdentifier `
            --skip-final-snapshot `
            *> $null

        foreach ($repositoryName in @(
            $script:CoreRepositoryName,
            $script:NginxRepositoryName
        )) {

            & aws `
                --endpoint-url $script:FlociEndpoint `
                --region $script:AwsRegion `
                ecr `
                delete-repository `
                --repository-name $repositoryName `
                --force `
                *> $null
        }

        & aws `
            --endpoint-url $script:FlociEndpoint `
            --region $script:AwsRegion `
            ecs `
            delete-cluster `
            --cluster $script:ClusterName `
            *> $null
    }
}

Start-Sleep -Seconds 2

$networkJson = docker network inspect $script:NetworkName 2>$null

if ($LASTEXITCODE -eq 0) {

    $network = $networkJson | ConvertFrom-Json

    $containers = `
        $network[0].Containers.PSObject.Properties |
        ForEach-Object {
            $_.Value.Name
        }

    foreach ($containerName in $containers) {

        if (
            $containerName -and
            $containerName -ne "piscinapp-floci"
        ) {

            docker rm `
                -f `
                $containerName `
                *> $null
        }
    }
}

docker compose `
    -f $composeFile `
    down `
    --remove-orphans

Write-Host ""
Write-Host "PiscinApp FAKE_PROD stopped."
