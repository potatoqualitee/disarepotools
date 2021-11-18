function Save-DisaFile {
    <#
    .SYNOPSIS
        Downloads files from DISA repositories in parallel

    .DESCRIPTION
        Downloads files from DISA repositories in parallel

    .PARAMETER InputObject
        The piped object from Get-DisaFile

    .PARAMETER Path
        The path to save all files

        Defaults to current directory if not specified

    .PARAMETER AllowClobber
        By default, file will not be downloaded if it already exists. Use AllowClobber to redownload.

    .EXAMPLE
        Get-DisaFile -Verbose -OutVariable files | Save-DisaFile

        Download the whole repository and save the results of Get-DisaFile to $files

    .EXAMPLE
        PS> $date = (Get-Date).AddDays(-30)
        PS> Get-DisaFile -Since $date -Verbose | Save-DisaFile

        Downloads files published in the last 30 days

    .EXAMPLE
        Get-DisaFile -Limit 15 | Out-GridView -PassThru | Save-DisaFile -Path C:\temp

        Download selected files to C:\temp

    .EXAMPLE
        Get-DisaFile -Limit 15 -Search "Windows 10" | Save-DisaFile -Path C:\temp\Win10

        Download files matching "Windows 10" to C:\temp\win10

    .EXAMPLE
        Get-DisaFile | Save-DisaFile -AllowClobber -Verbose

        Overwrite existing files
    #>
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline, Mandatory)]
        [psobject]$InputObject,
        [Alias("FullName")]
        [ValidateScript( { Test-Path -Path $_ } )]
        [string]$Path = $PWD,
        [switch]$AllowClobber
    )
    begin {
        $allfiles = @()
    }
    process {
        $allfiles += $InputObject
    }
    end {
        try {
            Write-Verbose "Reconnecting once just in case"
            $null = Connect-DisaRepository -Thumbprint $global:disarepotools.certthumbprint -Repository $global:disarepotools.currentrepo
        } catch {
            continue
        }

        $allfiles | Invoke-Parallel -ImportVariables -ScriptBlock {
            try {
                $title = $psitem.Title
                $filename = $psitem.filename
                $size = $psitem.SizeMB
                $source = $psitem.DownloadLink
                $destination = Join-Path -Path $Path -ChildPath $filename
                Write-Verbose "Downloading $title -$filename. File size: $size MB."

                if (-not (Test-Path -Path $destination) -or $AllowClobber) {
                    $ProgressPreference = "SilentlyContinue"
                    try {
                        Invoke-RestMethod -Uri $source -OutFile $destination -CertificateThumbprint $global:disarepotools.certthumbprint -WebSession $global:disarepotools.disalogin
                    } catch {
                        Write-Verbose "Trying again"
                        Invoke-RestMethod -Uri $source -OutFile $destination -CertificateThumbprint $global:disarepotools.certthumbprint -WebSession $global:disarepotools.disalogin
                    }
                    $ProgressPreference = "Continue"
                }
                Get-ChildItem -Path $destination -ErrorAction SilentlyContinue
            } catch {
                Write-Warning "Couldn't download $($filename): $PSItem"
                continue
            }
        }
    }
}