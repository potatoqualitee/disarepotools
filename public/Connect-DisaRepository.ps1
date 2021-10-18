

function Connect-DisaRepository {
    <#
    .SYNOPSIS
    Sup

    .DESCRIPTION
    Sup

    .EXAMPLE
    Sup
    #>
    [CmdletBinding()]
    param (
        [string]$Repository = "MicrosoftSecurityBulletins",
        [string]$Thumbprint = ([System.Security.Cryptography.X509Certificates.X509Certificate2[]](Get-ChildItem Cert:\CurrentUser\My | Where-Object FriendlyName -like "*Authentication -*") | Select-Object -ExpandProperty Thumbprint)
    )
    process {
        if (-not $Thumbprint) {
            throw "Certificate thumbprint could not be automatically determined. Please use Connect-DisaRepository -Thumbprint to specify the desired certificate."
        } else {
            $global:certthumbprint = $Thumbprint
        }

        $global:repoid = $global:repos[$Repository]
        $PSDefaultParameterValues["Invoke-*:CertificateThumbprint"] = $Thumbprint
        $loginurl = "https://patches.csd.disa.mil/PkiLogin/Default.aspx"

        try {
            Write-Verbose "Logging in to $Repository with Thumbprint $Thumbprint"
            $null = Invoke-WebRequest -Uri $loginurl -SessionVariable global:disalogin -WebSession $null
        } catch {
            $global:disalogin = $null
            throw $PSItem
        }

        Write-Verbose "Setting global WebSession"
        $PSDefaultParameterValues["Invoke-*:WebSession"] = $global:disalogin

        $body = [PSCustomObject]@{
            collectionId = $global:repoid
            _search      = $false
            rows         = 15
            page         = 1
            filters      = ""
        }

        $params = @{
            Uri         = "https://patches.csd.disa.mil/Service/CollectionInfoService.svc/GetAssetsListingOfCollection"
            Method      = "POST"
            ContentType = "application/json; charset=UTF-8"
            Body        = $body | ConvertTo-Json
        }

        try {
            Write-Verbose "Getting total records"
            $global:totalrows = (Invoke-RestMethod @params | ConvertFrom-Json).Total
        } catch {
            throw $PSItem
        }

        [PSCustomObject]@{
            Repository   = $Repository
            RepositoryId = $global:repoid
            TotalRows    = $global:totalrows
            Thumbprint   = $global:certthumbprint
            Status       = "Connected"
        }
    }
}