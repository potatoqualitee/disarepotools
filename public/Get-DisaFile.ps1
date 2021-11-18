

function Get-DisaFile {
    <#
    .SYNOPSIS
        Gets a list of files available for download from the DISA Patch Repository

    .DESCRIPTION
        This command gets a list of files available for download from the DISA Patch Repository

        Smartcard authentication is supported, woo!

    .PARAMETER Since
        List only files published since a certain date

    .PARAMETER Search
        Use Keyword filtering like you do on the DISA website

    .PARAMETER ExcludePattern
        DISA's site does not support exclusions at this time. Use this to filter out results that
        are returned

    .PARAMETER Limit
        Limit the number of files returned. By default, all files found in the repository are returned.

        Note that if one bulletin/post/KB has multiple files, this is not calculated in the limit.

    .PARAMETER Page
        Specify the page needed

    .PARAMETER SortOrder
        The sort order

        Options are Descending or Ascending

        Default from DISA's site is CREATED_DATE Descending

    .PARAMETER SortColumn
        The column to sort by

        Options are TITLE or CREATED_DATE

        Default is TITLE but SortColumn is only called when SortOrder is specified

    .EXAMPLE
        PS> Get-DisaFile

        Gets a list of every file in the connected DISA repository

    .EXAMPLE
        PS> $date = (Get-Date).AddDays(-30)
        PS> Get-DisaFile -Since $date

        Gets a list of files published in the last 30 days

    .EXAMPLE
        PS> Get-DisaFile -Limit 3

        Get just the first three results

        Note that if one result has multiple files, this is not calculated in the limit

    .EXAMPLE
        PS> Get-DisaFile -Search "Windows Server" -ExcludePattern "x86|ARM64" -SortOrder Ascending

        Searches for Windows Server and excludes any files matching x86 or ARM64, ordered by oldest created
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
        $currentrow = 0
        $PSDefaultParameterValues["Invoke-*:MaximumRetryCount"] = 5
        $PSDefaultParameterValues["Invoke-*:RetryIntervalSec"] = 1
    }
    process {
        if (-not $global:disarepotools.disalogin) {
            try {
                $null = Connect-DisaRepository
            } catch {
                throw "Connection timedout or login failed. Please connect manually using Connect-DisaRepository."
            }
        }

        $PSDefaultParameterValues["Invoke-*:CertificateThumbprint"] = $global:disarepotools.certthumbprint
        $PSDefaultParameterValues["Invoke-*:WebSession"] = $global:disarepotools.disalogin

        $ProgressPreference = "SilentlyContinue"

        if (-not $Limit) {
            $Limit = $global:disarepotools.totalrows
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
            collectionId = $global:disarepotools.repoid
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
            Write-Verbose "Connection may have timed out, trying to connect again"
            try {
                $null = Connect-DisaRepository -Thumbprint $global:disarepotools.certthumbprint -Repository $global:disarepotools.currentrepo
                $assets = Invoke-RestMethod @params
            } catch {
                throw $PSItem
            }
        }

        $rows = $assets | ConvertFrom-Json | Select-Object -ExpandProperty Rows
        Write-Verbose "$(($rows).Count) total rows returned"

        foreach ($row in $rows) {
            $currentrow++
            $rowtitle = $row.TITLE
            Write-Verbose "Processing $currentrow of $(($rows).Count)"

            if ($ExcludePattern) {
                if ($rowtitle -match $ExcludePattern) {
                    Write-Verbose "Skipping $rowtitle (matched ExcludePattern)"
                    continue
                }
            }

            if ($global:disarepotools.rowresults[$rowtitle]) {
                Write-Verbose "Found result in cache"
                $global:disarepotools.rowresults[$rowtitle]
                continue
            }

            $results = @()
            $id = $row.STANDARDASSETID
            $link = "$pluginbase=$id"

            try {
                Write-Verbose "Finding link"
                try {
                    $data = Invoke-WebRequest -Uri $link
                } catch {
                    Write-Verbose "Trying again"
                    $data = Invoke-WebRequest -Uri $link
                }
            } catch {
                Write-Warning "Can't connect to link: $PSItem. Moving on"
                continue
            }

            $downloadfile = $data.links | Where-Object outerHTML -match ".ms|.exe|.tar|.zip"
            Write-Verbose "$(($downloadfile).Count) total download files found"
            if (-not $downloadfile) {
                Write-Verbose "No links found, moving on"
                continue
            }

            foreach ($file in $downloadfile) {
                Write-Verbose "Getting detailed information"
                $product = $null
                $downloadlink = ($baselink + ($file.href)).Replace("&amp;", "&")
                Write-Verbose "Download link: $downloadlink"
                if (-not $global:disarepotools.linkdetails[$downloadlink]) {
                    Write-Verbose "Link not found in cache, grabbing headers"

                    try {
                        $headers = (Invoke-WebRequest -Uri $downloadlink -Method Head).Headers
                    } catch {
                        Write-Verbose "Trying again"
                        $headers = (Invoke-WebRequest -Uri $downloadlink -Method Head).Headers
                    }

                    if (-not $headers.'Content-disposition') {
                        Write-Verbose "No link found, skipping"
                        $global:disarepotools.linkdetails[$downloadlink] = "Skipped"
                        continue
                    }

                    $filename = $headers.'Content-disposition'.Replace("attachment;filename=", "").Replace("attachment; filename=", "")
                    $size = $headers.'Content-Length' | Select-Object -First 1
                    $temp = [PSCustomObject]@{
                        filename = $filename
                        size     = $size
                    }
                    $global:disarepotools.linkdetails[$downloadlink] = $temp
                } else {
                    Write-Verbose "Link details found in cache"
                    if ($global:disarepotools.linkdetails[$downloadlink] -eq "Skipped") {
                        Write-Verbose "No link found, skipping"
                        continue
                    }
                    $filename = $global:disarepotools.linkdetails[$downloadlink].filename
                    $size = $global:disarepotools.linkdetails[$downloadlink].size
                }

                if ($global:disarepotools.currentrepo -eq "MicrosoftSecurityBulletins") {

                    if ($rowtitle -match "x64" -or $filename -match "-x64_" -or $rowtitle -match "64-bit") {
                        $arch = "x64"
                    } elseif ($rowtitle -match "arm64" -or $filename -match "-arm64_") {
                        $arch = "arm64"
                    } elseif ($rowtitle -match "x86" -or $filename -match "x86" -or $rowtitle -match "32-bit") {
                        $arch = "x86"
                    } else {
                        $arch = $null
                    }

                    if ($rowtitle -match "Windows Embedded") {
                        $product = "Windows Embedded"
                    }

                    if ($rowtitle -match "Windows 7") {
                        $product = "Windows 7"
                    }

                    if ($rowtitle -match "Windows 8") {
                        $product = "Windows 8"
                    }

                    if ($rowtitle -match "Windows 8.1") {
                        $product = "Windows 8.1"
                    }

                    if ($rowtitle -match "Windows 11") {
                        $product = "Windows 11"
                    }

                    if ($rowtitle -match "Windows 10") {
                        if ($rowtitle -match "1809") {
                            $product = "Windows 10 Version 1809"
                        } elseif ($rowtitle -match "1909") {
                            $product = "Windows 10 Version 1909"
                        } elseif ($rowtitle -match "2004") {
                            $product = "Windows 10 Version 2004"
                        } elseif ($rowtitle -match "21H1") {
                            $product = "Windows 10 Version 21H1"
                        } elseif ($rowtitle -match "20H2") {
                            $product = "Windows 10 Version 20H2"
                        } elseif ($rowtitle -match "1507") {
                            $product = "Windows 10 Version 1507"
                        } elseif ($rowtitle -match "1607") {
                            $product = "Windows 10 Version 1607"
                        } else {
                            $product = "Windows 10"
                        }
                    }

                    if ($rowtitle -match "Windows Server") {
                        if ($rowtitle -match "2012 R2") {
                            $product = "Windows Server 2012 R2"
                        } elseif ($rowtitle -match "2012") {
                            $product = "Windows Server 2012"
                        } elseif ($rowtitle -match "2019") {
                            $product = "Windows Server 2019"
                        } elseif ($rowtitle -match "21H2") {
                            $product = "Windows Server Version 21H2"
                        } elseif ($rowtitle -match "2004") {
                            $product = "Windows Server Version 2004"
                        } elseif ($rowtitle -match "2008 R2") {
                            $product = "Windows Server 2008 R2"
                        } elseif ($rowtitle -match "2008") {
                            $product = "Windows Server 2008"
                        } elseif ($rowtitle -match "2022") {
                            $product = "Windows Server 2022"
                        } else {
                            $product = "Windows Server"
                        }
                    }

                    if ($rowtitle -match "server" -and $rowtitle -match "21H2") {
                        $product = "Windows Server Version 21H2"
                    }

                    if (-not $product) {
                        if ($rowtitle -match ".NET") {
                            $product = ".NET"
                        }
                        if ($rowtitle -match ".NET Core") {
                            $product = ".NET Core"
                        }
                        if ($rowtitle -match "Excel") {
                            $product = "Excel"
                        }
                        if ($rowtitle -match "SharePoint") {
                            $product = "SharePoint"
                        }
                        if ($rowtitle -match "Microsoft Word") {
                            $product = "Word"
                        }
                        if ($rowtitle -match "Microsoft Office") {
                            $product = "Office"
                        }
                        if ($rowtitle -match "Edge") {
                            $product = "Edge"
                        }
                        if ($rowtitle -match "Malicious") {
                            $product = "Malicious Software Removal Tool"
                        }
                        if ($rowtitle -match "Exchange") {
                            $product = "Exchange"
                        }
                        if ($rowtitle -match "Azure Stack") {
                            $product = "Azure Stack"
                        }
                    }
                    # I don't know regex
                    $guid = $filename.Split("_") | Select-Object -Last 1
                    $guid = $guid.Split(".") | Select-Object -First 1
                    $date = ($rowtitle).Split(" ") | Select-Object -First 1
                    if ($rowtitle -match "KB") {
                        $kb = ($rowtitle).Split(" (KB") | Where-Object { "$PSItem".EndsWith(")") }
                        $kb = $kb.Replace(")", "")
                        $kb = $kb | Where-Object { $PSItem -match "^[\d\.]+$" }
                    } else {
                        $kb = $null
                    }
                    $title = ($rowtitle).Replace("$date ", "").Replace(" (KB$kb)", "").Trim()

                    $result = [PSCustomObject]@{
                        Title        = $title
                        FileName     = $filename
                        Architecture = $arch
                        Product      = $product
                        SizeMB       = [math]::Round(($size / 1MB), 2)
                        DownloadLink = $downloadlink
                        PostedDate   = $row.CREATED_DATE
                        GUID         = $guid
                        DisaDate     = $date
                        KB           = $kb
                    }
                } else {
                    $result = [PSCustomObject]@{
                        Title        = $rowtitle
                        FileName     = $filename
                        SizeMB       = [math]::Round(($size / 1MB), 2)
                        DownloadLink = $downloadlink
                        PostedDate   = $row.CREATED_DATE
                    }
                }
                $results += $result
                $result
            }
            $global:disarepotools.rowresults[$rowtitle] = $results
        }
    }
}