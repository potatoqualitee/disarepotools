

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

        Connects to the MicrosoftSecurityBulletins repository with a thumbprint that matches "Authentication - "

    .EXAMPLE
        PS> Connect-DisaRepository -Repository MicrosoftSecurityAdvisories -Thumbprint A909502DD82AE41433E6F83886B00D4277A32A7B

        Connects to the MicrosoftSecurityAdvisories repository using certificate with thumbprint A909502DD82AE41433E6F83886B00D4277A32A7B
    #>
    [CmdletBinding()]
    param (
        [string]$Repository = "MicrosoftSecurityBulletins",
        [string]$Thumbprint
    )
    begin {
        if (-not $Thumbprint) {
            $thumbprints = Get-ChildItem Cert:\CurrentUser\My | Where-Object FriendlyName -like "*Authentication -*"
            if ($thumbprints.count -eq 1) {
                $Thumbprint = $thumbprints | Select-Object -ExpandProperty Thumbprint
            } else {
                $Thumbprint = Get-ChildItem Cert:\CurrentUser\My | Select-Object FriendlyName, Thumbprint, Subject, Issuer | Out-GridView -Passthru | Select-Object -First 1 -ExpandProperty Thumbprint
            }
        }
    }
    process {
        if (-not $Thumbprint -and -not $global:disarepotools.certthumbprint) {
            throw "Certificate thumbprint could not be automatically determined. Please use Connect-DisaRepository -Thumbprint to specify the desired certificate."
        } else {
            if (-not $Thumbprint) {
                $Thumbprint = $global:disarepotools.certthumbprint
            }
            $global:disarepotools.certthumbprint = $Thumbprint
        }

        $global:disarepotools.currentrepo = $Repository
        $global:disarepotools.repoid = $global:disarepotools.repos[$Repository]
        $PSDefaultParameterValues["Invoke-*:CertificateThumbprint"] = $global:disarepotools.certthumbprint
        $loginurl = "https://patches.csd.disa.mil/PkiLogin/Default.aspx"

        try {
            Write-Verbose "Logging in to $Repository with Thumbprint $Thumbprint"
            try {
                $null = Invoke-WebRequest -Uri $loginurl -SessionVariable loginvar -WebSession $null
            } catch {
                # Sometimes it fails for an unknown reason. Try again.
                $null = Invoke-WebRequest -Uri $loginurl -SessionVariable loginvar -WebSession $null
            }
            $global:disarepotools.disalogin = $loginvar
        } catch {
            $global:disarepotools.disalogin = $null
            throw $PSItem
        }

        Write-Verbose "Setting global WebSession"
        $PSDefaultParameterValues["Invoke-*:WebSession"] = $global:disarepotools.disalogin

        $body = [PSCustomObject]@{
            collectionId = $global:disarepotools.repoid
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
            $global:disarepotools.totalrows = (Invoke-RestMethod @params | ConvertFrom-Json).Total
        } catch {
            throw $PSItem
        }

        [PSCustomObject]@{
            Repository   = $Repository
            RepositoryId = $global:disarepotools.repoid
            TotalRows    = $global:disarepotools.totalrows
            Thumbprint   = $global:disarepotools.certthumbprint
            Status       = "Connected"
        }
    }
}