

function Connect-DisaRepository {
    <#
    .SYNOPSIS
        Connects to a DISA Repository and creates a web session for reuse within Get-DisaFile and Save-DisaFile

    .DESCRIPTION
        Connects to a DISA Repository and creates a web session for reuse within Get-DisaFile and Save-DisaFile

    .PARAMETER Repository
        The repository to connect to. Currently, only the following repos are supported:

        MicrosoftSecurityBulletins
        MicrosoftSecurityAdvisories
        MicrosoftApplications
        MicrosoftToolkits

        Defaults to MicrosoftSecurityBulletins

    .PARAMETER Thumbprint
        Certificate thumbprint of the authorized smartcard

        By default, the command will try to figure out the right one

    .EXAMPLE
        PS> Connect-DisaRepository

        Conects to the MicrosoftSecurityBulletins repository with a thumbprint that matches "Authentication - "

    .EXAMPLE
        PS> Connect-DisaRepository -Repository MicrosoftSecurityAdvisories -Thumbprint A909502DD82AE41433E6F83886B00D4277A32A7B

        Connects to the MicrosoftSecurityAdvisories repository using certificate with thumbprint A909502DD82AE41433E6F83886B00D4277A32A7B
    #>
    [CmdletBinding()]
    param (
        [string]$Repository = "MicrosoftSecurityBulletins",
        [string]$Thumbprint = ([System.Security.Cryptography.X509Certificates.X509Certificate2[]](Get-ChildItem Cert:\CurrentUser\My | Where-Object FriendlyName -like "*Authentication -*") | Select-Object -ExpandProperty Thumbprint)
    )
    process {
        if (-not $Thumbprint -and -not $global:disadownload.certthumbprint) {
            throw "Certificate thumbprint could not be automatically determined. Please use Connect-DisaRepository -Thumbprint to specify the desired certificate."
        } else {
            if (-not $Thumbprint) {
                $Thumbprint = $global:disadownload.certthumbprint
            }
            $global:disadownload.certthumbprint = $Thumbprint
        }

        $global:disadownload.repoid = $global:disadownload.repos[$Repository]
        $PSDefaultParameterValues["Invoke-*:CertificateThumbprint"] = $global:disadownload.certthumbprint
        $loginurl = "https://patches.csd.disa.mil/PkiLogin/Default.aspx"

        try {
            Write-Verbose "Logging in to $Repository with Thumbprint $Thumbprint"
            $null = Invoke-WebRequest -Uri $loginurl -SessionVariable loginvar -WebSession $null
            $global:disadownload.disalogin = $loginvar
        } catch {
            $global:disadownload.disalogin = $null
            throw $PSItem
        }

        Write-Verbose "Setting global WebSession"
        $PSDefaultParameterValues["Invoke-*:WebSession"] = $global:disadownload.disalogin

        $body = [PSCustomObject]@{
            collectionId = $global:disadownload.repoid
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
            $global:disadownload.totalrows = (Invoke-RestMethod @params | ConvertFrom-Json).Total
        } catch {
            throw $PSItem
        }

        [PSCustomObject]@{
            Repository   = $Repository
            RepositoryId = $global:disadownload.repoid
            TotalRows    = $global:disadownload.totalrows
            Thumbprint   = $global:disadownload.certthumbprint
            Status       = "Connected"
        }
    }
}