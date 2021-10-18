#requires -Version 5.1
$global:ModuleRoot = $PSScriptRoot

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

# Setup initial collections
if (-not $global:kbcollection) {
    $global:kbcollection = [hashtable]::Synchronized(@{ })
}

if (-not $global:compcollection) {
    $global:compcollection = [hashtable]::Synchronized(@{ })
}

$global:repos = @{
    MicrosoftSecurityBulletins  = 15
    MicrosoftSecurityAdvisories = 734
    MicrosoftApplications       = 732
    MicrosoftToolkits           = 733
}

# Register autocompleter script
Register-PSFTeppScriptblock -Name Repository -ScriptBlock { $global:repos.Keys }

# Register the actual auto completer
Register-PSFTeppArgumentCompleter -Command Connect-DisaRepository -Parameter Repository -Name Repository

$PSDefaultParameterValues["Invoke-*:ErrorAction"] = "Stop"
$PSDefaultParameterValues["Invoke-*:UseBasicParsing"] = $true
$PSDefaultParameterValues["Invoke-*:UserAgent"] = ([Microsoft.PowerShell.Commands.PSUserAgent]::InternetExplorer)