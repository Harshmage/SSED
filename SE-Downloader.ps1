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

Param (
	[Parameter(Mandatory = $true)]
	[ValidateSet("FOSE", "NVSE", "F4SE", "F76SFE", "OBSE", "OBSE64", "SKSE", "SKSE64", "SKSEVR", "MWSE", "SFSE")]
	[string]$SEGame,
	
	[Parameter()]
	[ValidateSet("true", "false")]
	[string]$RunGame = "false",
	
	[Parameter()]
	[ValidateSet("true", "false")]
	[string]$dlkeep = "false",
	
	[Parameter()]
	[ValidateSet("true", "false")]
	[string]$forceDL = "false",
	
	[Parameter()]
	[string]$hardpath,
	
	[Parameter()]
	[string]$nexusAPI = (Get-Content "..\nexus.api") # NexusMods API Key (https://www.nexusmods.com/users/myaccount?tab=api)
)

# Convert string to boolean
$RunGame = [System.Convert]::ToBoolean($RunGame)
$dlkeep = [System.Convert]::ToBoolean($dlkeep)
$forceDL = [System.Convert]::ToBoolean($forceDL)

$global:SEGame = $SEGame

Function Get-GamePath {
	# Get the Install Path from the uninstall registry
	If (($hardpath.Length -gt 4) -and (Test-path $hardpath)) {
		Write-Log -Level Debug -Message "Hard Path provided: $($hardpath)"
		$global:gamepath = $hardpath
	} Else {
		Try {
			$global:gamepath = get-childitem -recurse HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall | get-itemproperty | Where-Object { $_ -match $GameName } | Select-object -first 1 -expandproperty InstallLocation
			Test-path $gamepath
			Write-Log -Level Debug -Message "SEGame $SEGame path found in registry: $($gamepath)"
		} Catch {
			Write-Log -Level Error -Message "Unable to find installation directory for $GameName"
			Exit 1
		}
	}
	$global:gog = ($gamepath -notmatch "steamapps") # Identify if not using Steam for the install path, assume its GOG, as the Epic Store install is officially unsupported
	# Oblivion Remastered has a deeper path to the real executable folder
	If ($SEGame -eq "OBSE64") {
		$global:gamepath = "$gamepath\OblivionRemastered\Binaries\Win64"
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
	If (!($gamepath)) { Get-GamePath }
	Write-Log -Level Debug -Message "Get-NexusMods called with gameID: $($nexusgameID), modID: $($nexusmodID), fileindex: $($nexusfileindex)"
	If ($nexusAPI -eq "") { Write-Log -Level Error -Message "Nexus API Key is empty"; Exit 1 }
	$nexusHeaders = @{
		"Accept" = "application/json"
		"apikey" = "$nexusAPI"
	}
	$global:url = "https://api.nexusmods.com"
	Try {
		$global:WebResponse = (Invoke-WebRequest "https://api.nexusmods.com/v1/games/$nexusgameID/mods/$nexusmodID/files.json" -Headers $nexusHeaders -UseBasicParsing).Content | ConvertFrom-Json | Select-Object -Property @{ L = 'files'; E = { $_.files[$nexusfileindex] } }
		$global:json = $WebResponse.files
		$global:latestfileid = $json.file_id[0]
		$global:dlResponse = (Invoke-WebRequest "https://api.nexusmods.com/v1/games/$nexusgameID/mods/$nexusmodID/files/$latestfileid/download_link.json" -Headers $nexusHeaders).Content | ConvertFrom-Json | Where-Object { $_.short_name -eq "Nexus CDN" }
		# if Select-Object returns an error, set the $halt flag
		If ($null -eq $dlResponse) {
			Write-Log -Level Error -Message "Unable to access NexusMods API"
			Write-Log -Level Error -Message "$($Error[0].Exception.Message)"
			Write-Log -Level Error -Message "API Key: $nexusAPI"
			Write-Log -Level Error -Message "Game: $GameName"
			Write-Log -Level Error -Message "Mod ID: $nexusmodID"
			$global:halt = $true
			# throw error
			Throw "Unable to access NexusMods API"
		}
		If ($SEGame -eq "FOSE") {
			# FOSE in a post-GFWL has a tag of -newloader, need to trim that off to work properly.
			$global:dl = [PSCustomObject]@{
				ver = [System.Version]::Parse("0.$(($json.version).Replace('-newloader', ''))")
				url = $dlResponse[0].URI
				file = $json.file_name
			}
		} Else {
			$global:dl = [PSCustomObject]@{
				ver = [System.Version]::Parse("0.$($json.version)")
				url = $dlResponse[0].URI
				file = $json.file_name
				nexusver = $json.version
			}
		}
		$global:subfolder = ($dl.file).Replace('.7z', '') # f4se_0_06_20
		Write-Log -Level Debug -Message "NexusMods API returned: $($dl.file), version $($dl.ver) for $($SEGame)"
		Write-Log -Level Debug -Message "NexusMods API returned: $($dl.url)"
	} Catch {
		Write-Log -Level Error -Message "Unable to access NexusMods API"
		Write-Log -Level Error -Message "$($Error[0].Exception.Message)"
		Write-Log -Level Error -Message "API Key: $nexusAPI"
		Write-Log -Level Error -Message "Game: $GameName"
		Write-Log -Level Error -Message "Mod ID: $nexusmodID"
		$global:halt = $true
	}
}

Function Get-GitHubMod {
	[CmdletBinding()]
	Param (
		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$url
	)
	If (!($gamepath)) { Get-GamePath }
	Write-Log -Level Debug -Message "Get-GitHubMod called with URL: $($url)"
	Try {
		$WebResponse = Invoke-WebRequest $url -Headers @{ "Accept" = "application/json" } -UseBasicParsing
		$json = $WebResponse.Content | ConvertFrom-Json
		$json = $json[0]
		If ($SEGame -eq "SKSE64") {
			# SKSE64 has a GOG version, need to check for that
			$global:dl = [PSCustomObject]@{
				ver = [System.Version]::Parse("0." + ($json.tag_name).Replace("v", "")) # 0. + 5.1.6 = 0.5.1.6
				url = If ($gog) { $json.assets.browser_download_url | Where-Object { $_ -match "gog" } } Else { $json.assets.browser_download_url | Where-Object { $_ -notmatch "gog" } } # https://github.com/xNVSE/NVSE/releases/download/5.1.6/nvse_5_1_beta6.7z
				file = If ($gog) { $json.assets.name | Where-Object { $_ -match "gog" } } Else { $json.assets.name | Where-Object { $_ -notmatch "gog" } } # nvse_5_1_beta6.7z
			}
		} Else {
			$global:dl = [PSCustomObject]@{
				ver = [System.Version]::Parse("0." + ($json.tag_name).Replace("v", "")) # 0. + 5.1.6 = 0.5.1.6
				url = If ($gog) { $json.assets.browser_download_url | Where-Object { $_ -match "gog" } } Else { $json.assets.browser_download_url | Where-Object { $_ -notmatch "gog" } } # https://github.com/xNVSE/NVSE/releases/download/5.1.6/nvse_5_1_beta6.7z
				file = If ($gog) { $json.assets.name | Where-Object { $_ -match "gog" } } Else { $json.assets.name | Where-Object { $_ -notmatch "gog" } } # nvse_5_1_beta6.7z
			}
		}
		$subfolder = ($dl.file).Replace('.7z', '') # f4se_0_06_20
		Write-Log -Level Debug -Message "GitHub API returned: $($dl.file), version $($dl.ver) for $($SEGame)"
		Write-Log -Level Debug -Message "GitHub API returned: $($dl.url)"
	} Catch {
		Write-Log -Level Error -Message "Unable to access URL: $url"
		Write-Log -Level Error -Message "$($Error[0].Exception.Message)"
		Write-Log -Level Error -Message "Game: $GameName"
		$global:halt = $true
	}
}

Function Get-CurrentVersion {
	# Get current install version
	Try {
		If ($null -eq $global:currentSE) {
			$global:currentSE = Get-Item "$gamepath\$($SEGame.ToLower())_*.dll" -Exclude "$($SEGame)_steam_loader.dll", "$($SEGame.ToLower())_editor*.dll" # f4se_1_10_163.dll
			$global:currentSE = (Get-Item $global:currentSE).VersionInfo.FileVersion # 0, 0, 6, 20
			If ($global:currentSE -is [System.Array]) { $global:currentSE = $global:currentSE[0] }
			$global:currentSE = $global:currentSE.Replace(', ', '.') # 0.0.6.20
			$global:currentSE = [System.Version]::Parse($global:currentSE)
		} ElseIf ($SEGame -eq "F76SFE") {
			$global:currentSE = (Get-Item "$gamepath\dxgi.dll").VersionInfo.FileVersion # 0, 0, 6, 20
			If ($global:currentSE -is [System.Array]) { $global:currentSE = $global:currentSE[0] }
			$global:currentSE = [System.Version]::Parse($global:currentSE.Replace(', ', '.'))
		}
		Write-Log -Level Debug -Message "Current version of $($SEGame) found: $($global:currentSE)"
	} Catch {
		$global:currentSE = [System.Version]::Parse("0.0.0.0") # Means you don't have it
		Write-Log -Level Error -Message "Unable to find current version of $($SEGame), defaulting version compare to $($global:currentSE)"
	}
}

Function Get-Download {
	[CmdletBinding()]
	Param (
		[Parameter()]
		[string]$downloadURL,
		
		[Parameter()]
		[string]$downloadFile = "$($dl.file)",
		
		[Parameter()]
		[string]$saveDir = "$env:USERPROFILE\Downloads",
		
		[Parameter()]
		[string]$extractPath
	)
	
	# Check for 7Zip4Powershell module, install if not found, and import it
	If (!(Get-Module -Name "7Zip4Powershell")) {
		Write-Log -Level Debug -Message "7Zip4Powershell module not found, installing..."
		Install-Module -Name 7Zip4Powershell -Scope CurrentUser -Confirm:$false -Force
	}
	Import-Module -Name 7Zip4Powershell
	
	Write-Log -Message "Downloading Source version ($($dl.url))" -Level Info
	Invoke-WebRequest $downloadURL -OutFile "$saveDir\$downloadFile" -UseBasicParsing
	If ($forceDL) {
		# Cleanup Fallout 4 directory of older F4SE components
		#Write-Log -Message "Cleaning up older Local $($SEGame) files" -Level Info
		#Get-ChildItem -Path "$gamepath\$($SEGame)*" -Exclude "$SEGame-Updater.log" | Remove-Item -Force -Recurse       
	}
	# Extract F4SE to the Fallout 4 folder (f4path\f4se_x_xx_xx)
	
	# If $useSubfolder is true, then we need to extract to a subfolder instead of directly into the root game folder
	If ($global:useSubfolder) {
		$subfolder = $SEGame.ToLower()
		$extractPath = "$gamepath\$($subfolder)"
	}
	
	Write-Log -Message "Extracting Source $($SEGame) files $downloadFile to $($extractPath))" -Level Info
	Expand-7zip -ArchiveFileName "$saveDir\$downloadFile" -TargetPath $extractPath
	Write-Log -Message "Copying Source $($SEGame) files to game path" -Level Info
	Copy-Item "$extractPath\*" -include *.dll, *.exe -Destination $gamepath -Recurse -Force
	# Cleanup
	If ($dlkeep -eq $false) {
		#Write-Log -Message "Cleaning up extracted files from $($extractPath)" -Level Info
		#If (Test-Path -Path "$gamepath\src") { Remove-Item -Path "$gamepath\src" -Recurse -Force }
		#Remove-Item -Path $gamepath\$subfolder -Recurse -Force
	}
}

Function Write-Log {
	[CmdletBinding()]
	Param (
		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[ValidateNotNullOrEmpty()]
		[Alias("LogContent")]
		[string]$Message,
		
		[Parameter(Mandatory = $false)]
		[Alias('LogPath')]
		[string]$Path = "$gamepath\$($SEGame)-Updater.log",
		
		[Parameter(Mandatory = $false)]
		[ValidateSet("Error", "Warn", "Info", "Debug")]
		[string]$Level = "Info",
		
		[Parameter(Mandatory = $false)]
		[switch]$NoClobber
	)
	
	Begin {
		# Set VerbosePreference to Continue so that verbose messages are displayed. 
		$VerbosePreference = 'Continue'
		If (!($gamepath)) { Get-GamePath }
	}
	Process {
		# If the file already exists and NoClobber was specified, do not write to the log. 
		If ((Test-Path $Path) -AND $NoClobber) {
			Write-Error "Log file $Path already exists, and you specified NoClobber. Either delete the file or specify a different name."
			Return
		} ElseIf (!(Test-Path $Path)) {
			# If attempting to write to a log file in a folder/path that doesn't exist create the file including the path. 
			Write-Verbose "Creating $Path."
			New-Item $Path -Force -ItemType File
		} Else {
			# Nothing to see here yet. 
		}
		# Format Date for our Log File 
		$FormattedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
		# Write message to error, warning, or verbose pipeline and specify $LevelText 
		Switch ($Level) {
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
		"$FormattedDate $LevelText $Message" | Out-File -FilePath $Path -Append -Encoding ascii
		Write-Host "$FormattedDate $LevelText $Message"
	}
}

$NexusAPIRquired = @("F76SFE", "OBSE64", "SFSE", "SKSEVR", "SKSE", "FOSE", "MWSE")
If ($SEGame -in $NexusAPIRquired) {
	If (-not $nexusAPI) {
		Write-Error -Message "NexusMods SSED API key is required for $SEGame, visit https://next.nexusmods.com/settings/api-keys#:~:text=Silverlock%20Script%20Extender%20Downloader to acquire one!"
		Exit 1
	}
}



# Set some variables for much older silverlock.org versions
#$url = "https://$($SEGame).silverlock.org/"
#$rtype = "beta" # Release Type, Beta or Download

# Build the primary game and DLL variables
If ($SEGame -eq "SKSE64") {
	$GameName = "Skyrim Special Edition"
	Get-GitHubMod -url "https://api.github.com/repos/ianpatt/$($SEGame)/releases"
} ElseIf ($SEGame -eq "SKSEVR") {
	# TODO Need to validate
	$GameName = "Skyrim VR"
	Get-NexusMods -nexusmodID "30457" -nexusgameID "skyrimspecialedition" -nexusfileindex "0"
} ElseIf ($SEGame -eq "SKSE") {
	# TODO Need to validate
	$GameName = "Skyrim"
	Get-NexusMods -nexusmodID "100216" -nexusgameID "skyrim" -nexusfileindex "0"
} ElseIf ($SEGame -eq "OBSE") {
	# TODO Need to validate
	$GameName = "Oblivion"
	Get-GitHubMod -url "https://api.github.com/repos/llde/xOBSE/releases"
} ElseIf ($SEGame -eq "OBSE64") {
	$GameName = "Oblivion Remastered"
	Get-NexusMods -nexusmodID "282" -nexusgameID "oblivionremastered" -nexusfileindex "-1"
} ElseIf ($SEGame -eq "F4SE") {
	$GameName = "Fallout4"
	# 20240718 - Adding new code to check the game version and determine the correct F4SE version to download due to the overhaul patch in April 2024
	# This is going to be weird for a while, until ianpatt adds the 0.7.2 release to the Github repo (currently only available on NexusMods)
	# Also this is in prep for Fallout: London, which will only work with the pre-overhaul patch version of Fallout 4
	Get-GamePath
	$currentGameVer = (Get-Item "$gamepath\Fallout4.exe").VersionInfo.FileVersion
	If ($currentGameVer -eq "1.10.163.0") {
		Write-Log -Level Debug -Message "Fallout 4 version 1.10.163.0 is pre-overhaul patch, and uses F4SE 0.6.23, specifically for Fallout: London"
		Get-GitHubMod -url "https://api.github.com/repos/ianpatt/$($SEGame)/releases"
	} Else {
		# otherwise assume the game is post-overhaul patch, and uses F4SE 0.7.2+ from NexusMods
		Get-NexusMods -nexusmodID "42147" -nexusgameID "fallout4" -nexusfileindex "-1"
	}
} ElseIf ($SEGame -eq "F76SFE") {
	$GameName = "Fallout76"
	Get-NexusMods -nexusmodID "287" -nexusgameID "fallout76" -nexusfileindex "-1"
	# And because SFE isn't exactly standard, we have to do some extra parsing.
	Get-CurrentVersion
	$subfolder = ($dl.file).Replace('.zip', '')
	$global:useSubfolder = $true
} ElseIf ($SEGame -eq "NVSE") {
	$GameName = "Fallout New Vegas"
	# NVSE went to a community Github in May 2020
	# https://github.com/xNVSE/NVSE
	Get-GitHubMod -url "https://api.github.com/repos/xNVSE/$($SEGame)/releases"
	$global:useSubfolder = $true
} ElseIf ($SEGame -eq "FOSE") {
	# https://www.nexusmods.com/fallout3/mods/8606
	$GameName = "Fallout 3"
	Get-NexusMods -nexusmodID "8606" -nexusgameID "fallout3" -nexusfileindex "-1"
} ElseIf ($SEGame -eq "MWSE") {
	# TODO Need to validate
	$GameName = "Morrowind"
	Get-NexusMods -nexusmodID "45468" -nexusgameID "morrowind" -nexusfileindex "-1"
} ElseIf ($SEGame -eq "SFSE") {
	$GameName = "Starfield"
	Get-NexusMods -nexusmodID "106" -nexusgameID "starfield" -nexusfileindex "-1"
	$global:useSubfolder = $true
}

If (!($halt)) {
	If ($null -eq $gamepath) { Get-GamePath }
	
	Get-CurrentVersion
	
	# Compare versions, download if source is newer than local
	If (($dl.ver -gt $global:currentSE) -or ($forceDL -eq $true)) {
		Write-Log -Message "Source version ($($dl.ver)) is higher than Local version ($global:currentSE)" -Level Warn
		Get-Download -downloadURL $dl.url -downloadFile $dl.file -extractPath "$gamepath" -saveDir "$env:USERPROFILE\Downloads"
	} Else {
		Write-Log -Message "Source version ($($dl.ver)) is NOT higher than Local version ($global:currentSE), no action taken" -Level Info
	}
	If ($RunGame -eq "true") {
		If ($SEGame -eq "F76SFE") {
			Write-Log -Message "RunGame flag True, running Fallout76.exe" -Level Info
			Start-Process -FilePath "$gamepath\Fallout76.exe" -WorkingDirectory $gamepath -PassThru
			# If a window named "SFE" is found, that means SFE is incompatible with the current game version, end the Fallout76.exe task tree, archive the dxgi.dll file, and relaunch Fallout76.exe.
			Start-Sleep -Seconds 5
			$sfeOOD = Get-Process | Where-Object { $_.MainWindowTitle -eq "SFE" }
			If ($sfeOOD) {
				<#
				Write-Log -Message "SFE is incompatible with the current game version, archiving dxgi.dll and relaunching Fallout76.exe" -Level Warn
				Stop-Process -Name "Fallout76" -Force
				# Rename dxgi.dll to SFE-<version>-dxgi.dll, if SFE-<version>-dxgi.dll exists, delete dxgi.dll
				If (!(Test-Path "$gamepath\SFE-$($dl.ver)-dxgi.dll")) {
					Rename-Item -Path "$gamepath\dxgi.dll" -NewName "SFE-$($dl.ver)-dxgi.dll" -Force
				} Else {
					Remove-Item -Path "$gamepath\dxgi.dll" -Force
				}
				Start-Process -FilePath "$gamepath\Fallout76.exe" -WorkingDirectory $gamepath -PassThru
				#>
				Write-Log -Message "SFE is incompatible with the current game version, looping to close error message" -Level Warn
				# Message pops up 3 times, first is immediate, second takes ~12 seconds, third is less than 5 seconds after that
				$i = 0
				$counter = 0
				Do {
					Start-Sleep -Seconds 1
					If (Get-Process | Where-Object { $_.MainWindowTitle -eq "SFE" }) {
						If (!($wshell)) { $wshell = New-Object -ComObject wscript.shell }
						$wshell.AppActivate('SFE')
						Start-Sleep 1
						$wshell.SendKeys('%C')
						$wshell.AppActivate('SFE')
						Start-Sleep 1
						$wshell.SendKeys('{ENTER}')
						$i++
					}
					$counter++
				} Until ($i -eq 3 -or $counter -eq 45)
			}
		} Else {
			Write-Log -Message "RunGame flag True, running $($SEGame)_loader.exe" -Level Info
			Start-Process -FilePath "$gamepath\$($SEGame)_loader.exe" -WorkingDirectory $gamepath -PassThru
		}
	}
}
# SIG # Begin signature block
# MIIYnwYJKoZIhvcNAQcCoIIYkDCCGIwCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDOGOeLn4iN98nl
# eZWtNFEJ5tA3Z+7lKH2Hg4KuH3Trz6CCB0IwggN5MIIC/qADAgECAhAcz51nzeIZ
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
# /lL/lh6qZ8OTjcHeMYIQszCCEK8CAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNV
# BAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0
# MDIGA1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIEVD
# QyBSMgIQKvzyxM9cIXUHGNhlicWrLDANBglghkgBZQMEAgEFAKB8MBAGCisGAQQB
# gjcCAQwxAjAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBuqEgDMQW6iev/Gjgv
# x0qL+oYepEMuQGptLyRZF8CYWDALBgcqhkjOPQIBBQAEZzBlAjEAt9ASjFooJZrM
# X/hvXaSFdkXYuthZ3eOGfV7aoxAxKpAEqzgauIJgSpqRWzXpc6CcAjAFwAkWDsiO
# sYabKAdtD7iNDpFc9efXUO2zwq+m3NwJhlkkVm83M8NwGcw/AK39KX6hgg8WMIIP
# EgYKKwYBBAGCNwMDATGCDwIwgg7+BgkqhkiG9w0BBwKggg7vMIIO6wIBAzENMAsG
# CWCGSAFlAwQCATB3BgsqhkiG9w0BCRABBKBoBGYwZAIBAQYMKwYBBAGCqTABAwYB
# MDEwDQYJYIZIAWUDBAIBBQAEIMlK8hiuePliKwT0n0WnKOusljVhg5Z7RLT+IEQJ
# F3GRAghNV0UaJdUzyhgPMjAyNTEyMDUwMjU0NThaMAMCAQGgggwAMIIE/DCCAuSg
# AwIBAgIQWlqs6Bo1brRiho1XfeA9xzANBgkqhkiG9w0BAQsFADBzMQswCQYDVQQG
# EwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAPBgNVBAoM
# CFNTTCBDb3JwMS8wLQYDVQQDDCZTU0wuY29tIFRpbWVzdGFtcGluZyBJc3N1aW5n
# IFJTQSBDQSBSMTAeFw0yNDAyMTkxNjE4MTlaFw0zNDAyMTYxNjE4MThaMG4xCzAJ
# BgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8G
# A1UECgwIU1NMIENvcnAxKjAoBgNVBAMMIVNTTC5jb20gVGltZXN0YW1waW5nIFVu
# aXQgMjAyNCBFMTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABKdhcvUw6XrEgxSW
# BULj3Oid25Rt2TJvSmLLaLy3cmVATADvhyMryD2ZELwYfVwABUwivwzYd1mlWCRX
# UtcEsHyjggFaMIIBVjAfBgNVHSMEGDAWgBQMnRAljpqnG5mHQ88IfuG9gZD0zzBR
# BggrBgEFBQcBAQRFMEMwQQYIKwYBBQUHMAKGNWh0dHA6Ly9jZXJ0LnNzbC5jb20v
# U1NMLmNvbS10aW1lU3RhbXBpbmctSS1SU0EtUjEuY2VyMFEGA1UdIARKMEgwPAYM
# KwYBBAGCqTABAwYBMCwwKgYIKwYBBQUHAgEWHmh0dHBzOi8vd3d3LnNzbC5jb20v
# cmVwb3NpdG9yeTAIBgZngQwBBAIwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwRgYD
# VR0fBD8wPTA7oDmgN4Y1aHR0cDovL2NybHMuc3NsLmNvbS9TU0wuY29tLXRpbWVT
# dGFtcGluZy1JLVJTQS1SMS5jcmwwHQYDVR0OBBYEFFBPJKzvtT5jEyMJkibsujqW
# 5F0iMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAmKCPAwCRvKvE
# ZEF/QiHiv6tsIHnuVO7BWILqcfZ9lJyIyiCmpLOtJ5VnZ4hvm+GP2tPuOpZdmfTY
# WdyzhhOsDVDLElbfrKMLiOXn9uwUJpa5fMZe3Zjoh+n/8DdnSw1MxZNMGhuZx4ze
# yqei91f1OhEU/7b2vnJCc9yBFMjY++tVKovFj0TKT3/Ry+Izdbb1gGXTzQQ1uVFy
# 7djxGx/NG1VP/aye4OhxHG9FiZ3RM9oyAiPbEgjrnVCc+nWGKr3FTQDKi8vNuyLn
# CVHkiniL+Lz7H4fBgk163Llxi11Ynu5A/phpm1b+M2genvqo1+2r8iVLHrERgFGM
# UHEdKrZ/OFRDmgFrCTY6xnaPTA5/ursCqMK3q3/59uZaOsBZhZkaP9EuOW2p0U8G
# kgqp2GNUjFoaDNWFoT/EcoGDiTgN8VmQFgn0Fa4/3dOb6lpYEPBcjsWDdqUaxugS
# tY9aW/AwCal4lSN4otljbok8u31lZx5NVa4jK6N6upvkgyZ6osmbmIWr9DLhg8bI
# +KiXDnDWT0547gSuZLYUq+TV6O/DhJZH5LVXJaeS1jjjZZqhK3EEIJVZl0xYV4H4
# Skvy6hA2rUyFK3+whSNS52TJkshsxVCOPtvqA9ecPqZLwWBaIICG4zVr+GAD7qjW
# wlaLMd2ZylgOHI3Oit/0pVETqJHutyYwggb8MIIE5KADAgECAhBtUhhwh+gjTYVg
# ANCAj5NWMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVU
# ZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENvcnBvcmF0aW9u
# MTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkg
# UlNBMB4XDTE5MTExMzE4NTAwNVoXDTM0MTExMjE4NTAwNVowczELMAkGA1UEBhMC
# VVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhT
# U0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNvbSBUaW1lc3RhbXBpbmcgSXNzdWluZyBS
# U0EgQ0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCuURAT0vk8
# IKAghd7JUBxkyeH9xek0/wp/MUjoclrFXqhh/fGH91Fc+7fm0MHCE7A+wmOiqBj9
# ODrJAYGq3rm33jCnHSsCBNWAQYyoauLq8IjqsS1JlXL29qDNMMdwZ8UNzQS7vWZM
# DJ40JSGNphMGTIA2qn2bohGtgRc4p1395ESypUOaGvJ3t0FNL3BuKmb6YctMcQUF
# 2sqooMzd89h0E6ujdvBDo6ZwNnWoxj7YmfWjSXg33A5GuY9ym4QZM5OEVgo8ebz/
# B+gyhyCLNNhh4Mb/4xvCTCMVmNYrBviGgdPZYrym8Zb84TQCmSuX0JlLLa6WK1aO
# 6qlwISbb9bVGh866ekKblC/XRP20gAu1CjvcYciUgNTrGFg8f8AJgQPOCc1/CCda
# JSYwhJpSdheKOnQgESgNmYZPhFOC6IKaMAUXk5U1tjTcFCgFvvArXtK4azAWUOO1
# Y3fdldIBL6LjkzLUCYJNkFXqhsBVcPMuB0nUDWvLJfPimstjJ8lF4S6ECxWnlWi7
# OElVwTnt1GtRqeY9ydvvGLntU+FecK7DbqHDUd366UreMkSBtzevAc9aqoZPnjVM
# jvFqV1pYOjzmTiVHZtAc80bAfFe5LLfJzPI6DntNyqobpwTevQpHqPDN9qqNO83r
# 3kaw8A9j+HZiSw2AX5cGdQP0kG0vhzfgBwIDAQABo4IBgTCCAX0wEgYDVR0TAQH/
# BAgwBgEB/wIBADAfBgNVHSMEGDAWgBTdBAkHovV6fVJTEpKV7jiAJQ2mWTCBgwYI
# KwYBBQUHAQEEdzB1MFEGCCsGAQUFBzAChkVodHRwOi8vd3d3LnNzbC5jb20vcmVw
# b3NpdG9yeS9TU0xjb21Sb290Q2VydGlmaWNhdGlvbkF1dGhvcml0eVJTQS5jcnQw
# IAYIKwYBBQUHMAGGFGh0dHA6Ly9vY3Nwcy5zc2wuY29tMD8GA1UdIAQ4MDYwNAYE
# VR0gADAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3JlcG9zaXRv
# cnkwEwYDVR0lBAwwCgYIKwYBBQUHAwgwOwYDVR0fBDQwMjAwoC6gLIYqaHR0cDov
# L2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0GA1UdDgQWBBQM
# nRAljpqnG5mHQ88IfuG9gZD0zzAOBgNVHQ8BAf8EBAMCAYYwDQYJKoZIhvcNAQEL
# BQADggIBAJIZdQ2mWkLPGQfZ8vyU+sCb8BXpRJZaL3Ez3VDlE3uZk3cPxPtybVfL
# uqaci0W6SB22JTMttCiQMnIVOsXWnIuAbD/aFTcUkTLBI3xys+wEajzXaXJYWACD
# S47BRjDtYlDW14gLJxf8W6DQoH3jHDGGy8kGJFOlDKG7/YrK7UGfHtBAEDVe6lyZ
# +FtCsrk7dD/IiL/+Q3Q6SFASJLQ2XI89ihFugdYL77CiDNXrI2MFspQGswXEAGpH
# uaQDTHUp/LdR3TyrIsLlnzoLskUGswF/KF8+kpWUiKJNC4rPWtNrxlbXYRGgdEdx
# 8SMjUTDClldcrknlFxbqHsVmr9xkT2QtFmG+dEq1v5fsIK0vHaHrWjMMmaJ9i+4q
# GJSD0stYfQ6v0PddT7EpGxGd867Ada6FZyHwbuQSadMb0K0P0OC2r7rwqBUe0BaM
# qTa6LWzWItgBjGcObXeMxmbQqlEz2YtAcErkZvh0WABDDE4U8GyV/32FdaAvJgTf
# e9MiL2nSBioYe/g5mHUSWAay/Ip1RQmQCvmF9sNfqlhJwkjy/1U1ibUkTIUBX3Hg
# ymyQvqQTZLLys6pL2tCdWcjI9YuLw30rgZm8+K387L7ycUvqrmQ3ZJlujHl3r1hg
# V76s3WwMPgKk1bAEFMj+rRXimSC+Ev30hXZdqyMdl/il5Ksd0vhGMYICWDCCAlQC
# AQEwgYcwczELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdI
# b3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNvbSBUaW1l
# c3RhbXBpbmcgSXNzdWluZyBSU0EgQ0EgUjECEFparOgaNW60YoaNV33gPccwCwYJ
# YIZIAWUDBAIBoIIBYTAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwHAYJKoZI
# hvcNAQkFMQ8XDTI1MTIwNTAyNTQ1OFowKAYJKoZIhvcNAQk0MRswGTALBglghkgB
# ZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIL9tjh53E5d0oEDirNQp
# TS4H8DdxVNTmvjmM2IJkhUdiMIHJBgsqhkiG9w0BCRACLzGBuTCBtjCBszCBsAQg
# nXF/jcI3ZarOXkqw4fV115oX1Bzu2P2v7wP9Pb2JR+cwgYswd6R1MHMxCzAJBgNV
# BAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UE
# CgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5nIElzc3Vp
# bmcgUlNBIENBIFIxAhBaWqzoGjVutGKGjVd94D3HMAoGCCqGSM49BAMCBEcwRQIg
# aUa3mVi1ci7bCU75Tq7Hm7c3ShKftFpPD+Kxe37Y+2ECIQCP0a46hgg1rkkMTcA0
# 8mJRnX4EsaVpDtMJlKQ80LSHQQ==
# SIG # End signature block
