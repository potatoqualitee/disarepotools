

function Get-DisaFile {
    <#
    .SYNOPSIS
        Gets a list of downloads available from the DISA Patch Repository

    .DESCRIPTION
        This command a list of downloads available from the DISA Patch Repository

        Smartcard authentication is supported

    .PARAMETER Since
        List only files since a certain date

    .PARAMETER Search
        Use Keyword filtering

    .PARAMETER ExcludePattern
        DISA's site does not support exclusions at this time. Use this to filter out results that
        are returned from the website

    .PARAMETER Limit
        Limit the number of files returned. By default, all files are returned.

    .PARAMETER Page
        Specify the page needed

    .PARAMETER SortOrder
        The sort order. Options are Descending or Ascending.

    .PARAMETER SortColumn
        The column to sort by. Options are TITLE or CREATED_DATE. Default is TITLE.

    .EXAMPLE
        PS> Get-DisaFile

    .EXAMPLE
        PS> $date = (Get-Date).AddDays(-30)
        PS> Get-DisaFile -Since $date

    .EXAMPLE
        PS> Get-DisaFile -Limit 3

        Get just the first three files

    .EXAMPLE
        PS> Get-DisaFile -Search "Windows Server" -ExcludePattern "x86|ARM64" -SortOrder Ascending -Limit 3

        Get just the first three files
    #>
    [CmdletBinding()]
    param (
        [datetime]$Since,
        [string]$Search,
        [string]$ExcludePattern,
        [Alias("First")]
        [int]$Limit,
        [int]$Page = 1,
        [ValidateSet("Ascending", "Descending")]
        [string]$SortOrder,
        [ValidateSet("TITLE", "CREATED_DATE")]
        [string]$SortColumn = "TITLE"
    )
    begin {
        $baselink = "https://patches.csd.disa.mil"
        $pluginbase = "$baselink/Metadata.aspx?id"
    }
    process {
        if (-not $global:disadownload.disalogin) {
            try {
                $null = Connect-DisaRepository
            } catch {
                throw "Connection timedout or login failed. Please connect manually using Connect-DisaRepository."
            }
        }

        $PSDefaultParameterValues["Invoke-*:CertificateThumbprint"] = $global:disadownload.certthumbprint
        $PSDefaultParameterValues["Invoke-*:WebSession"] = $global:disadownload.disalogin

        $ProgressPreference = "SilentlyContinue"

        if (-not $Limit) {
            $Limit = $global:disadownload.totalrows
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
            collectionId = $global:disadownload.repoid
            _search      = $($Since -or $Search)
            rows         = $Limit
            page         = $Page
            filters      = $filters
        }

        if ($SortOrder) {
            Write-Verbose "Sorting"
            if ($SortOrder -eq "Ascending") {
                $sortor = "asc"
            } else {
                $sortor = "desc"
            }
            $body.sidx = $SortColumn
            $body.sord = $sortor
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
            Write-Verbose "$(($downloadfile).Count) total download files found"
            if (-not $downloadfile) {
                Write-Verbose "No links found, moving on"
                continue
            }

            foreach ($file in $downloadfile) {
                Write-Verbose "Getting detailed information"
                $downloadlink = ($baselink + ($file.href)).Replace("&amp;", "&")

                if (-not $global:disadownload.linkdetails[$downloadlink]) {
                    Write-Verbose "Link not found in cache, grabbing headers"
                    $headers = (Invoke-WebRequest -Uri $downloadlink -Method Head).Headers

                    if (-not $headers.'Content-disposition') {
                        continue
                    }

                    $filename = $headers.'Content-disposition'.Replace("attachment;filename=", "").Replace("attachment; filename=", "")
                    $size = $headers.'Content-Length' | Select-Object -First 1
                    $temp = [PSCustomObject]@{
                        filename = "hello"
                        size     = 1
                    }
                    $global:disadownload.linkdetails[$downloadlink] = $temp
                } else {
                    Write-Verbose "Link details found in cache"
                    $filename = $global:disadownload.linkdetails[$downloadlink].filename
                    $size = $global:disadownload.linkdetails[$downloadlink].size
                }

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