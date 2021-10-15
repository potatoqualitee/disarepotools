

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
        }

        $global:repoid = $global:repos[$Repository]
        $PSDefaultParameterValues["Invoke-*:ErrorAction"] = "Stop"
        $PSDefaultParameterValues["Invoke-*:CertificateThumbprint"] = $Thumbprint
        $PSDefaultParameterValues["Invoke-*:UseBasicParsing"] = $true
        $PSDefaultParameterValues["Invoke-*:UserAgent"] = ([Microsoft.PowerShell.Commands.PSUserAgent]::InternetExplorer)
        $loginurl = "https://patches.csd.disa.mil/PkiLogin/Default.aspx"
        $null = Invoke-WebRequest -Uri $loginurl -SessionVariable global:disalogin

        $PSDefaultParameterValues["Invoke-*:WebSession"] = $global:disalogin
        $ProgressPreference = "SilentlyContinue"

        [PSCustomObject]@{
            Repository   = $Repository
            RepositoryId = $global:repoid
            Status       = "Connected"
        }
    }
}