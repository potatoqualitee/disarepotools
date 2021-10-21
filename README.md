<img align="left" src=https://user-images.githubusercontent.com/8278033/68308152-a886c180-00ac-11ea-880c-ef6ff99f5cd4.png alt="disadownload logo">

# disadownload
DISA Repository File Manager

## Install

```powershell
Install-Module disadownload -Scope CurrentUser
```

## Connect-DisaRepository

Connects to a DISA Repository and creates a web session for reuse within Get-DisaFile and Save-DisaFile

```powershell
# Connect to the MicrosoftSecurityBulletins repository with a thumbprint that matches "Authentication - "
Connect-DisaRepository

# Connect to the MicrosoftSecurityAdvisories repository using certificate with thumbprint A909502DD82AE41433E6F83886B00D4277A32A7B
Connect-DisaRepository -Repository MicrosoftSecurityAdvisories -Thumbprint A909502DD82AE41433E6F83886B00D4277A32A7B
```

## Get-DisaFile

 Gets a list of files available for download from the DISA Patch Repository

```powershell
# Get a list of every file in the connected DISA repository
Get-DisaFile

# Get a list of files published in the last 30 days
$date = (Get-Date).AddDays(-30)
Get-DisaFile -Since $date

# Get just the first three results. Note that if one result has multiple files, this is not calculated in the limit.
Get-DisaFile -Limit 3

#  Search for Windows Server and excludes any files matching x86 or ARM64, ordered by oldest created
Get-DisaFile -Search "Windows Server" -ExcludePattern "x86|ARM64" -SortOrder Ascending
```

## Save-DisaFile

Downloads files from DISA repositories in parallel

```powershell
# Download the whole repository
Get-DisaFile | Save-DisaFile

# Download selected files to C:\temp
Get-DisaFile -Limit 15 | Out-GridView -PassThru | Save-DisaFile -Path C:\temp

# Download files matching "Windows 10" to C:\temp\win10
Get-DisaFile -Limit 15 -Search "Windows 10" | Save-DisaFile -Path C:\temp\Win10
```


## Screenshots

## More Help

Get more help

```powershell
Get-Help Get-DisaFile -Detailed
```