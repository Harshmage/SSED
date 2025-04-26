<#
Silverlock Script Extender Downloader

The Silverlock Team builds script extensions for Bethesda games, expanding the modding capability said games.
Currently supports:
    Fallout 3 (FOSE)
    Fallout: New Vegas (NVSE)
    Fallout 4 (F4SE)
		Supports Fallout: London and the version rollback
	Fallout 76 (only the SFE tool for Text Chat and Perk Loader mods) (F76SFE)
    Skyrim Special/Anniversary Edition (SKSE64)
        GOG version needs validation
    Skyrim Original Edition (No Longer Updated!) (SKSE)
    Skyrim VR (SKSEVR)
    Oblivion (OBSE)
	Oblivion Remastered (OBSE64)
    Morrowind (MWSE)
    Starfield (SFSE)

Nexusmods API Reference: https://app.swaggerhub.com/apis-docs/NexusMods/nexus-mods_public_api_params_in_form_data/1.0#/
Nexusmods API AUP: https://help.nexusmods.com/article/114-api-acceptable-use-policy

Checks matching Silverlock SE page for latest file version against locally installed
Updates if available
Runs if flag set

Parameters:
    -SEGame <designation> (four character game designation on silverlock.org)
    -RunGame <true/false> (string, default false)
    -dlkeep <true/false> (string, default false)
    -hardpath (string, file path to game folder)
    -nexusAPI (string, generated from https://www.nexusmods.com/users/myaccount?tab=api)

Usage:
    se-downloader.ps1 -SEGame F4SE -RunGame true
        Checks game for Fallout 4 Script Extender, and launches the game when completed
    se-downloader.ps1 -SEGame FOSE -hardpath "G:\FO3GOTY"
        Checks game for Fallout 3 with a direct install path
    se-downloader.ps1 -SEGame SKSE64
        Checks game for Skyrim Special Edition Script Extender
    se-downloader.ps1 -SEGame F76SFE -dlkeep true -nexusAPI "NexusMods API Key"
        Checks game for Fallout 76 SFE, an overlay DLL for Text Chat, requires NexusMods API Key, and does not delete the extracted download

#>

param(
    [Parameter()]
    [ValidateSet("FOSE","NVSE","F4SE","F76SFE","OBSE","OBSE64","SKSE","SKSE64","SKSEVR","MWSE","SFSE")]
	[string]$SEGame,
	
	[Parameter()]
	[ValidateSet("true","false")]
    [string]$RunGame = "false",
	
	[Parameter()]
	[ValidateSet("true", "false")]
    [string]$dlkeep = "false",

    [Parameter()]
    [string]$hardpath,

    [Parameter()]
    [string]$nexusAPI = (Get-Content "..\nexus.api") # NexusMods API Key (https://www.nexusmods.com/users/myaccount?tab=api)
)

# For Debug

$SEGame = "OBSE64"
$RunGame = $false 
# For Debug

#$SEGame = "F4SE"
#$RunGame = $false 
#$dlkeep = $true

# Convert string to boolean
$RunGame = [System.Convert]::ToBoolean($RunGame)
$dlkeep = [System.Convert]::ToBoolean($dlkeep)

Function Get-GamePath {
	# Get the Install Path from the uninstall registry
	If (($hardpath.Length -gt 4) -and (Test-path $hardpath)) {
		$global:gamepath = $hardpath
	} Else {
		Try {
			$global:gamepath = get-childitem -recurse HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall | get-itemproperty | Where-Object { $_  -match $GameName } | Select-object -expandproperty InstallLocation
			Test-path $gamepath
		} Catch {
			Write-Error -Message "Unable to find installation directory for $GameName"
			break
		}
	}
}

Function Get-NexusMods {
	[CmdletBinding()]
	Param (
		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[ValidateNotNullOrEmpty()]
		[Alias("modID")]
		[string]$nexusmodID,
		
		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[ValidateNotNullOrEmpty()]
		[Alias("gameID")]
		[string]$nexusgameID,
		
		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$nexusfileindex
	)
	
	If ($nexusAPI -eq "") { Write-Log -Level Error -Message "Nexus API Key is empty"; Exit 1 }
	$nexusHeaders = @{
        "Accept"="application/json"
        "apikey"="$nexusAPI"
    }
    $global:url = "https://api.nexusmods.com"
    Try {
        $global:WebResponse = (Invoke-WebRequest "https://api.nexusmods.com/v1/games/$nexusgameID/mods/$nexusmodID/files.json" -Headers $nexusHeaders -UseBasicParsing).Content | ConvertFrom-Json | Select-Object -Property @{L='files';E={$_.files[$nexusfileindex]}}
        $global:json = $WebResponse.files
        $global:latestfileid = $json.file_id[0]
        $global:dlResponse = (Invoke-WebRequest "https://api.nexusmods.com/v1/games/$nexusgameID/mods/$nexusmodID/files/$latestfileid/download_link.json" -Headers $nexusHeaders).Content | ConvertFrom-Json | Select-Object -Property @{L='URI';E={$_.URI[0]}}
        $global:dl = [PSCustomObject]@{
            ver = [System.Version]::Parse("0.$($json.version)")
            url = $dlResponse.URI
            file = $json.file_name
            nexusver = $json.version
        }
        $global:subfolder = ($dl.file).Replace('.7z','') # f4se_0_06_20
    } Catch {
		Write-Log -Level Error -Message "Unable to access NexusMods API"
		Write-Log -Level Error -Message "$($Error[0].Exception.Message)"
		Write-Log -Level Error -Message "API Key: $nexusAPI"
		Write-Log -Level Error -Message "Game: $GameName"
		Write-Log -Level Error -Message "Mod ID: $nexusmodID"
        $global:halt = $true
    }
}

function Write-Log { 
    [CmdletBinding()] 
    Param ( 
        [Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()] 
        [Alias("LogContent")] 
        [string]$Message, 
 
        [Parameter(Mandatory=$false)] 
        [Alias('LogPath')] 
        [string]$Path="$gamepath\$($SEGame)-Updater.log", 
         
        [Parameter(Mandatory=$false)] 
        [ValidateSet("Error","Warn","Info","Debug")] 
        [string]$Level="Info", 
         
        [Parameter(Mandatory=$false)] 
        [switch]$NoClobber 
    ) 
 
    Begin { 
        # Set VerbosePreference to Continue so that verbose messages are displayed. 
        $VerbosePreference = 'Continue' 
    } 
    Process { 
        # If the file already exists and NoClobber was specified, do not write to the log. 
        if ((Test-Path $Path) -AND $NoClobber) { 
            Write-Error "Log file $Path already exists, and you specified NoClobber. Either delete the file or specify a different name." 
            Return 
        } elseif (!(Test-Path $Path)) { # If attempting to write to a log file in a folder/path that doesn't exist create the file including the path. 
            Write-Verbose "Creating $Path." 
            New-Item $Path -Force -ItemType File 
        } else { 
            # Nothing to see here yet. 
        }
        # Format Date for our Log File 
        $FormattedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss" 
        # Write message to error, warning, or verbose pipeline and specify $LevelText 
        switch ($Level) { 
            'Error' { 
                Write-Error $Message 
                $LevelText = 'ERROR:' 
            }
            'Warn' { 
                Write-Warning $Message 
                $LevelText = 'WARNING:' 
            }
            'Info' { 
                Write-Verbose $Message 
                $LevelText = 'INFO:'
			}
			'Debug' {
				Write-Verbose $Message
				$LevelText = 'DEBUG:'
			}
		}
		# Write log entry to $Path 
        "$FormattedDate $LevelText $Message" | Out-File -FilePath $Path -Append
        Write-Host "$FormattedDate $LevelText $Message"
        "$FormattedDate $LevelText $Message" | Out-File -FilePath $Path -Append
        Write-Host "$FormattedDate $LevelText $Message"
    }
}

$NexusAPIRquired = @("F76SFE", "OBSE64", "SFSE", "SKSEVR", "SKSE", "FOSE", "MWSE")
If ($SEGame -in $NexusAPIRquired) {
	If (-not $nexusAPI) {
		Write-Log -Level Error -Message "NexusMods SSED API key is required for $SEGame, visit https://next.nexusmods.com/settings/api-keys#:~:text=Silverlock%20Script%20Extender%20Downloader to acquire one!"
		Exit 1
	}
}

# Test for 7-Zip x64 path, fail if not found
If (!(Test-Path $env:ProgramFiles\7-Zip\7z.exe)) {
    Write-Log -Message "7-Zip x64 Path Not Found!" -Level Error
    Start-Process msedge -PassThru "https://www.7-zip.org/download.html"
    Exit
}

# Set some variables
$url = "https://$($SEGame).silverlock.org/"
$rtype = "beta" # Release Type, Beta or Download



# Build the primary game and DLL variables
If ($SEGame -eq "SKSE64") {
	$GameName = "Skyrim Special Edition"
	Get-GamePath
	$gog = ($gamepath -notmatch "steamapps") # Identify if not using Steam for the install path, assume its GOG, as the Epic Store install is officially unsupported
	$url = "https://api.github.com/repos/ianpatt/$($SEGame)/releases"
	$WebResponse = Invoke-WebRequest $url -Headers @{ "Accept" = "application/json" } -UseBasicParsing
	$json = $WebResponse.Content | ConvertFrom-Json
	$json = $json[0]
	$dl = [PSCustomObject]@{
		ver = [System.Version]::Parse("0." + ($json.tag_name).Replace("v", "")) # 0. + 5.1.6 = 0.5.1.6
		url = If ($gog) { $json.assets.browser_download_url | Where-Object { $_ -match "gog" } } Else { $json.assets.browser_download_url | Where-Object { $_ -notmatch "gog" } } # https://github.com/xNVSE/NVSE/releases/download/5.1.6/nvse_5_1_beta6.7z
		file = If ($gog) { $json.assets.name | Where-Object { $_ -match "gog" } } Else { $json.assets.name | Where-Object { $_ -notmatch "gog" } } # nvse_5_1_beta6.7z
	}
	$subfolder = ($dl.file).Replace('.7z', '') # f4se_0_06_20
} ElseIf ($SEGame -eq "SKSEVR") {
	# TODO Need to validate
	If ($nexusAPI -eq "") { Write-Log -Level Error -Message "Nexus API Key is empty"; Exit }
	$GameName = "Skyrim VR"
	Get-NexusMods -nexusmodID "30457" -nexusgameID "skyrimspecialedition" -nexusfileindex "0"
} ElseIf ($SEGame -eq "SKSE") {
	# TODO Need to validate
	$GameName = "Skyrim"
	Get-NexusMods -nexusmodID "100216" -nexusgameID "skyrim" -nexusfileindex "0"
} ElseIf ($SEGame -eq "OBSE") {
	# TODO Need to validate
	$GameName = "Oblivion"
	$url = "https://api.github.com/repos/llde/xOBSE/releases"
	$WebResponse = Invoke-WebRequest $url -Headers @{ "Accept" = "application/json" } -UseBasicParsing
	$json = $WebResponse.Content | ConvertFrom-Json
	$json = $json[0]
	$dl = [PSCustomObject]@{
		ver = [System.Version]::Parse("0." + ($json.tag_name).Replace("v", "") + ".0") # 0. + 5.1.6 = 0.5.1.6
		url = $json.assets.browser_download_url # https://github.com/xNVSE/NVSE/releases/download/5.1.6/nvse_5_1_beta6.7z
		file = $json.assets.name # nvse_5_1_beta6.7z
	}
	$subfolder = ($dl.file).Replace('.7z', '') # f4se_0_06_20
} ElseIf ($SEGame -eq "OBSE64") {
	$GameName = "Oblivion Remastered"
	Get-NexusMods -nexusmodID "282" -nexusgameID "oblivionremastered" -nexusfileindex "0"
} ElseIf ($SEGame -eq "F4SE") {
	$GameName = "Fallout4"
	# 20240718 - Adding new code to check the game version and determine the correct F4SE version to download due to the overhaul patch in April 2024
	# This is going to be weird for a while, until ianpatt adds the 0.7.2 release to the Github repo (currently only available on NexusMods)
	# Also this is in prep for Fallout: London, which will only work with the pre-overhaul patch version of Fallout 4
	Get-GamePath
	$currentGameVer = (Get-Item "$gamepath\Fallout4.exe").VersionInfo.FileVersion
	If ($currentGameVer -eq "1.10.163.0") {
		# game version 1.10.163.0 is pre-overhaul patch, and uses F4SE 0.6.23
		$url = "https://api.github.com/repos/ianpatt/$($SEGame)/releases"
		$WebResponse = Invoke-WebRequest $url -Headers @{ "Accept" = "application/json" } -UseBasicParsing
		$json = $WebResponse.Content | ConvertFrom-Json
		$json = $json | Where-Object { $_.assets.name -eq "f4se_0_06_23.7z" }
		$dl = [PSCustomObject]@{
			ver = [System.Version]::Parse("0." + ($json.tag_name).Replace("v", "")) # 0. + 5.1.6 = 0.5.1.6
			url = $json.assets.browser_download_url # https://github.com/xNVSE/NVSE/releases/download/5.1.6/nvse_5_1_beta6.7z
			file = $json.assets.name # nvse_5_1_beta6.7z
		}
		$subfolder = ($dl.file).Replace('.7z', '') # f4se_0_06_20
	} Else {
		# otherwise assume the game is post-overhaul patch, and uses F4SE 0.7.2+ from NexusMods
		Get-NexusMods -nexusmodID "42147" -nexusgameID "fallout4" -nexusfileindex "-1"
	}
} ElseIf ($SEGame -eq "F76SFE") {
	$GameName = "Fallout76"
	Get-NexusMods -nexusmodID "287" -nexusgameID "fallout76" -nexusfileindex "-1"
	# And because SFE isn't exactly standard, we have to do some extra parsing.
	Get-GamePath
	If (Test-Path "$gamepath\dxgi.dll") {
		$currentSE = (Get-Item "$gamepath\dxgi.dll").VersionInfo.FileVersion # 0, 0, 6, 20
		If ($currentSE -is [System.Array]) { $currentSE = $currentSE[0] }
		$currentSE = [System.Version]::Parse($currentSE.Replace(', ', '.'))
	} Else {
		$currentSE = [System.Version]::Parse("0.0.0.0") # Means you don't have it
	}
	$subfolder = ($dl.file).Replace('.7z', '')
	$useSubfolder = $true
} ElseIf ($SEGame -eq "NVSE") {
	$GameName = "Fallout New Vegas"
	# NVSE went to a community Github in May 2020
	# https://github.com/xNVSE/NVSE
	$url = "https://api.github.com/repos/xNVSE/$($SEGame)/releases"
	$WebResponse = Invoke-WebRequest $url -Headers @{ "Accept" = "application/json" }
	$json = $WebResponse.Content | ConvertFrom-Json
	$json = $json[0]
	$dl = [PSCustomObject]@{
		ver = [System.Version]::Parse("0." + $json.tag_name)
		url = $json.assets.browser_download_url
		file = $json.assets.name
	}
	$subfolder = ($dl.file).Replace('.7z', '') # nvse_5_1_beta6
	$useSubfolder = $true
} ElseIf ($SEGame -eq "FOSE") {
	# https://www.nexusmods.com/fallout3/mods/8606
	$GameName = "Fallout 3"
	Get-NexusMods -nexusmodID "8606" -nexusgameID "fallout3" -nexusfileindex "-1"
	# FOSE in a post-GFWL has a tag of -newloader, need to trim that off to work properly.
	$global:dl = [PSCustomObject]@{
		ver = [System.Version]::Parse("0.$(($json.version).Replace('-newloader', ''))")
		url = $dlResponse.URI
		file = $json.file_name
	}
	$subfolder = ($dl.file).Replace('.7z', '') # nvse_5_1_beta6
} ElseIf ($SEGame -eq "MWSE") {
	# TODO Need to validate
	$GameName = "Morrowind"
	Get-NexusMods -nexusmodID "45468" -nexusgameID "morrowind" -nexusfileindex "-1"
} ElseIf ($SEGame -eq "SFSE") {
	$GameName = "Starfield"
	Get-NexusMods -nexusmodID "106" -nexusgameID "starfield" -nexusfileindex "-1"
	$subfolder = "$($SEGame.ToLower())_$($dl.nexusver.Replace('.', '_'))"
}

If (!($halt)) {
    If ($null -eq $gamepath) { Get-GamePath }

    #### If a silverlock.org url, use this section to build out version validation ####
    If ($url -match "silverlock.org") {
        # Get the latest 7-Zip file
        Try { 
            $WebResponse = Invoke-WebRequest $url
        } Catch {
            Write-Log -Message "Unable to access URL: $url" -Level Error
            Exit
        }
        $target = ($WebResponse.Links | Where-Object {$_.href -Like "*$rtype/$($SEGame)_*.7z"}).href
        #$target = $target.href
        If ($target -match $url) { $target = $target -Replace "$url","" }
        If ($target -match "./$($rtype)*") { $target = $target.Replace('./','') }
        $dlurl = $url + $target
        $file = ($target).Replace("$($rtype)/","") # f4se_0_06_20.7z
        $subfolder = ($file).Replace('.7z','') # f4se_0_06_20
        # Get version info from file name
        $SEGameString = $SEGame + '_'
        $dlver = $subfolder.Replace($SEGameString.ToLower(),'') # 0_06_20
        If ($SEGame -eq "SKSE64") { $dlver = $dlver.Replace('00','0') ; $dlver = "0." + $dlver } # SKSE64 currently reads as 2.00.17, fixes to 0.2.0.17
        $dlver = $dlver.Replace('_','.') # 0.06.20
        If (($SEGame -eq "FOSE") -or ($SEGame -eq "NVSE")) {
            If ($dlver -match 'v') { $dlver = $dlver.Replace('v','')}
            If ($dlver -match 'beta') { $dlver = $dlver -Replace '.beta\w','' }
            If ($dlver.Count -lt 5 ) {$dlver = "0." + $dlver + ".0"}
        } ElseIf ($dlver -notlike "*.*.*.*") {
            $dlver = $dlver.Insert(3,'.') # 0.0.6.20
        }
        $dlver = [System.Version]::Parse($dlver)
    #### If a silverlock.org url, use this section to build out version validation ####
    If ($url -match "silverlock.org") {
        # Get the latest 7-Zip file
        Try { 
            $WebResponse = Invoke-WebRequest $url
        } Catch {
            Write-Log -Message "Unable to access URL: $url" -Level Error
            Exit
        }
        $target = $WebResponse.Links | Where-Object {$_.href -Like "*$rtype/$($SEGame)_*.7z"}
        $target = $target.href
        If ($target -match $url) { $target = $target -Replace "$url","" }
        If ($target -match "./$($rtype)*") { $target = $target.Replace('./','') }
        $dlurl = $url + $target
        $file = ($target).Replace("$($rtype)/","") # f4se_0_06_20.7z
        $subfolder = ($file).Replace('.7z','') # f4se_0_06_20
        # Get version info from file name
        $SEGameString = $SEGame + '_'
        $dlver = $subfolder.Replace($SEGameString.ToLower(),'') # 0_06_20
        If ($SEGame -eq "SKSE64") { $dlver = $dlver.Replace('00','0') ; $dlver = "0." + $dlver } # SKSE64 currently reads as 2.00.17, fixes to 0.2.0.17
        $dlver = $dlver.Replace('_','.') # 0.06.20
        If (($SEGame -eq "FOSE") -or ($SEGame -eq "NVSE")) {
            If ($dlver -match 'v') { $dlver = $dlver.Replace('v','')}
            If ($dlver -match 'beta') { $dlver = $dlver -Replace '.beta\w','' }
            If ($dlver.Count -lt 5 ) {$dlver = "0." + $dlver + ".0"}
        } ElseIf ($dlver -notlike "*.*.*.*") {
            $dlver = $dlver.Insert(3,'.') # 0.0.6.20
        }
        $dlver = [System.Version]::Parse($dlver)

        $dl = [PSCustomObject]@{
            ver = $dlver
            url = $dlurl
            file = $file
        }
    }
        $dl = [PSCustomObject]@{
            ver = $dlver
            url = $dlurl
            file = $file
        }
    }

    # Get current install version
    Try { 
        If ($null -eq $currentSE) {
            $currentSE = Get-Item "$gamepath\$($SEGame.ToLower())_*.dll" -Exclude "$($SEGame)_steam_loader.dll","$($SEGame.ToLower())_editor*.dll" # f4se_1_10_163.dll
            $currentSE = (Get-Item $currentSE).VersionInfo.FileVersion # 0, 0, 6, 20
            If ($currentSE -is [System.Array]) { $currentSE = $currentSE[0] }
            $currentSE = $currentSE.Replace(', ','.') # 0.0.6.20
            $currentSE = [System.Version]::Parse($currentSE)
        }
    } Catch {
        $currentSE = [System.Version]::Parse("0.0.0.0") # Means you don't have it
    }
    # Compare versions, download if source is newer
    If ($dl.ver -gt $currentSE) {
        Write-Log -Message "Source version ($($dl.ver)) is higher than Local version ($currentSE)" -Level Warn
        Write-Log -Message "Downloading Source version ($($dl.url))" -Level Info
        Invoke-WebRequest $dl.url -OutFile "$env:USERPROFILE\Downloads\$($dl.file)"
        # Cleanup Fallout 4 directory of older F4SE components
        Write-Log -Message "Cleaning up older Local $($SEGame) files" -Level Info
        Get-ChildItem -Path "$gamepath\$($SEGame)*" -Exclude "$SEGame-Updater.log" | Remove-Item -Force
        # Extract F4SE to the Fallout 4 folder (f4path\f4se_x_xx_xx)
        Write-Log -Message "Extracting Source $($SEGame) files ($($dl.file) to $($gamepath))" -Level Info
        $file = $dl.file
        If ($useSubfolder) {
            & ${env:ProgramFiles}\7-Zip\7z.exe x $env:USERPROFILE\Downloads\$file "-o$($gamepath + "\" + $subfolder)" -y # The Silverlock files have a subdir in the 7z file, the NVSE/Nexus files do not. Use this flag to create that subdir structure.
        } Else {
            & ${env:ProgramFiles}\7-Zip\7z.exe x $env:USERPROFILE\Downloads\$file "-o$($gamepath)" -y
        }
        # Copy the required components of F4SE to the root Fallout 4 folder
        Write-Log -Message "Copying Source $($SEGame) files to game path" -Level Info
        Copy-Item "$gamepath\$subfolder\*" -Exclude *.txt -Destination $gamepath -Force
        # Cleanup
        If ($dlkeep -eq $false) {
            Write-Log -Message "Cleaning up extracted files from $($gamepath)\$($subfolder)" -Level Info
            If (Test-Path -Path "$gamepath\src") { Remove-Item -Path "$gamepath\src" -Recurse -Force }
            Remove-Item -Path $gamepath\$subfolder -Recurse -Force
        }
    } Else {
        Write-Log -Message "Source version ($($dl.ver)) is NOT higher than Local version ($currentSE), no action taken" -Level Info
    }
    If ($RunGame) {
        If ($SEGame -eq "F76SFE") {
            Write-Log -Message "RunGame flag True, running Fallout76.exe" -Level Info
            Start-Process -FilePath "$gamepath\Fallout76.exe" -WorkingDirectory $gamepath -PassThru
            # If a window named "SFE" is found, that means SFE is incompatible with the current game version, end the Fallout76.exe task tree, archive the dxgi.dll file, and relaunch Fallout76.exe.
            Start-Sleep -Seconds 1
            $sfe = Get-Process | Where-Object { $_.MainWindowTitle -eq "SFE" }
            If ($sfe) {
                Write-Log -Message "SFE is incompatible with the current game version, archiving dxgi.dll and relaunching Fallout76.exe" -Level Warn
                Stop-Process -Name "Fallout76" -Force
                # Rename dxgi.dll to SFE-<version>-dxgi.dll, if SFE-<version>-dxgi.dll exists, delete dxgi.dll
                If (!(Test-Path "$gamepath\SFE-$($dl.ver)-dxgi.dll")) {
                    Rename-Item -Path "$gamepath\dxgi.dll" -NewName "SFE-$($dl.ver)-dxgi.dll" -Force
                } Else {
                    Remove-Item -Path "$gamepath\dxgi.dll" -Force
                }
                Start-Process -FilePath "$gamepath\Fallout76.exe" -WorkingDirectory $gamepath -PassThru
            }
        } Else {
            Write-Log -Message "RunGame flag True, running $($SEGame)_loader.exe" -Level Info
            Start-Process -FilePath "$gamepath\$($SEGame)_loader.exe" -WorkingDirectory $gamepath -PassThru
        }
    }
}


# SIG # Begin signature block
# MIIYngYJKoZIhvcNAQcCoIIYjzCCGIsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDoWURDAp+KlHzR
# HubviQZuF957KldChhY+2Qx/E9AedqCCB0IwggN5MIIC/qADAgECAhAcz51nzeIZ
# /xLZmv82guWnMAoGCCqGSM49BAMDMHwxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVU
# ZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENvcnBvcmF0aW9u
# MTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkg
# RUNDMB4XDTE5MDMwNzE5MzU0N1oXDTM0MDMwMzE5MzU0N1oweDELMAkGA1UEBhMC
# VVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhT
# U0wgQ29ycDE0MDIGA1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRp
# YXRlIENBIEVDQyBSMjB2MBAGByqGSM49AgEGBSuBBAAiA2IABOpt7gyJbfdl1TyX
# rJy6JZGueJwq39d2z/FOJTbnNRuYrlS823MWKvLp+ziKPRCumlXWYiCS5X0xZxWv
# 2FIxsD9Tf7tCm8JcqSsa6W8uRyjXT+yEBglVRcOJGZiIjeFxJKOCAUcwggFDMBIG
# A1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAUgtGFczDnNQTTjgKS++Wk0cQh
# 6M0weAYIKwYBBQUHAQEEbDBqMEYGCCsGAQUFBzAChjpodHRwOi8vd3d3LnNzbC5j
# b20vcmVwb3NpdG9yeS9TU0xjb20tUm9vdENBLUVDQy0zODQtUjEuY3J0MCAGCCsG
# AQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNvbTARBgNVHSAECjAIMAYGBFUdIAAw
# EwYDVR0lBAwwCgYIKwYBBQUHAwMwOwYDVR0fBDQwMjAwoC6gLIYqaHR0cDovL2Ny
# bHMuc3NsLmNvbS9zc2wuY29tLWVjYy1Sb290Q0EuY3JsMB0GA1UdDgQWBBQyeLEO
# kNtGzxrPtmMRbf4w52dUMDAOBgNVHQ8BAf8EBAMCAYYwCgYIKoZIzj0EAwMDaQAw
# ZgIxAIZwNaUUH2Oi1OfK9PES0J4Ay3EIm1mAOjpxEHItL3pSmV+5tJ/iQQqK2Dwg
# evkxFQIxAIHLuf6CWo8Wvxn2XZR/+3do0Q/XjqQSbfhJlqwRUVPlxUz5aK1vpJwv
# LRHaPzhzXTCCA8EwggNHoAMCAQICECr88sTPXCF1BxjYZYnFqywwCgYIKoZIzj0E
# AwMweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3Vz
# dG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIGA1UEAwwrU1NMLmNvbSBDb2RlIFNp
# Z25pbmcgSW50ZXJtZWRpYXRlIENBIEVDQyBSMjAeFw0yNTAyMDYwNDI2MzBaFw0y
# NzAyMDYwNDI2MzBaMHkxCzAJBgNVBAYTAlVTMRAwDgYDVQQIDAdBcml6b25hMRAw
# DgYDVQQHDAdQaG9lbml4MSIwIAYDVQQKDBlIYXJzaG1hZ2UgVGVjaG5vbG9neSwg
# TExDMSIwIAYDVQQDDBlIYXJzaG1hZ2UgVGVjaG5vbG9neSwgTExDMHYwEAYHKoZI
# zj0CAQYFK4EEACIDYgAEdw5NvdPSBVJyaFa8qcyDwB0wsL/0rQhh1lphmBG4lne2
# 341HtlN9F/GwxXIJj9j0x8194Xmp02rLMHX+HOpSUsRsaTaSBwrHtMQ0LoNLIVTs
# CW9xHJCR7eca5BJmxpEho4IBkzCCAY8wDAYDVR0TAQH/BAIwADAfBgNVHSMEGDAW
# gBQyeLEOkNtGzxrPtmMRbf4w52dUMDB5BggrBgEFBQcBAQRtMGswRwYIKwYBBQUH
# MAKGO2h0dHA6Ly9jZXJ0LnNzbC5jb20vU1NMY29tLVN1YkNBLWNvZGVTaWduaW5n
# LUVDQy0zODQtUjIuY2VyMCAGCCsGAQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNv
# bTBRBgNVHSAESjBIMAgGBmeBDAEEATA8BgwrBgEEAYKpMAEDAwEwLDAqBggrBgEF
# BQcCARYeaHR0cHM6Ly93d3cuc3NsLmNvbS9yZXBvc2l0b3J5MBMGA1UdJQQMMAoG
# CCsGAQUFBwMDMEwGA1UdHwRFMEMwQaA/oD2GO2h0dHA6Ly9jcmxzLnNzbC5jb20v
# U1NMY29tLVN1YkNBLWNvZGVTaWduaW5nLUVDQy0zODQtUjIuY3JsMB0GA1UdDgQW
# BBRzI40/UEMbyec3rFFEW5ZDtKwWYjAOBgNVHQ8BAf8EBAMCB4AwCgYIKoZIzj0E
# AwMDaAAwZQIwNVgM4BPJzIgZPJsqt2IM+YDkBxjUtNICT1s9b3jCdfhO42jFeC4Y
# fQNpNAG3I9cvAjEAqvktj50M7f/sEZeUtqkn30qEDVRZQQE6SWMKGtShygANugd4
# /lL/lh6qZ8OTjcHeMYIQsjCCEK4CAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNV
# BAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0
# MDIGA1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIEVD
# QyBSMgIQKvzyxM9cIXUHGNhlicWrLDANBglghkgBZQMEAgEFAKB8MBAGCisGAQQB
# gjcCAQwxAjAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDKkuMjhhzTe5os6qp+
# ubgGjPG/xvGsXNIPqPuY8Vyq8TALBgcqhkjOPQIBBQAEZjBkAjArLzOYmXjkEp1Q
# zCV/4WfMwKtkigjsYWlchLLt2+A4L9B6X1iLwXDwEPkC50cPJqYCMGUtBOK9Z6XC
# 0TQ0mebwNSh+GugHAJ+XlEplBgbXVQTzyMXtS07o5GRuCPgTnMphraGCDxYwgg8S
# BgorBgEEAYI3AwMBMYIPAjCCDv4GCSqGSIb3DQEHAqCCDu8wgg7rAgEDMQ0wCwYJ
# YIZIAWUDBAIBMHcGCyqGSIb3DQEJEAEEoGgEZjBkAgEBBgwrBgEEAYKpMAEDBgEw
# MTANBglghkgBZQMEAgEFAAQg5u8AhXFoKLeadfLkTfaIQWK9zCVad7NphKW7Mwrp
# mYoCCDwMkGdIDLFPGA8yMDI1MDQyNjA1MTA0NFowAwIBAaCCDAAwggT8MIIC5KAD
# AgECAhBaWqzoGjVutGKGjVd94D3HMA0GCSqGSIb3DQEBCwUAMHMxCzAJBgNVBAYT
# AlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwI
# U1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5nIElzc3Vpbmcg
# UlNBIENBIFIxMB4XDTI0MDIxOTE2MTgxOVoXDTM0MDIxNjE2MTgxOFowbjELMAkG
# A1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYD
# VQQKDAhTU0wgQ29ycDEqMCgGA1UEAwwhU1NMLmNvbSBUaW1lc3RhbXBpbmcgVW5p
# dCAyMDI0IEUxMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEp2Fy9TDpesSDFJYF
# QuPc6J3blG3ZMm9KYstovLdyZUBMAO+HIyvIPZkQvBh9XAAFTCK/DNh3WaVYJFdS
# 1wSwfKOCAVowggFWMB8GA1UdIwQYMBaAFAydECWOmqcbmYdDzwh+4b2BkPTPMFEG
# CCsGAQUFBwEBBEUwQzBBBggrBgEFBQcwAoY1aHR0cDovL2NlcnQuc3NsLmNvbS9T
# U0wuY29tLXRpbWVTdGFtcGluZy1JLVJTQS1SMS5jZXIwUQYDVR0gBEowSDA8Bgwr
# BgEEAYKpMAEDBgEwLDAqBggrBgEFBQcCARYeaHR0cHM6Ly93d3cuc3NsLmNvbS9y
# ZXBvc2l0b3J5MAgGBmeBDAEEAjAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDBGBgNV
# HR8EPzA9MDugOaA3hjVodHRwOi8vY3Jscy5zc2wuY29tL1NTTC5jb20tdGltZVN0
# YW1waW5nLUktUlNBLVIxLmNybDAdBgNVHQ4EFgQUUE8krO+1PmMTIwmSJuy6Opbk
# XSIwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQCYoI8DAJG8q8Rk
# QX9CIeK/q2wgee5U7sFYgupx9n2UnIjKIKaks60nlWdniG+b4Y/a0+46ll2Z9NhZ
# 3LOGE6wNUMsSVt+sowuI5ef27BQmlrl8xl7dmOiH6f/wN2dLDUzFk0waG5nHjN7K
# p6L3V/U6ERT/tva+ckJz3IEUyNj761Uqi8WPRMpPf9HL4jN1tvWAZdPNBDW5UXLt
# 2PEbH80bVU/9rJ7g6HEcb0WJndEz2jICI9sSCOudUJz6dYYqvcVNAMqLy827IucJ
# UeSKeIv4vPsfh8GCTXrcuXGLXVie7kD+mGmbVv4zaB6e+qjX7avyJUsesRGAUYxQ
# cR0qtn84VEOaAWsJNjrGdo9MDn+6uwKowrerf/n25lo6wFmFmRo/0S45banRTwaS
# CqnYY1SMWhoM1YWhP8RygYOJOA3xWZAWCfQVrj/d05vqWlgQ8FyOxYN2pRrG6BK1
# j1pb8DAJqXiVI3ii2WNuiTy7fWVnHk1VriMro3q6m+SDJnqiyZuYhav0MuGDxsj4
# qJcOcNZPTnjuBK5kthSr5NXo78OElkfktVclp5LWOONlmqErcQQglVmXTFhXgfhK
# S/LqEDatTIUrf7CFI1LnZMmSyGzFUI4+2+oD15w+pkvBYFoggIbjNWv4YAPuqNbC
# Vosx3ZnKWA4cjc6K3/SlUROoke63JjCCBvwwggTkoAMCAQICEG1SGHCH6CNNhWAA
# 0ICPk1YwDQYJKoZIhvcNAQELBQAwfDELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRl
# eGFzMRAwDgYDVQQHDAdIb3VzdG9uMRgwFgYDVQQKDA9TU0wgQ29ycG9yYXRpb24x
# MTAvBgNVBAMMKFNTTC5jb20gUm9vdCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eSBS
# U0EwHhcNMTkxMTEzMTg1MDA1WhcNMzQxMTEyMTg1MDA1WjBzMQswCQYDVQQGEwJV
# UzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAPBgNVBAoMCFNT
# TCBDb3JwMS8wLQYDVQQDDCZTU0wuY29tIFRpbWVzdGFtcGluZyBJc3N1aW5nIFJT
# QSBDQSBSMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK5REBPS+Twg
# oCCF3slQHGTJ4f3F6TT/Cn8xSOhyWsVeqGH98Yf3UVz7t+bQwcITsD7CY6KoGP04
# OskBgareubfeMKcdKwIE1YBBjKhq4urwiOqxLUmVcvb2oM0wx3BnxQ3NBLu9ZkwM
# njQlIY2mEwZMgDaqfZuiEa2BFzinXf3kRLKlQ5oa8ne3QU0vcG4qZvphy0xxBQXa
# yqigzN3z2HQTq6N28EOjpnA2dajGPtiZ9aNJeDfcDka5j3KbhBkzk4RWCjx5vP8H
# 6DKHIIs02GHgxv/jG8JMIxWY1isG+IaB09livKbxlvzhNAKZK5fQmUstrpYrVo7q
# qXAhJtv1tUaHzrp6QpuUL9dE/bSAC7UKO9xhyJSA1OsYWDx/wAmBA84JzX8IJ1ol
# JjCEmlJ2F4o6dCARKA2Zhk+EU4LogpowBReTlTW2NNwUKAW+8Cte0rhrMBZQ47Vj
# d92V0gEvouOTMtQJgk2QVeqGwFVw8y4HSdQNa8sl8+Kay2MnyUXhLoQLFaeVaLs4
# SVXBOe3Ua1Gp5j3J2+8Yue1T4V5wrsNuocNR3frpSt4yRIG3N68Bz1qqhk+eNUyO
# 8WpXWlg6POZOJUdm0BzzRsB8V7kst8nM8joOe03KqhunBN69Ckeo8M32qo07zeve
# RrDwD2P4dmJLDYBflwZ1A/SQbS+HN+AHAgMBAAGjggGBMIIBfTASBgNVHRMBAf8E
# CDAGAQH/AgEAMB8GA1UdIwQYMBaAFN0ECQei9Xp9UlMSkpXuOIAlDaZZMIGDBggr
# BgEFBQcBAQR3MHUwUQYIKwYBBQUHMAKGRWh0dHA6Ly93d3cuc3NsLmNvbS9yZXBv
# c2l0b3J5L1NTTGNvbVJvb3RDZXJ0aWZpY2F0aW9uQXV0aG9yaXR5UlNBLmNydDAg
# BggrBgEFBQcwAYYUaHR0cDovL29jc3BzLnNzbC5jb20wPwYDVR0gBDgwNjA0BgRV
# HSAAMCwwKgYIKwYBBQUHAgEWHmh0dHBzOi8vd3d3LnNzbC5jb20vcmVwb3NpdG9y
# eTATBgNVHSUEDDAKBggrBgEFBQcDCDA7BgNVHR8ENDAyMDCgLqAshipodHRwOi8v
# Y3Jscy5zc2wuY29tL3NzbC5jb20tcnNhLVJvb3RDQS5jcmwwHQYDVR0OBBYEFAyd
# ECWOmqcbmYdDzwh+4b2BkPTPMA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsF
# AAOCAgEAkhl1DaZaQs8ZB9ny/JT6wJvwFelEllovcTPdUOUTe5mTdw/E+3JtV8u6
# ppyLRbpIHbYlMy20KJAychU6xdaci4BsP9oVNxSRMsEjfHKz7ARqPNdpclhYAINL
# jsFGMO1iUNbXiAsnF/xboNCgfeMcMYbLyQYkU6UMobv9isrtQZ8e0EAQNV7qXJn4
# W0KyuTt0P8iIv/5DdDpIUBIktDZcjz2KEW6B1gvvsKIM1esjYwWylAazBcQAake5
# pANMdSn8t1HdPKsiwuWfOguyRQazAX8oXz6SlZSIok0Lis9a02vGVtdhEaB0R3Hx
# IyNRMMKWV1yuSeUXFuoexWav3GRPZC0WYb50SrW/l+wgrS8doetaMwyZon2L7ioY
# lIPSy1h9Dq/Q911PsSkbEZ3zrsB1roVnIfBu5BJp0xvQrQ/Q4LavuvCoFR7QFoyp
# NrotbNYi2AGMZw5td4zGZtCqUTPZi0BwSuRm+HRYAEMMThTwbJX/fYV1oC8mBN97
# 0yIvadIGKhh7+DmYdRJYBrL8inVFCZAK+YX2w1+qWEnCSPL/VTWJtSRMhQFfceDK
# bJC+pBNksvKzqkva0J1ZyMj1i4vDfSuBmbz4rfzsvvJxS+quZDdkmW6MeXevWGBX
# vqzdbAw+AqTVsAQUyP6tFeKZIL4S/fSFdl2rIx2X+KXkqx3S+EYxggJYMIICVAIB
# ATCBhzBzMQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hv
# dXN0b24xETAPBgNVBAoMCFNTTCBDb3JwMS8wLQYDVQQDDCZTU0wuY29tIFRpbWVz
# dGFtcGluZyBJc3N1aW5nIFJTQSBDQSBSMQIQWlqs6Bo1brRiho1XfeA9xzALBglg
# hkgBZQMEAgGgggFhMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAcBgkqhkiG
# 9w0BCQUxDxcNMjUwNDI2MDUxMDQ0WjAoBgkqhkiG9w0BCTQxGzAZMAsGCWCGSAFl
# AwQCAaEKBggqhkjOPQQDAjAvBgkqhkiG9w0BCQQxIgQgSWOwEKzUvoaW1Y29zJQN
# XTqcdeU6XwQ2bp6Ya+gkrl0wgckGCyqGSIb3DQEJEAIvMYG5MIG2MIGzMIGwBCCd
# cX+Nwjdlqs5eSrDh9XXXmhfUHO7Y/a/vA/09vYlH5zCBizB3pHUwczELMAkGA1UE
# BhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQK
# DAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNvbSBUaW1lc3RhbXBpbmcgSXNzdWlu
# ZyBSU0EgQ0EgUjECEFparOgaNW60YoaNV33gPccwCgYIKoZIzj0EAwIERzBFAiEA
# 0OYSE0vWucvseTy+D9HXqFN1jXkVa0zPF7x7aEoupzECIAMt/zXlTrvuTg5Zq36y
# 6cpsOqFfBtjIReF9jXt3WTiE
# SIG # End signature block
