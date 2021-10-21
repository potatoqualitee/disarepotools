function Save-DisaFile {
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
        [Parameter(ValueFromPipeline, Mandatory)]
        [psobject]$InputObject,
        [Alias("FullName")]
        [ValidateScript( { Test-Path -Path $_ } )]
        [string]$Path = $PWD
    )
    begin {
        $PSDefaultParameterValues["Invoke-*:CertificateThumbprint"] = $global:disadownload.certthumbprint
        $PSDefaultParameterValues["Invoke-*:WebSession"] = $global:disadownload.disalogin
        $allfiles = @()
        $number = 0
    }
    process {
        $allfiles += $InputObject
    }
    end {
        $total = $allfiles.Count
        foreach ($file in $allfiles) {
            try {
                $number++
                $title = $file.FileTitle
                $filename = $file.filename
                $size = $file.SizeMB
                $source = $file.DownloadLink
                $destination = Join-Path -Path $Path -ChildPath $filename
                Write-Verbose "Downloading $title -$filename. File size: $size MB."

                $params = @{
                    TotalSteps = $total + 1
                    StepNumber = $number
                    Message    = "Downloading $filename ($size MB)"
                    Activity   = "Downloading file $number of $total"
                }
                Write-ProgressHelper @params

                $ProgressPreference = "SilentlyContinue"
                Invoke-RestMethod -Uri $source -OutFile $destination
                $ProgressPreference = "Continue"
                Get-ChildItem -Path $destination
            } catch {
                Write-Warning "Couldn't download $($filename): $PSItem"
                continue
            }
        }
    }
}