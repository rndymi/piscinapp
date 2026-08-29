param(

    [string] $CoreRepositoryPath = "",

    [switch] $KeepRunning
)

$ErrorActionPreference = "Stop"

try {

    & "$PSScriptRoot/start.ps1"

    & "$PSScriptRoot/provision.ps1"

    if ([string]::IsNullOrWhiteSpace($CoreRepositoryPath)) {

        & "$PSScriptRoot/deploy.ps1"
    }
    else {

        & "$PSScriptRoot/deploy.ps1" `
            -CoreRepositoryPath $CoreRepositoryPath
    }

    & "$PSScriptRoot/validate.ps1"

    Write-Host ""
    Write-Host "PiscinApp FAKE_PROD completed successfully."
}
finally {

    if (-not $KeepRunning) {

        Write-Host ""
        Write-Host "Cleaning FAKE_PROD..."
        Write-Host ""

        & "$PSScriptRoot/stop.ps1"
    }
    else {

        Write-Host ""
        Write-Host "FAKE_PROD remains running because -KeepRunning was specified."
    }
}
