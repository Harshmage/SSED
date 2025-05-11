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
		Install-Module -Name 7Zip4Powershell -Scope CurrentUser -Confirm:$false
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
# MIIYnwYJKoZIhvcNAQcCoIIYkDCCGIwCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBRqrQ1jlbZWgk6
# 8ffdUfkTHnRubnKjYUCUVuZVucibXKCCB0IwggN5MIIC/qADAgECAhAcz51nzeIZ
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
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCq8U+Ub7zj9FQJ8RyO
# hRQXrFJemA2Q2Fn098q4cy+eijALBgcqhkjOPQIBBQAEZjBkAjBr8b9APwos8dDG
# aAT6+Yk5O8X1MOHeWDoE3YIg3lNul+V59u28aZHxa6RMf71iS38CMEPHAgjGcsQ9
# a1N8wq02T1Qkc+o8gYPrOSy0862pKtKwmNj8PghE7UgB1M8mT7dOnqGCDxcwgg8T
# BgorBgEEAYI3AwMBMYIPAzCCDv8GCSqGSIb3DQEHAqCCDvAwgg7sAgEDMQ0wCwYJ
# YIZIAWUDBAIBMHcGCyqGSIb3DQEJEAEEoGgEZjBkAgEBBgwrBgEEAYKpMAEDBgEw
# MTANBglghkgBZQMEAgEFAAQgFc7QHEvSuFnRwIknxiLQNB8KqYH2jxn6gYGj69se
# JnYCCHpTe+wYQbudGA8yMDI1MDUxMTA4NTQwMVowAwIBAaCCDAAwggT8MIIC5KAD
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
# vqzdbAw+AqTVsAQUyP6tFeKZIL4S/fSFdl2rIx2X+KXkqx3S+EYxggJZMIICVQIB
# ATCBhzBzMQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hv
# dXN0b24xETAPBgNVBAoMCFNTTCBDb3JwMS8wLQYDVQQDDCZTU0wuY29tIFRpbWVz
# dGFtcGluZyBJc3N1aW5nIFJTQSBDQSBSMQIQWlqs6Bo1brRiho1XfeA9xzALBglg
# hkgBZQMEAgGgggFhMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAcBgkqhkiG
# 9w0BCQUxDxcNMjUwNTExMDg1NDAxWjAoBgkqhkiG9w0BCTQxGzAZMAsGCWCGSAFl
# AwQCAaEKBggqhkjOPQQDAjAvBgkqhkiG9w0BCQQxIgQgsYGijDEN/z6B82ZY8Jr8
# jP2ndeqbk0YUkvaGtWuas5swgckGCyqGSIb3DQEJEAIvMYG5MIG2MIGzMIGwBCCd
# cX+Nwjdlqs5eSrDh9XXXmhfUHO7Y/a/vA/09vYlH5zCBizB3pHUwczELMAkGA1UE
# BhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQK
# DAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNvbSBUaW1lc3RhbXBpbmcgSXNzdWlu
# ZyBSU0EgQ0EgUjECEFparOgaNW60YoaNV33gPccwCgYIKoZIzj0EAwIESDBGAiEA
# pZ7Y2o5Z1U6SVu/CuX/9P7IcIZELbLpYE/jl7Nj1ZWICIQCjut4eXGA1D1EkOfya
# 4SR4mwvBlU/JscsJKzQEbG6p2A==
# SIG # End signature block
