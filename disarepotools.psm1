#requires -Version 5.1
$script:ModuleRoot = $PSScriptRoot

function Import-ModuleFile {
    <#
		.SYNOPSIS
			Loads files into the module on module import.

		.DESCRIPTION
			This helper function is used during module initialization.
			It should always be dotsourced itself, in order to proper function.

			This provides a central location to react to files being imported, if later desired

		.PARAMETER Path
			The path to the file to load

		.EXAMPLE
			PS C:\> . Import-ModuleFile -File $function.FullName

			Imports the file stored in $function according to import policy
	    #>
    [CmdletBinding()]
    Param (
        [string]
        $Path
    )

    if ($doDotSource) { . $Path }
    else { $ExecutionContext.InvokeCommand.InvokeScript($false, ([scriptblock]::Create([io.file]::ReadAllText($Path))), $null, $null) }
}

# Import all internal functions
foreach ($function in (Get-ChildItem "$ModuleRoot\private" -Filter "*.ps1" -Recurse -ErrorAction Ignore)) {
    . Import-ModuleFile -Path $function.FullName
}

# Import all public functions
foreach ($function in (Get-ChildItem "$ModuleRoot\public" -Filter "*.ps1" -Recurse -ErrorAction Ignore)) {
    . Import-ModuleFile -Path $function.FullName
}

# Setup initial collections and use Synchronized which works with runspaces
if (-not $global:disarepotools) {
    $global:disarepotools = [hashtable]::Synchronized(@{ })
    $global:disarepotools.linkdetails = [hashtable]::Synchronized(@{ })

    $global:disarepotools.repos = @{
        MicrosoftSecurityBulletins  = 15
        MicrosoftSecurityAdvisories = 734
        MicrosoftApplications       = 732
        MicrosoftToolkits           = 733
    }
}

# Register autocompleter script
Register-PSFTeppScriptblock -Name Repository -ScriptBlock { $global:disarepotools.repos.Keys }

# Register the actual auto completer
Register-PSFTeppArgumentCompleter -Command Connect-DisaRepository -Parameter Repository -Name Repository

$PSDefaultParameterValues["Invoke-*:ErrorAction"] = "Stop"
$PSDefaultParameterValues["Invoke-*:UseBasicParsing"] = $true
$PSDefaultParameterValues["Invoke-*:MaximumRetryCount"] = 10
$PSDefaultParameterValues["Invoke-*:RetryIntervalSec"] = 1
$PSDefaultParameterValues["Invoke-*:UserAgent"] = ([Microsoft.PowerShell.Commands.PSUserAgent]::InternetExplorer)

if (-not $IsLinux -and -not $IsMacOs) {
    $regproxy = Get-ItemProperty -Path "Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $proxy = $regproxy.ProxyServer

    if ($proxy -and -not ([System.Net.Webrequest]::DefaultWebProxy).Address -and $regproxy.ProxyEnable) {
        [System.Net.Webrequest]::DefaultWebProxy = New-object System.Net.WebProxy $proxy
        [System.Net.Webrequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    }
}

$currentVersionTls = [Net.ServicePointManager]::SecurityProtocol
$currentSupportableTls = [Math]::Max($currentVersionTls.value__, [Net.SecurityProtocolType]::Tls.value__)
$availableTls = [enum]::GetValues('Net.SecurityProtocolType') | Where-Object { $_ -gt $currentSupportableTls }
$availableTls | ForEach-Object {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $_
}
