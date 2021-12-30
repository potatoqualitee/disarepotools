# requires 5
function Install-DisaPatch {
    <#
    .SYNOPSIS
        Installs KBs on local and remote servers on Windows-based systems

    .DESCRIPTION
        Installs KBs on local and remote servers on Windows-based systems

        PowerShell 5.1 must be installed and enabled on the target machine and the target machine must be Windows-based

        Note that if you use a DSC Pull server, this may impact your LCM

    .PARAMETER ComputerName
        Used to connect to a remote host

    .PARAMETER Credential
        The optional alternative credential to be used when connecting to ComputerName

    .PARAMETER PSDscRunAsCredential
        Run the install as a specific user (other than SYSTEM) on the target node

    .PARAMETER HotfixId
        The HotfixId of the patch

    .PARAMETER FilePath
        The filepath of the patch. Not required - if you don't have it, we can grab it from the internet

        Note this does place the hotfix files in your local and remote Downloads directories

    .PARAMETER Guid
        If the file is an exe and no GUID is specified, we will have to get it from Get-DisaUpdate

    .PARAMETER Title
        If the file is an exe and no Title is specified, we will have to get it from Get-DisaUpdate

    .PARAMETER ArgumentList
        This is an advanced parameter for those of you who need special argumentlists for your platform-specific update.

        The argument list required by SQL updates are already accounted for.

    .PARAMETER InputObject
        Allows infos to be piped in from Get-DisaUpdate

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Author: Jess Pomfret (@jpomfret), Chrissy LeMaire (@cl)
        Copyright: (c) licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

    .EXAMPLE
        PS C:\> Install-DisaPatch -ComputerName sql2017 -FilePath C:\temp\windows10.0-kb4534273-x64_74bf76bc5a941bbbd0052caf5c3f956867e1de38.msu

        Installs KB4534273 from the C:\temp directory on sql2017

    .EXAMPLE
        PS C:\> Install-DisaPatch -ComputerName sql2017 -FilePath \\dc\sql\windows10.0-kb4532947-x64_20103b70445e230e5994dc2a89dc639cd5756a66.msu

        Installs KB4534273 from the \\dc\sql\ directory on sql2017

    .EXAMPLE
        PS C:\> Install-DisaPatch -ComputerName sql2017 -HotfixId kb4486129

        Downloads an update, stores it in Downloads and installs it from there

    .EXAMPLE
        PS C:\> $params = @{
            ComputerName = "sql2017"
            FilePath = "C:\temp\sqlserver2017-kb4498951-x64_b143d28a48204eb6ebab62394ce45df53d73f286.exe"
            Verbose = $true
        }
        PS C:\> Install-DisaPatch @params
        PS C:\> Uninstall-DisaPatch -ComputerName sql2017 -HotfixId KB4498951

        Installs KB4498951 on sql2017 then uninstalls it ✔
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
    param (
        [PSFComputer[]]$ComputerName = $env:ComputerName,
        [PSCredential]$Credential,
        [PSCredential]$PSDscRunAsCredential,
        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias("Name", "KBUpdate", "Id")]
        [string]$HotfixId,
        [Alias("Path", "FullName")]
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$FilePath,
        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias("UpdateId")]
        [string]$Guid,
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Title,
        [string]$ArgumentList,
        [switch]$EnableException
    )
    process {
        if (-not $PSBoundParameters.HotfixId -and -not $PSBoundParameters.FilePath -and -not $PSBoundParameters.InputObject) {
            Stop-PSFFunction -EnableException:$EnableException -Message "You must specify either HotfixId or FilePath or pipe in the results from Get-DisaUpdate"
            return
        }

        if ($IsLinux -or $IsMacOs) {
            Stop-PSFFunction -Message "This command using remoting and only supports Windows at this time" -EnableException:$EnableException
            return
        }

        if (-not $HotfixId.ToUpper().StartsWith("KB") -and $PSBoundParameters.HotfixId) {
            $HotfixId = "KB$HotfixId"
        }

        foreach ($computer in $ComputerName) {
            Write-PSFMessage -Level Verbose -Message "Processing $computer"
            # null out a couple things to be safe
            $remotefileexists = $remotehome = $remotesession = $null

            if (-not $computer.IsLocalhost) {
                # a lot of the file copy work will be done in the remote $home dir
                $remotehome = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock { $home }
                Write-PSFMessage -Level Verbose -Message "Remote home: $remotehome"
                if (-not $remotesession) {
                    $remotesession = Get-PSSession -ComputerName $computer | Where-Object { $PsItem.Availability -eq 'Available' -and ($PsItem.Name -match 'WinRM' -or $PsItem.Name -match 'Runspace') } | Select-Object -First 1
                }

                if (-not $remotesession) {
                    $remotesession = Get-PSSession -ComputerName $computer | Where-Object { $PsItem.Availability -eq 'Available' } | Select-Object -First 1
                }

                if (-not $remotesession) {
                    Stop-PSFFunction -EnableException:$EnableException -Message "Session for $computer can't be found or no runspaces are available. Please file an issue on the GitHub repo at https://github.com/potatoqualitee/kbupdate/issues" -Continue
                }
            }

            $hasxhotfixmodule = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
                Get-Module -ListAvailable xWindowsUpdate
            }

            if ($hasxhotfixmodule) {
                Write-PSFMessage -Level Verbose -Message "xWindowsUpdate found on $computer"
            } else {
                Write-PSFMessage -Level Verbose -Message "xWindowsUpdate not found on $computer, attempting to install it"
                try {
                    # Copy xWindowsUpdate to Program Files. The module is pretty much required to be in the PS Modules directory.
                    $oldpref = $ProgressPreference
                    $ProgressPreference = "SilentlyContinue"
                    $programfiles = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ArgumentList "$env:ProgramFiles\WindowsPowerShell\Modules" -ScriptBlock {
                        $env:ProgramFiles
                    }
                    $null = Copy-Item -Path "$script:ModuleRoot\library\xWindowsUpdate" -Destination "$programfiles\WindowsPowerShell\Modules\xWindowsUpdate" -ToSession $remotesession -Recurse -Force
                    $ProgressPreference = $oldpref

                    Write-PSFMessage -Level Verbose -Message "xWindowsUpdate installed successfully on $computer"
                } catch {
                    Stop-PSFFunction -EnableException:$EnableException -Message "Couldn't auto-install xHotfix on $computer. Please Install-Module xWindowsUpdate on $computer to continue." -Continue
                }
            }

            foreach ($file in $FilePath) {
                $updatefile = Get-ChildItem -Path $file -ErrorAction SilentlyContinue
                if ($computer.IsLocalhost) {
                    $remotefile = $updatefile
                } else {
                    $remotefile = "$remotehome\Downloads\$(Split-Path -Leaf $updateFile)"
                }

                # ignore if it's on a file server
                if (-not "$($PSBoundParameters.FilePath)".StartsWith("\\") -and -not $computer.IsLocalhost) {
                    Write-PSFMessage -Level Verbose -Message "Not on file server"
                    try {
                        $exists = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ArgumentList $remotefile -ScriptBlock {
                            Get-ChildItem -Path $args -ErrorAction SilentlyContinue
                        }
                        if (-not $exists) {
                            $null = Copy-Item -Path $updatefile -Destination $remotefile -ToSession $remotesession -ErrorAction Stop
                        }
                    } catch {
                        $null = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ArgumentList $file -ScriptBlock {
                            Remove-Item $args -Force -ErrorAction SilentlyContinue
                        }
                        Stop-PSFFunction -EnableException:$EnableException -Message "Could not copy $updatefile to $file and no file was specified" -Continue
                    }
                } else {
                    Stop-PSFFunction -EnableException:$EnableException -Message "Could not find $HotfixId and no file was specified" -Continue
                }

                Write-PSFMessage -Level Verbose -Message "Moving on"
                if ($file.EndsWith("exe")) {
                    if (-not $ArgumentList) {
                        if ($file -match "sql") {
                            $ArgumentList = "/action=patch /AllInstances /quiet /IAcceptSQLServerLicenseTerms"
                        } else {
                            $ArgumentList = "/install /quiet /notrestart"
                        }
                    }

                    if (-not $Guid) {
                        if ($InputObject) {
                            $Guid = $PSBoundParameters.InputObject.Guid
                            $Title = $PSBoundParameters.InputObject.Title
                        } else {
                            try {
                                Write-PSFMessage -Level Verbose -Message "Guid not specifying, getting it from $($updatefile.FullName)"
                                <#
                                    It's better to just read from memory but I can't get this to work
                                    $cab = New-Object Microsoft.Deployment.Compression.Cab.Cabinfo "C:\path\path.exe"
                                    $file = New-Object Microsoft.Deployment.Compression.Cab.CabFileInfo($cab, "0")
                                    $content = $file.OpenRead()
                                #>
                                $cab = New-Object Microsoft.Deployment.Compression.Cab.Cabinfo $updatefile.FullName
                                $files = $cab.GetFiles("*")
                                $index = $files | Where-Object Name -eq 0
                                if (-not $index) {
                                    $index = $files | Where-Object Name -match "KB.*.xml|PSFX.*.xml|ParameterInfo.xml|mediainfo.xml|none.xml"
                                }
                                if (-not $index) {
                                    Stop-PSFFunction -EnableException:$EnableException -Message "Could not figure out the type of patch:  $updatefile"
                                    return
                                }
                                $temp = Get-PSFPath -Name Temp
                                $indexfilename = $index.Name
                                $xmlfile = Join-Path -Path $temp -ChildPath "$($updatefile.BaseName).xml"
                                $null = $cab.UnpackFile($indexfilename, $xmlfile)
                                $xml = [xml](Get-Content -Path $xmlfile)
                                $tempguid = $xml.BurnManifest.Registration.Id
                                if (-not $tempguid -and $xml.MediaInfo.Properties.Property) {
                                    $tempkb = ($xml.MediaInfo.Properties.Property | Where-Object Id -eq KBNumber).Value
                                    $tempguid = "KB$tempkb"
                                }
                                $Guid = ([guid]$tempguid).Guid
                                $Title = (Get-Item $updatefile).VersionInfo.ProductName
                                Get-ChildItem -Path $xmlfile -ErrorAction SilentlyContinue | Remove-Item -Confirm:$false -ErrorAction SilentlyContinue
                            } catch {
                                Stop-PSFFunction -EnableException:$EnableException -Message "Could not determine Guid from $file. Please provide a Guid." -ErrorRecord $PSItem
                                return
                            }
                        }
                    }

                    # this takes care of things like SQL Server updates

                    $hotfix = @{
                        Name       = 'Package'
                        ModuleName = 'PSDesiredStateConfiguration'
                        Property   = @{
                            Ensure     = 'Present'
                            ProductId  = $Guid
                            Name       = $Title
                            Path       = $remotefile
                            Arguments  = $ArgumentList
                            ReturnCode = 0, 3010
                        }
                    }
                } else {
                    # if user doesnt add kb, try to find it for them from the provided filename
                    if (-not $PSBoundParameters.HotfixId) {
                        $HotfixId = $file.ToUpper() -split "\-" | Where-Object { $psitem.Startswith("KB") }
                        if (-not $HotfixId) {
                            Stop-PSFFunction -EnableException:$EnableException -Message "Could not determine KB from $file. Looked for '-kbnumber-'. Please provide a HotfixId."
                            return
                        }
                    }

                    # this takes care of WSU files
                    $hotfix = @{
                        Name       = 'xHotFix'
                        ModuleName = 'xWindowsUpdate'
                        Property   = @{
                            Ensure = 'Present'
                            Id     = $HotfixId
                            Path   = $remotefile
                        }
                    }
                    if ($PSDscRunAsCredential) {
                        $hotfix.Property.PSDscRunAsCredential = $PSDscRunAsCredential
                    }
                    $Title = $HotfixId
                }

                if ($PSCmdlet.ShouldProcess($computer, "Installing Hotfix $HotfixId from $file")) {
                    try {
                        Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
                            param (
                                $Hotfix,
                                $VerbosePreference,
                                $ManualFileName
                            )
                            $PSDefaultParameterValues['*:ErrorAction'] = 'SilentlyContinue'
                            $ErrorActionPreference = "Stop"

                            if (-not (Get-Command Invoke-DscResource)) {
                                throw "Invoke-DscResource not found on $env:ComputerName"
                            }
                            $null = Import-Module xWindowsUpdate -Force
                            Write-Verbose -Message "Installing $($hotfix.property.id) from $($hotfix.property.path)"
                            try {
                                if (-not (Invoke-DscResource @hotfix -Method Test)) {
                                    Invoke-DscResource @hotfix -Method Set -ErrorAction Stop
                                }
                            } catch {
                                switch ($message = "$_") {
                                    # some things can be ignored
                                    { $message -match "Serialized XML is nested too deeply" -or $message -match "Name does not match package details" } {
                                        $null = 1
                                    }
                                    { $message -match "2359302" } {
                                        throw "Error 2359302: update is already installed on $env:ComputerName"
                                    }
                                    { $message -match "2042429437" } {
                                        throw "Error -2042429437. Configuration is likely not correct. The requested features may not be installed or features are already at a higher patch level."
                                    }
                                    { $message -match "2068709375" } {
                                        throw "Error -2068709375. The exit code suggests that something is corrupt. See if this tutorial helps: http://www.sqlcoffee.com/Tips0026.htm"
                                    }
                                    { $message -match "2067919934" } {
                                        throw "Error -2067919934 You likely need to reboot $env:ComputerName."
                                    }
                                    { $message -match "2147942402" } {
                                        throw "System can't find the file specified for some reason."
                                    }
                                    default {
                                        throw
                                    }
                                }
                            }
                        } -ArgumentList $hotfix, $VerbosePreference, $PSBoundParameters.FileName -ErrorAction Stop

                        Write-Verbose -Message "Finished installing, checking status"
                        $exists = Get-DisaInstalledSoftware -ComputerName $computer -Credential $Credential -Pattern $hotfix.property.id -IncludeHidden

                        if ($exists.Summary -match "restart") {
                            $status = "This update requires a restart"
                        } else {
                            $status = "Install successful"
                        }

                        [pscustomobject]@{
                            ComputerName = $computer
                            Title        = $Title
                            ID           = $Guid
                            Status       = $Status
                        }
                    } catch {
                        if ("$PSItem" -match "Serialized XML is nested too deeply") {
                            Write-PSFMessage -Level Verbose -Message "Serialized XML is nested too deeply. Forcing output."
                            $exists = Get-DisaInstalledSoftware -ComputerName $computer -Credential $credential -HotfixId $hotfix.property.id

                            if ($exists) {
                                [pscustomobject]@{
                                    ComputerName = $computer
                                    Title        = $Title
                                    Id           = $HotfixId
                                    Status       = "Successfully installed. A restart is now required."
                                }
                            } else {
                                Stop-PSFFunction -Message "Failure on $computer" -ErrorRecord $_ -EnableException:$EnableException
                            }
                        } else {
                            Stop-PSFFunction -Message "Failure on $computer" -ErrorRecord $_ -EnableException:$EnableException
                        }
                    }
                }
            }
        }
    }
}