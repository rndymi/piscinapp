Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:FlociEndpoint = "http://localhost:4566"
$script:AwsRegion = "us-east-1"

$script:NetworkName = "piscinapp-fake-prod"

$script:CoreRepositoryName = "piscinapp-core"
$script:NginxRepositoryName = "piscinapp-nginx"

$script:ClusterName = "piscinapp-fake-prod"
$script:TaskFamily = "piscinapp-fake-prod"

$script:DbIdentifier = "piscinapp-fake-prod"
$script:DbName = "piscinapp"
$script:DbUsername = "piscinapp"
$script:DbPassword = "piscinapp-fake-prod"

$script:BootstrapAdminUsername = "fake.prod.admin"
$script:BootstrapAdminPassword = "fake-prod-admin-password"

$script:PublicPort = 9080
$script:PublicBaseUrl = "http://localhost:$($script:PublicPort)"
$script:SecurityIssuer = $script:PublicBaseUrl

$script:ValidationClientId = "piscinapp-validation"
$script:ValidationRedirectUri = "http://127.0.0.1:18080/callback"

$script:ValidationUserUsername = "fake.prod.user"
$script:ValidationUserPassword = "fake-prod-user-password"

# Credenciales exclusivamente ficticias para el emulador local.
$env:AWS_ACCESS_KEY_ID = "test"
$env:AWS_SECRET_ACCESS_KEY = "test"
$env:AWS_DEFAULT_REGION = $script:AwsRegion
$env:AWS_EC2_METADATA_DISABLED = "true"

function Assert-Command {

    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {

        throw "Required command '$Name' is not available."
    }
}

function Invoke-FakeAws {

    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    & aws `
        --endpoint-url $script:FlociEndpoint `
        --region $script:AwsRegion `
        @Arguments

    if ($LASTEXITCODE -ne 0) {

        throw "AWS CLI command failed: aws $($Arguments -join ' ')"
    }
}

function Get-FakeAwsText {

    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $output = & aws `
        --endpoint-url $script:FlociEndpoint `
        --region $script:AwsRegion `
        @Arguments

    if ($LASTEXITCODE -ne 0) {

        throw "AWS CLI command failed: aws $($Arguments -join ' ')"
    }

    return ($output | Out-String).Trim()
}
