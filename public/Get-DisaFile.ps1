

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
        [Alias("First")]
        [int]$Limit,
        [int]$Page = 1,
        [string]$Thumbprint = ([System.Security.Cryptography.X509Certificates.X509Certificate2[]](Get-ChildItem Cert:\CurrentUser\My | Where-Object FriendlyName -like "*Authentication -*") | Select-Object -ExpandProperty Thumbprint),
        [ValidateSet("Ascending", "Descending")]
        [string]$Sort,
        [ValidateSet("TITLE", "CREATED_DATE")]
        [string]$SortColumn = "TITLE",
        [int]$Force
    )
    begin {
        $baselink = "https://patches.csd.disa.mil"
        $pluginbase = "$baselink/Metadata.aspx?id"
        $PSDefaultParameterValues["Invoke-*:CertificateThumbprint"] = $Thumbprint
        $PSDefaultParameterValues["Invoke-*:WebSession"] = $global:disalogin
    }
    process {
        if (-not $global:disalogin) {
            try {
                $null = Connect-DisaRepository
            } catch {
                throw "Connection timedout or login failed. Please connect manually using Connect-DisaRepository."
            }
        }

        $ProgressPreference = "SilentlyContinue"

        if (-not $Limit) {
            $Limit = $global:totalrows
        }

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

        Write-Verbose "Is search: $($Since -or $Search)"

        $body = @{
            collectionId = $global:repoid
            _search      = $($Since -or $Search)
            rows         = $Limit
            page         = $Page
            filters      = $filters
        }

        if ($Sort -eq "Ascending") {
            Write-Verbose "Sorting"
            if ($Sort -eq "Ascending") {
                $sortorder = "asc"
            } else {
                $sortorder = "desc"
            }
            $body.sidx = $SortColumn
            $body.sord = $sortorder
        }

        $params = @{
            Uri         = "$baselink/Service/CollectionInfoService.svc/GetAssetsListingOfCollection"
            Method      = "POST"
            ContentType = "application/json; charset=UTF-8"
            Body        = [PSCustomObject]$body | ConvertTo-Json
        }

        try {
            Write-Verbose "Getting a list of all assets"
            $assets = Invoke-RestMethod @params
        } catch {
            throw $PSItem
        }

        $rows = $assets | ConvertFrom-Json | Select-Object -ExpandProperty Rows
        Write-Verbose "$(($rows).Count) total rows returned"

        foreach ($row in $rows) {
            if ($ExcludePattern) {
                if ($row.Title -match $ExcludePattern) {
                    Write-Verbose "Skipping $($row.Title) (matched ExcludePattern)"
                    continue
                }
            }

            $id = $row.STANDARDASSETID
            $link = "$pluginbase=$id"

            try {
                Write-Verbose "Finding link"
                $data = Invoke-WebRequest -Uri $link
            } catch {
                throw $PSItem
            }

            $downloadfile = $data.links | Where-Object outerHTML -match ".ms|.exe|.tar|.zip"
            Write-Warning "$(($downloadfile).Count) total download files found"
            if (-not $downloadfile) {
                Write-Verbose "No links found, moving on"
                continue
            }

            foreach ($file in $downloadfile) {
                Write-Verbose "Getting detailed information"
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