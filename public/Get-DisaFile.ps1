

function Get-DisaFile {
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
        [datetime]$Since,
        [string]$Search,
        [string]$ExcludePattern,
        [Alias("Limit")]
        [int]$First,
        [int]$Last,
        [int]$Skip,
        [int]$Page,
        [string]$Thumbprint = ([System.Security.Cryptography.X509Certificates.X509Certificate2[]](Get-ChildItem Cert:\CurrentUser\My | Where-Object FriendlyName -like "*Authentication -*") | Select-Object -ExpandProperty Thumbprint),
        [int]$Force
    )
    process {
        if (-not $Thumbprint) {
            throw "Certificate thumbprint could not be automatically determined. Please use -Thumbprint to specify the desired certificate."
        }

        $baselink = "https://patches.csd.disa.mil"
        $pluginbase = "$baselink/Metadata.aspx?id"
        $loginurl = "$baselink/PkiLogin/Default.aspx"

        $PSDefaultParameterValues["Invoke-*:ErrorAction"] = "Stop"
        $PSDefaultParameterValues["Invoke-*:CertificateThumbprint"] = $Thumbprint
        $PSDefaultParameterValues["Invoke-*:UseBasicParsing"] = $true
        $PSDefaultParameterValues["Invoke-*:UserAgent"] = ([Microsoft.PowerShell.Commands.PSUserAgent]::InternetExplorer)

        if (-not $global:disalogin) {
            $null = Connect-DisaRepository
        }

        $PSDefaultParameterValues["Invoke-*:WebSession"] = $global:disalogin
        $ProgressPreference = "SilentlyContinue"

        $issearch = $false
        $rules = @()

        if ($Since) {
            $convertedDate = (Get-Date $Since -UFormat %e-%b-%Y).Trim()
            $rules += [PSCustomObject]@{
                field    = "CREATED_DATE"
                op       = "ge"
                data     = $convertedDate
                datatype = "date"
            }
        }

        if ($Search) {
            $issearch = $true
            $rules += [PSCustomObject]@{
                field    = "TITLE"
                op       = "cn"
                data     = $Search
                datatype = "text"
            }
        }

        if ($Since -or $Search) {
            $filters = [PSCustomObject]@{
                groupOp = "AND"
                rules   = $rules
            } | ConvertTo-Json
        } else {
            $filters = ""
        }

        $body = [PSCustomObject]@{
            collectionId = $global:repoid
            _search      = $issearch
            rows         = $First
            page         = 1
            filters      = $filters
        }

        $params = @{
            Uri         = "$baselink/Service/CollectionInfoService.svc/GetAssetsListingOfCollection"
            Method      = "POST"
            ContentType = "application/json; charset=UTF-8"
            Body        = $body | ConvertTo-Json
        }

        if (-not $First) {
            $body.rows = 15
            $params.Body = $body | ConvertTo-Json
            $First = (Invoke-RestMethod @params | ConvertFrom-Json).Total
            Write-Verbose "Limit set to $First"
            $body.rows = $First
            $params.Body = $body | ConvertTo-Json
        }

        $assets = Invoke-RestMethod @params

        $rows = $assets | ConvertFrom-Json | Select-Object -ExpandProperty Rows
        Write-Verbose "$($rows.Count) rows returned"

        foreach ($row in $rows) {
            if ($ExcludePattern) {
                if ($row.Title -match $ExcludePattern) {
                    Write-Verbose "Skipping $($row.Title) (matched ExcludePattern)"
                    continue
                }
            }
            $id = $row.STANDARDASSETID
            $link = "$pluginbase=$id"

            $data = Invoke-WebRequest -Uri $link

            $downloadfile = $data.links | Where-Object outerHTML -match ".ms|.exe|.tar|.zip"

            if (-not $downloadfile) {
                continue
            }

            foreach ($file in $downloadfile) {
                $downloadlink = ($baselink + ($file.href)).Replace("&amp;", "&")
                $headers = (Invoke-WebRequest -Uri $downloadlink -Method Head).Headers

                if (-not $headers.'Content-disposition') {
                    continue
                }

                $filename = $headers.'Content-disposition'.Replace("attachment;filename=", "").Replace("attachment; filename=", "")
                $size = $headers.'Content-Length' | Select-Object -First 1

                [PSCustomObject]@{
                    DownloadLink = $downloadlink
                    FileTitle    = $row.TITLE
                    FileName     = $filename
                    PostedDate   = $row.CREATED_DATE
                    SizeMB       = [math]::Round(($size / 1MB), 2)
                }
            }
        }
    }
}