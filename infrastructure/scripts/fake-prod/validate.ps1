. "$PSScriptRoot/common.ps1"

Assert-Command "aws"

if ($PSVersionTable.PSVersion.Major -lt 7) {

    throw "FAKE_PROD validation requires PowerShell 7 or newer."
}

$ecosystemRoot = (
    Resolve-Path (
        Join-Path $PSScriptRoot "../../.."
    )
).Path

$nginxConfiguration = Join-Path `
    $ecosystemRoot `
    "infrastructure/nginx/nginx.conf"

function Assert-Status {

    param(
        [Parameter(Mandatory = $true)]
        $Response,

        [Parameter(Mandatory = $true)]
        [int] $ExpectedStatus,

        [Parameter(Mandatory = $true)]
        [string] $Description
    )

    $actualStatus = [int] $Response.StatusCode

    if ($actualStatus -ne $ExpectedStatus) {

        throw "$Description. Expected HTTP $ExpectedStatus but received $actualStatus."
    }
}

function Get-JsonContent {

    param(
        [Parameter(Mandatory = $true)]
        $Response
    )

    if ([string]::IsNullOrWhiteSpace($Response.Content)) {

        return $null
    }

    return $Response.Content |
        ConvertFrom-Json
}

function Invoke-FakeProdRequest {

    param(
        [Parameter(Mandatory = $true)]
        [string] $Method,

        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string] $AccessToken = "",

        $Body = $null
    )

    $headers = @{}

    if (-not [string]::IsNullOrWhiteSpace($AccessToken)) {

        $headers["Authorization"] = "Bearer $AccessToken"
    }

    $parameters = @{

        Uri = "$($script:PublicBaseUrl)$Path"

        Method = $Method

        Headers = $headers

        SkipHttpErrorCheck = $true

        ErrorAction = "Stop"
    }

    if ($null -ne $Body) {

        $parameters["ContentType"] = "application/json"

        $parameters["Body"] = (
            $Body |
                ConvertTo-Json -Depth 10 -Compress
        )
    }

    return Invoke-WebRequest @parameters
}

function ConvertTo-Base64Url {

    param(
        [Parameter(Mandatory = $true)]
        [byte[]] $Bytes
    )

    return [Convert]::ToBase64String($Bytes).
        TrimEnd("=").
        Replace("+", "-").
        Replace("/", "_")
}

function New-RandomBase64Url {

    param(
        [int] $ByteLength = 32
    )

    $bytes = [byte[]]::new($ByteLength)

    [Security.Cryptography.RandomNumberGenerator]::Fill(
        $bytes
    )

    return ConvertTo-Base64Url $bytes
}

function New-Pkce {

    $verifierBytes = [byte[]]::new(64)

    [Security.Cryptography.RandomNumberGenerator]::Fill(
        $verifierBytes
    )

    $verifier = ConvertTo-Base64Url $verifierBytes

    $challengeBytes = (
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::ASCII.GetBytes(
                $verifier
            )
        )
    )

    return @{
        Verifier = $verifier
        Challenge = ConvertTo-Base64Url $challengeBytes
    }
}

function Get-QueryParameter {

    param(
        [Parameter(Mandatory = $true)]
        [Uri] $Uri,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    foreach (
        $part in $Uri.Query.TrimStart("?") -split "&"
    ) {

        if ([string]::IsNullOrWhiteSpace($part)) {

            continue
        }

        $pair = $part -split "=", 2

        $key = [Uri]::UnescapeDataString(
            $pair[0].Replace("+", " ")
        )

        if ($key -ne $Name) {

            continue
        }

        if ($pair.Count -eq 1) {

            return ""
        }

        return [Uri]::UnescapeDataString(
            $pair[1].Replace("+", " ")
        )
    }

    return $null
}

function Resolve-PublicUri {

    param(
        [Parameter(Mandatory = $true)]
        [string] $Location
    )

    $baseUri = [Uri](
        "$($script:PublicBaseUrl)/"
    )

    return [Uri]::new(
        $baseUri,
        $Location
    ).AbsoluteUri
}

function Get-RedirectLocation {

    param(
        [Parameter(Mandatory = $true)]
        $Response,

        [Parameter(Mandatory = $true)]
        [string] $Description
    )

    $status = [int] $Response.StatusCode

    if ($status -notin @(302, 303)) {

        throw "$Description did not return an OAuth2 redirect. Status: $status"
    }

    $location = [string] $Response.Headers["Location"]

    if ([string]::IsNullOrWhiteSpace($location)) {

        throw "$Description did not return a Location header."
    }

    return $location
}

function Get-CsrfToken {

    param(
        [Parameter(Mandatory = $true)]
        [string] $Html
    )

    $match = [regex]::Match(
        $Html,
        'name="_csrf"[^>]*value="([^"]+)"',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $match.Success) {

        throw "Spring Security login page did not expose the expected CSRF token."
    }

    return [Net.WebUtility]::HtmlDecode(
        $match.Groups[1].Value
    )
}

function Get-OAuth2AccessToken {

    param(
        [Parameter(Mandatory = $true)]
        [string] $Username,

        [Parameter(Mandatory = $true)]
        [string] $Password,

        [switch] $ExpectAuthenticationFailure
    )

    $pkce = New-Pkce
    $state = New-RandomBase64Url

    $authorizationUri =
        "$($script:PublicBaseUrl)/oauth2/authorize" +
        "?response_type=code" +
        "&client_id=$([Uri]::EscapeDataString($script:ValidationClientId))" +
        "&redirect_uri=$([Uri]::EscapeDataString($script:ValidationRedirectUri))" +
        "&scope=$([Uri]::EscapeDataString('openid profile'))" +
        "&state=$([Uri]::EscapeDataString($state))" +
        "&code_challenge=$([Uri]::EscapeDataString($pkce.Challenge))" +
        "&code_challenge_method=S256"

    $session = New-Object `
        Microsoft.PowerShell.Commands.WebRequestSession

    #
    # Start Authorization Code flow through Nginx.
    # Spring redirects the browser-style request to /login.
    #

    $loginPage = Invoke-WebRequest `
        -Uri $authorizationUri `
        -Method Get `
        -WebSession $session `
        -Headers @{
            Accept = "text/html"
        } `
        -MaximumRedirection 10 `
        -ErrorAction Stop

    if ([int] $loginPage.StatusCode -ne 200) {

        throw "OAuth2 authorization did not reach the login page."
    }

    $csrfToken = Get-CsrfToken `
        -Html $loginPage.Content

    #
    # Perform real Spring Security form login.
    #

    $loginResponse = Invoke-WebRequest `
        -Uri "$($script:PublicBaseUrl)/login" `
        -Method Post `
        -WebSession $session `
        -ContentType "application/x-www-form-urlencoded" `
        -Body @{
            username = $Username
            password = $Password
            _csrf = $csrfToken
        } `
        -MaximumRedirection 0 `
        -SkipHttpErrorCheck `
        -ErrorAction Stop

    $loginLocation = Get-RedirectLocation `
        -Response $loginResponse `
        -Description "Spring Security login"

    if ($loginLocation -match "/login\?error") {

        if ($ExpectAuthenticationFailure) {

            return $null
        }

        throw "OAuth2 credentials were rejected."
    }

    if ($ExpectAuthenticationFailure) {

        throw "Disabled user unexpectedly passed authentication."
    }

    #
    # Resume the saved OAuth2 authorization request.
    #

    $resumeAuthorizationUri = Resolve-PublicUri `
        -Location $loginLocation

    $authorizationResponse = Invoke-WebRequest `
        -Uri $resumeAuthorizationUri `
        -Method Get `
        -WebSession $session `
        -MaximumRedirection 0 `
        -SkipHttpErrorCheck `
        -ErrorAction Stop

    $callbackLocation = Get-RedirectLocation `
        -Response $authorizationResponse `
        -Description "OAuth2 authorization"

    $callbackUri = [Uri] $callbackLocation

    $callbackBase = $callbackUri.GetLeftPart(
        [UriPartial]::Path
    )

    if ($callbackBase -ne $script:ValidationRedirectUri) {

        throw "Authorization Server returned an unexpected OAuth2 callback URI."
    }

    $returnedState = Get-QueryParameter `
        -Uri $callbackUri `
        -Name "state"

    if ($returnedState -ne $state) {

        throw "OAuth2 state validation failed."
    }

    $authorizationCode = Get-QueryParameter `
        -Uri $callbackUri `
        -Name "code"

    if ([string]::IsNullOrWhiteSpace($authorizationCode)) {

        throw "Authorization Server did not return an authorization code."
    }

    #
    # Exchange the authorization code through Nginx.
    # No client secret is supplied.
    #

    $tokenResponse = Invoke-WebRequest `
        -Uri "$($script:PublicBaseUrl)/oauth2/token" `
        -Method Post `
        -ContentType "application/x-www-form-urlencoded" `
        -Body @{
            grant_type = "authorization_code"
            client_id = $script:ValidationClientId
            code = $authorizationCode
            redirect_uri = $script:ValidationRedirectUri
            code_verifier = $pkce.Verifier
        } `
        -SkipHttpErrorCheck `
        -ErrorAction Stop

    Assert-Status `
        -Response $tokenResponse `
        -ExpectedStatus 200 `
        -Description "OAuth2 token exchange failed"

    $tokenPayload = Get-JsonContent $tokenResponse

    if (
        $null -eq $tokenPayload -or
        [string]::IsNullOrWhiteSpace(
            $tokenPayload.access_token
        )
    ) {

        throw "Authorization Server did not return an access token."
    }

    return [string] $tokenPayload.access_token
}

function Assert-NoCredentialFields {

    param(
        [Parameter(Mandatory = $true)]
        $Account
    )

    $propertyNames = @(
        $Account.PSObject.Properties.Name
    )

    foreach ($forbiddenName in @(
        "password",
        "passwordHash",
        "encodedPassword",
        "credentials"
    )) {

        if ($propertyNames -contains $forbiddenName) {

            throw "Identity API exposed forbidden credential material."
        }
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
}

Write-Host "- emulated ECR repositories and image delivery"

#
# Core ECS runtime contract
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

foreach ($requiredEnvironmentName in @(

    "DATABASE_URL",
    "DATABASE_USERNAME",
    "DATABASE_PASSWORD",

    "PISCINAPP_BOOTSTRAP_ADMIN_USERNAME",
    "PISCINAPP_BOOTSTRAP_ADMIN_PASSWORD",

    "PISCINAPP_SECURITY_ISSUER",

    "PISCINAPP_VALIDATION_CLIENT_ENABLED",
    "PISCINAPP_VALIDATION_CLIENT_ID",
    "PISCINAPP_VALIDATION_CLIENT_REDIRECT_URI",

    "JWT_KEYSTORE_BASE64",
    "JWT_KEYSTORE_PASSWORD",
    "JWT_KEY_PASSWORD",
    "JWT_KEY_ALIAS",
    "JWT_KEY_ID"
)) {

    if (-not $environment.ContainsKey($requiredEnvironmentName)) {

        throw "Core runtime variable '$requiredEnvironmentName' is not configured."
    }
}

if (
    $environment["PISCINAPP_SECURITY_ISSUER"] -ne
    $script:SecurityIssuer
) {

    throw "Core issuer does not match the FAKE_PROD public boundary."
}

if (
    $environment["PISCINAPP_VALIDATION_CLIENT_ENABLED"] -ne
    "true"
) {

    throw "FAKE_PROD OAuth2 validation client is not enabled."
}

if (
    $environment["PISCINAPP_VALIDATION_CLIENT_ID"] -ne
    $script:ValidationClientId
) {

    throw "FAKE_PROD OAuth2 validation client ID is inconsistent."
}

if (
    $environment["PISCINAPP_VALIDATION_CLIENT_REDIRECT_URI"] -ne
    $script:ValidationRedirectUri
) {

    throw "FAKE_PROD OAuth2 redirect URI is inconsistent."
}

Write-Host "- Core prod runtime contract"

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
            -Uri "$($script:PublicBaseUrl)/actuator/health" `
            -Method Get `
            -ErrorAction Stop

        if ($health.status -eq "UP") {

            $healthReady = $true

            Write-Host "Core health through Nginx: UP"

            break
        }

        $lastHealthError =
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

$apiDocsResponse = Invoke-FakeProdRequest `
    -Method Get `
    -Path "/v3/api-docs"

if (
    [int] $apiDocsResponse.StatusCode -notin @(401, 404)
) {

    throw "OpenAPI is publicly exposed under prod profile."
}

$swaggerResponse = Invoke-FakeProdRequest `
    -Method Get `
    -Path "/swagger-ui/index.html"

if (
    [int] $swaggerResponse.StatusCode -notin @(401, 404)
) {

    throw "Swagger UI is publicly exposed under prod profile."
}

$internalActuatorResponse = Invoke-FakeProdRequest `
    -Method Get `
    -Path "/actuator/env"

Assert-Status `
    -Response $internalActuatorResponse `
    -ExpectedStatus 404 `
    -Description "Internal Actuator endpoint is exposed"

Write-Host "- production documentation and Actuator restrictions"

#
# OIDC discovery through Nginx
#

$discoveryResponse = Invoke-FakeProdRequest `
    -Method Get `
    -Path "/.well-known/openid-configuration"

Assert-Status `
    -Response $discoveryResponse `
    -ExpectedStatus 200 `
    -Description "OIDC discovery failed"

$discovery = Get-JsonContent $discoveryResponse

if ($discovery.issuer -ne $script:SecurityIssuer) {

    throw "OIDC discovery returned an unexpected issuer."
}

if (
    $discovery.authorization_endpoint -ne
    "$($script:PublicBaseUrl)/oauth2/authorize"
) {

    throw "OIDC discovery returned an unexpected authorization endpoint."
}

if (
    $discovery.token_endpoint -ne
    "$($script:PublicBaseUrl)/oauth2/token"
) {

    throw "OIDC discovery returned an unexpected token endpoint."
}

$jwksResponse = Invoke-FakeProdRequest `
    -Method Get `
    -Path "/oauth2/jwks"

Assert-Status `
    -Response $jwksResponse `
    -ExpectedStatus 200 `
    -Description "JWKS endpoint failed"

$jwks = Get-JsonContent $jwksResponse

if (
    $null -eq $jwks.keys -or
    @($jwks.keys).Count -eq 0
) {

    throw "JWKS endpoint returned no verification keys."
}

foreach ($jwk in @($jwks.keys)) {

    $jwkProperties = @(
        $jwk.PSObject.Properties.Name
    )

    foreach ($privateProperty in @(
        "d",
        "p",
        "q",
        "dp",
        "dq",
        "qi",
        "oth"
    )) {

        if ($jwkProperties -contains $privateProperty) {

            throw "JWKS endpoint exposed private signing material."
        }
    }
}

Write-Host "- OIDC discovery and public JWKS"

#
# Unauthenticated application API
#

$unauthenticatedResponse = Invoke-FakeProdRequest `
    -Method Get `
    -Path "/api/v1/me"

Assert-Status `
    -Response $unauthenticatedResponse `
    -ExpectedStatus 401 `
    -Description "Unauthenticated Identity API request was not rejected"

$unauthenticatedProblem = Get-JsonContent `
    $unauthenticatedResponse

if (
    $unauthenticatedProblem.code -ne
    "AUTHENTICATION_REQUIRED"
) {

    throw "Unauthenticated API error contract is incorrect."
}

#
# Invalid Bearer against a real functional endpoint
#

$invalidBearerResponse = Invoke-FakeProdRequest `
    -Method Get `
    -Path "/api/v1/me" `
    -AccessToken "invalid-fake-prod-token"

Assert-Status `
    -Response $invalidBearerResponse `
    -ExpectedStatus 401 `
    -Description "Invalid Bearer token was not rejected"

Write-Host "- unauthenticated and invalid Bearer behavior"

#
# Bootstrap ADMIN Authorization Code + PKCE
#

$adminAccessToken = Get-OAuth2AccessToken `
    -Username $script:BootstrapAdminUsername `
    -Password $script:BootstrapAdminPassword

Write-Host "OAuth2 ADMIN authentication passed"

#
# ADMIN /api/v1/me
#

$adminMeResponse = Invoke-FakeProdRequest `
    -Method Get `
    -Path "/api/v1/me" `
    -AccessToken $adminAccessToken

Assert-Status `
    -Response $adminMeResponse `
    -ExpectedStatus 200 `
    -Description "ADMIN /api/v1/me failed"

$adminAccount = Get-JsonContent `
    $adminMeResponse

if (-not $adminAccount.enabled) {

    throw "Bootstrap ADMIN is not enabled."
}

if (
    @($adminAccount.roles) -notcontains "USER" -or
    @($adminAccount.roles) -notcontains "ADMIN"
) {

    throw "Bootstrap ADMIN does not contain USER and ADMIN roles."
}

Assert-NoCredentialFields `
    -Account $adminAccount

Write-Host "ADMIN /api/v1/me passed"

#
# Create disposable USER
#

$createUserResponse = Invoke-FakeProdRequest `
    -Method Post `
    -Path "/api/v1/users" `
    -AccessToken $adminAccessToken `
    -Body @{
        username = $script:ValidationUserUsername
        password = $script:ValidationUserPassword
        enabled = $true
        roles = @(
            "USER"
        )
    }

Assert-Status `
    -Response $createUserResponse `
    -ExpectedStatus 201 `
    -Description "ADMIN could not create FAKE_PROD USER"

$validationUser = Get-JsonContent `
    $createUserResponse

if (
    [string]::IsNullOrWhiteSpace(
        [string] $validationUser.id
    )
) {

    throw "Created USER did not return an account UUID."
}

if (-not $validationUser.enabled) {

    throw "Created validation USER is not enabled."
}

if (
    @($validationUser.roles).Count -ne 1 -or
    @($validationUser.roles) -notcontains "USER"
) {

    throw "Created validation USER has unexpected roles."
}

Assert-NoCredentialFields `
    -Account $validationUser

$validationUserId = [string] $validationUser.id

Write-Host "USER creation passed"

#
# Disposable USER Authorization Code + PKCE
#

$userAccessToken = Get-OAuth2AccessToken `
    -Username $script:ValidationUserUsername `
    -Password $script:ValidationUserPassword

Write-Host "OAuth2 USER authentication passed"

#
# USER /api/v1/me
#

$userMeResponse = Invoke-FakeProdRequest `
    -Method Get `
    -Path "/api/v1/me" `
    -AccessToken $userAccessToken

Assert-Status `
    -Response $userMeResponse `
    -ExpectedStatus 200 `
    -Description "USER /api/v1/me failed"

$userAccount = Get-JsonContent `
    $userMeResponse

if (
    $userAccount.username -ne
    $script:ValidationUserUsername
) {

    throw "USER token resolved an unexpected account."
}

if (
    @($userAccount.roles) -notcontains "USER" -or
    @($userAccount.roles) -contains "ADMIN"
) {

    throw "USER account has an unexpected authorization role set."
}

Assert-NoCredentialFields `
    -Account $userAccount

Write-Host "USER /api/v1/me passed"

#
# USER cannot use ADMIN API
#

$userAdminResponse = Invoke-FakeProdRequest `
    -Method Get `
    -Path "/api/v1/users" `
    -AccessToken $userAccessToken

Assert-Status `
    -Response $userAdminResponse `
    -ExpectedStatus 403 `
    -Description "USER unexpectedly accessed ADMIN Identity API"

$userForbiddenProblem = Get-JsonContent `
    $userAdminResponse

if ($userForbiddenProblem.code -ne "ACCESS_DENIED") {

    throw "USER authorization error contract is incorrect."
}

Write-Host "USER authorization separation passed"

#
# ADMIN disables disposable USER
#

$disableUserResponse = Invoke-FakeProdRequest `
    -Method Put `
    -Path "/api/v1/users/$validationUserId/status" `
    -AccessToken $adminAccessToken `
    -Body @{
        enabled = $false
    }

Assert-Status `
    -Response $disableUserResponse `
    -ExpectedStatus 200 `
    -Description "ADMIN could not disable validation USER"

$disabledUser = Get-JsonContent `
    $disableUserResponse

if ($disabledUser.enabled) {

    throw "Validation USER remained enabled."
}

#
# A NEW authentication must now be rejected.
# Existing JWT revocation is intentionally not required.
#

$rejectedToken = Get-OAuth2AccessToken `
    -Username $script:ValidationUserUsername `
    -Password $script:ValidationUserPassword `
    -ExpectAuthenticationFailure

if ($null -ne $rejectedToken) {

    throw "Disabled USER unexpectedly received a new token."
}

Write-Host "Disabled USER reauthentication rejected"

Write-Host ""
Write-Host "FAKE_PROD validation passed."
Write-Host ""
Write-Host "Validated:"
Write-Host "- emulated ECR/ECS/RDS delivery"
Write-Host "- Core prod profile and external runtime contract"
Write-Host "- Nginx -> Core public boundary"
Write-Host "- production-shaped JWT signing configuration"
Write-Host "- OIDC discovery and public JWKS"
Write-Host "- Authorization Code + PKCE through Nginx"
Write-Host "- bootstrap ADMIN authentication"
Write-Host "- Core-issued Bearer token"
Write-Host "- ADMIN /api/v1/me"
Write-Host "- ADMIN Identity operation"
Write-Host "- USER /api/v1/me"
Write-Host "- USER/ADMIN authorization separation"
Write-Host "- disabled-user reauthentication rejection"
Write-Host "- Swagger/OpenAPI disabled"
Write-Host "- internal Actuator endpoints blocked"