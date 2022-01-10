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

    .PARAMETER FilePath
        The filepath of the patch. Not required - if you don't have it, we can grab it from the internet

        Note this does place the hotfix files in your local and remote Downloads directories

    .PARAMETER ArgumentList
        This is an advanced parameter for those of you who need special argumentlists for your platform-specific update.

        The argument list required by SQL updates are already accounted for.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .EXAMPLE
        PS C:\> Install-DisaPatch -ComputerName sql2017 -FilePath C:\temp\windows10.0-kb4534273-x64_74bf76bc5a941bbbd0052caf5c3f956867e1de38.msu

        Installs KB4534273 from the C:\temp directory on sql2017

    .EXAMPLE
        PS C:\> Install-DisaPatch -ComputerName sql2017 -FilePath \\nas\sql\windows10.0-kb4532947-x64_20103b70445e230e5994dc2a89dc639cd5756a66.msu

        Installs KB4534273 from the \\nas\sql\ directory on sql2017

    .EXAMPLE
        PS> $params = @{
            ComputerName = "sql2017"
            FilePath = "C:\temp\sqlserver2017-kb4498951-x64_b143d28a48204eb6ebab62394ce45df53d73f286.exe"
            Verbose = $true
        }
        PS> Install-DisaPatch @params
        PS> Uninstall-DisaPatch -ComputerName sql2017 -HotfixId KB4498951

        Installs KB4498951 on sql2017 then uninstalls it ✔
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
    param (
        [PSFComputer[]]$ComputerName = $env:ComputerName,
        [PSCredential]$Credential,
        [PSCredential]$PSDscRunAsCredential,
        [Alias("Path", "FullName")]
        [ValidateScript( { Test-Path -Path $_ } )]
        [Parameter(ValueFromPipeline, Mandatory)]
        [System.IO.FileInfo]$FilePath,
        [string]$ArgumentList,
        [switch]$EnableException
    )
    process {
        if ($IsLinux -or $IsMacOs) {
            Stop-PSFFunction -Message "This command using remoting and only supports Windows at this time" -EnableException:$EnableException
            return
        }

        foreach ($computer in $ComputerName) {
            Write-PSFMessage -Level Verbose -Message "Processing $computer"
            # null out a couple things to be safe
            $remotehome = $remotesession = $null

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
                    Stop-PSFFunction -EnableException:$EnableException -Message "Session for $computer can't be found or no runspaces are available. Please file an issue on the GitHub repo at https://github.com/potatoqualitee/disarepotools/issues" -Continue
                }
            }

            # See if remote server has xWindowsUpdate installed, if not install it because it'll likely be needed
            # but store the test results in a script variable to prevent it from running over again because it takes 1 second
            if (-not $script:hashotfixmodule[$computer.ComputerName]) {
                $script:hashotfixmodule[$computer.ComputerName] = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
                    if ((Get-Module -ListAvailable xWindowsUpdate).Name) {
                        $true
                    } else {
                        $false
                    }
                }
            }

            if ($script:hashotfixmodule[$computer.ComputerName]) {
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
                    $script:hashotfixmodule["$computer"] = $true
                } catch {
                    Stop-PSFFunction -EnableException:$EnableException -Message "Couldn't auto-install xHotfix on $computer. Please Install-Module xWindowsUpdate on $computer to continue." -Continue
                }
            }

            if (-not $script:installedsoftware["$computer"]) {
                # Get a list of installed software to do comparisons later
                # This takes 1s so store it so that it does't run with each piped in file
                $script:installedsoftware["$computer"] = Get-DisaInstalledSoftware -ComputerName $computer -Credential $Credential
            }

            foreach ($file in $FilePath) {
                $hotfixid = $guid = $null
                $updatefile = Get-ChildItem -Path $file -ErrorAction SilentlyContinue
                $Title = $updatefile.VersionInfo.ProductName
                if ($computer.IsLocalhost) {
                    $remotefile = $updatefile
                } else {
                    $remotefile = "$remotehome\Downloads\$(Split-Path -Leaf $updateFile)"
                }

                # copy over to destination server unless
                # it's local or it's on a network share
                if (-not "$($PSBoundParameters.FilePath)".StartsWith("\\") -and -not $computer.IsLocalhost) {
                    Write-PSFMessage -Level Verbose -Message "Update is not located on a file server and not local, copying over the remote server"
                    try {
                        $exists = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ArgumentList $remotefile -ScriptBlock {
                            Get-ChildItem -Path $args -ErrorAction SilentlyContinue
                        }
                        if (-not $exists) {
                            $null = Copy-Item -Path $updatefile -Destination $remotefile -ToSession $remotesession -ErrorAction Stop
                            $deleteremotefile = $remotefile
                        }
                    } catch {
                        $null = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ArgumentList $remotefile -ScriptBlock {
                            Remove-Item $args -Force -ErrorAction SilentlyContinue
                        }
                        try {
                            Write-PSFMessage -Level Warning -Message "Copy failed, trying again"
                            $null = Copy-Item -Path $updatefile -Destination $remotefile -ToSession $remotesession -ErrorAction Stop
                            $deleteremotefile = $remotefile
                        } catch {
                            $null = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ArgumentList $remotefile -ScriptBlock {
                                Remove-Item $args -Force -ErrorAction SilentlyContinue
                            }
                            Stop-PSFFunction -EnableException:$EnableException -Message "Could not copy $updatefile to $remotefile" -ErrorRecord $PSItem -Continue
                        }
                    }
                } else {
                    Stop-PSFFunction -EnableException:$EnableException -Message "Could not find $HotfixId and no file was specified" -Continue
                }

                # if user doesnt add kb, try to find it for them from the provided filename
                $HotfixId = $file.ToString().ToUpper() -split "\-" | Where-Object { $psitem.Startswith("KB") }

                if ($HotfixId) {
                    Write-PSFMessage -Level Verbose -Message "Hotfix ID found: $HotfixId"
                    $hotfixinstalled = ($script:installedsoftware["$computer"] | Where-Object Name -match $HotfixId).Name
                    if ($hotfixinstalled) {
                        Stop-PSFFunction -EnableException:$EnableException -Message "$hotfixinstalled is already installed on $computer" -Continue
                    }
                }

                if ($file.ToString().EndsWith("exe")) {
                    if (-not $PSBoundParameters.ArgumentList) {
                        if ($file -match "sql") {
                            # kb has already been checked, use generic GUID
                            $guid = "DAADB00F-DAAD-B00F-B00F-DAADB00FB00F"
                            $ArgumentList = "/action=patch /AllInstances /quiet /IAcceptSQLServerLicenseTerms"
                        } else {
                            $ArgumentList = "/install /quiet /notrestart"
                        }
                    }
                }

                # first, if hotfix can be determiend, see if it's been installed
                # If hotfix AND NOT SQL, do hotfix
                # if exe at all, do this below, but

                if (-not $HotfixId -and $file -notmatch "sql") {
                    try {
                        Write-PSFMessage -Level Verbose -Message "Trying to get GUID from $($updatefile.FullName)"
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
                            $index = $files | Where-Object Name -match "none.xml|ParameterInfo.xml" #KB.*.xml|mediainfo.xml|PSFX.*.xml
                        }
                        $temp = Get-PSFPath -Name Temp
                        $indexfilename = $index.Name
                        $xmlfile = Join-Path -Path $temp -ChildPath "$($updatefile.BaseName).xml"
                        $null = $cab.UnpackFile($indexfilename, $xmlfile)
                        $xml = [xml](Get-Content -Path $xmlfile)
                        $tempguid = $xml.BurnManifest.Registration.Id

                        if (-not $tempguid -and $xml.MsiPatch.PatchGUID) {
                            $tempguid = $xml.MsiPatch.PatchGUID
                        }
                        if (-not $tempguid -and $xml.Setup.Items.Patches.MSP.PatchCode) {
                            $tempguid = $xml.Setup.Items.Patches.MSP.PatchCode
                        }

                        Get-ChildItem -Path $xmlfile -ErrorAction SilentlyContinue | Remove-Item -Confirm:$false -ErrorAction SilentlyContinue

                        if (-not $tempguid) {
                            $tempguid = "DAADB00F-DAAD-B00F-B00F-DAADB00FB00F"
                        }

                        $guid = ([guid]$tempguid).Guid
                    } catch {
                        $guid = "DAADB00F-DAAD-B00F-B00F-DAADB00FB00F"
                    }

                    Write-PSFMessage -Level Verbose -Message "GUID is $guid"
                }

                if (-not $HotfixId -and -not $Guid) {
                    Stop-PSFFunction -EnableException:$EnableException -Message "Could not determine KB from $file. Looked for '-kbnumber-'. Please provide a HotfixId." -Continue
                }

                if ($HotfixId -and $updatefile -notmatch 'sql') {
                    Write-PSFMessage -Level Verbose -Message "It's a Hotfix"
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
                    $verbosemessage = "Installing Hotfix $HotfixId from $file"
                } else {
                    Write-PSFMessage -Level Verbose -Message "It's a GUID"
                    $hotfix = @{
                        Name       = 'Package'
                        ModuleName = 'PSDesiredStateConfiguration'
                        Property   = @{
                            Ensure     = 'Present'
                            ProductId  = $guid
                            Name       = $Title
                            Path       = $remotefile
                            Arguments  = $ArgumentList
                            ReturnCode = 0, 3010
                        }
                    }
                    $verbosemessage = "Installing $Title ($Guid) from $file"
                }

                if ($PSCmdlet.ShouldProcess($computer, $verbosemessage)) {
                    try {
                        Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
                            param (
                                $Hotfix,
                                $VerbosePreference,
                                $ManualFileName
                            )
                            $PSDefaultParameterValues['*:ErrorAction'] = 'SilentlyContinue'
                            $ErrorActionPreference = "Stop"

                            $null = Import-Module PSDesiredStateConfiguration -Verbose:$false

                            if (-not (Get-Command Invoke-DscResource)) {
                                throw "Invoke-DscResource not found on $env:ComputerName"
                            }
                            $null = Import-Module xWindowsUpdate -Force -Verbose:$false
                            Write-Verbose -Message "Performing installation of $ManualFileName on $env:ComputerName"
                            try {
                                if (-not (Invoke-DscResource @hotfix -Method Test)) {
                                    $ProgressPreference = 'SilentlyContinue'
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
                        } -ArgumentList $hotfix, $VerbosePreference, $updatefile -ErrorAction Stop


                        if ($deleteremotefile) {
                            Write-PSFMessage -Level Verbose -Message "Deleting $deleteremotefile"
                            $null = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ArgumentList $deleteremotefile -ScriptBlock {
                                Get-ChildItem -ErrorAction SilentlyContinue $args | Remove-Item -Force -ErrorAction SilentlyContinue -Confirm:$false
                            }
                        }

                        Write-Verbose -Message "Finished installing, checking status"
                        $exists = Get-DisaInstalledSoftware -ComputerName $computer -Credential $Credential -Pattern $hotfixid, $guid -IncludeHidden

                        if ($exists.Summary -match "restart") {
                            $status = "This update requires a restart"
                        } else {
                            $status = "Install successful"
                        }
                        if ($guid) {
                            $id = $guid
                        } else {
                            $id = $HotfixId
                        }
                        [pscustomobject]@{
                            ComputerName = $computer
                            Title        = $Title
                            ID           = $id
                            Status       = $Status
                        } | Select-DefaultView -Property ComputerName, Title, Status
                    } catch {
                        if ($deleteremotefile) {
                            Write-PSFMessage -Level Verbose -Message "Deleting $deleteremotefile"
                            $null = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ArgumentList $deleteremotefile -ScriptBlock {
                                Get-ChildItem -ErrorAction SilentlyContinue $args | Remove-Item -Force -ErrorAction SilentlyContinue
                            }
                        }

                        if ("$PSItem" -match "Serialized XML is nested too deeply") {
                            Write-PSFMessage -Level Verbose -Message "Serialized XML is nested too deeply. Forcing output."
                            $exists = Get-DisaInstalledSoftware -ComputerName $computer -Credential $credential -HotfixId $hotfix.property.id

                            if ($exists) {
                                [pscustomobject]@{
                                    ComputerName = $computer
                                    Title        = $Title
                                    Id           = $id
                                    Status       = "Successfully installed. A restart is now required."
                                } | Select-DefaultView -Property ComputerName, Title, Status
                            } else {
                                Stop-PSFFunction -Message "Failure on $computer" -ErrorRecord $_ -EnableException:$EnableException -Continue
                            }
                        } else {
                            Stop-PSFFunction -Message "Failure on $computer" -ErrorRecord $_ -EnableException:$EnableException -Continue
                        }
                    }
                }
            }
        }
    }
}