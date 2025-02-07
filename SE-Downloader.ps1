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
    [ValidateSet("FOSE","NVSE","F4SE","F76SFE","OBSE","SKSE","SKSE64","SKSEVR","MWSE","SFSE")]
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
        Write-Host "Unable to access NexusMods API"
        Write-Host $Error[0].Exception.Message -ForegroundColor Red
        Write-Host "API Key: $nexusAPI"
        Write-Host "Game: $GameName"
        Write-Host "Mod ID: $nexusmodID"
        $global:halt = $true
    }
}

<#
# For future use to move mod variables to an INI file
Function Parse-IniFile ($file) {
    $ini = @{}
    # Create a default section if none exist in the file. Like a java prop file.
    $section = "NO_SECTION"
    $ini[$section] = @{}
    switch -regex -file $file {
        "^\[(.+)\]$" {
            $section = $matches[1].Trim()
            $ini[$section] = @{}
        }
        "^\s*([^#].+?)\s*=\s*(.*)" {
            $name,$value = $matches[1..2]
            # skip comments that start with semicolon:
            if (!($name.StartsWith(";"))) {
                $ini[$section][$name] = $value.Trim()
            }
        }
    }
    $ini
}
#>

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
        [ValidateSet("Error","Warn","Info")] 
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
            } 
        # If attempting to write to a log file in a folder/path that doesn't exist create the file including the path. 
        elseif (!(Test-Path $Path)) { 
            Write-Verbose "Creating $Path." 
            New-Item $Path -Force -ItemType File 
            } 
        else { 
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
            } 
        # Write log entry to $Path 
        "$FormattedDate $LevelText $Message" | Out-File -FilePath $Path -Append
        Write-Host "$FormattedDate $LevelText $Message"
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
    $WebResponse = Invoke-WebRequest $url -Headers @{"Accept"="application/json"} -UseBasicParsing
    $json = $WebResponse.Content | ConvertFrom-Json
    $json = $json[0]
    $dl = [PSCustomObject]@{
        ver = [System.Version]::Parse("0." + ($json.tag_name).Replace("v","")) # 0. + 5.1.6 = 0.5.1.6
        url = If ($gog) { $json.assets.browser_download_url | Where-Object { $_ -match "gog" } } Else { $json.assets.browser_download_url | Where-Object { $_ -notmatch "gog" } } # https://github.com/xNVSE/NVSE/releases/download/5.1.6/nvse_5_1_beta6.7z
        file = If ($gog) { $json.assets.name | Where-Object { $_ -match "gog" } } Else { $json.assets.name | Where-Object { $_ -notmatch "gog" } } # nvse_5_1_beta6.7z
    }
    $subfolder = ($dl.file).Replace('.7z','') # f4se_0_06_20
} ElseIf ($SEGame -eq "SKSEVR") {
    # TODO Need to validate
    If ($nexusAPI -eq "") { Write-Log -Level Error -Message "Nexus API Key is empty" ; Exit }
    $GameName = "Skyrim VR"
    $nexusmodID = "30457"
    $nexusgameID = "skyrimspecialedition"
    $nexusfileindex = "0"
    Get-NexusMods
} ElseIf ($SEGame -eq "SKSE") {
    # TODO Need to validate
    If ($nexusAPI -eq "") { Write-Log -Level Error -Message "Nexus API Key is empty" ; Exit }
    $GameName = "Skyrim"
    $nexusmodID = "100216"
    $nexusgameID = "skyrim"
    $nexusfileindex = "0"
    Get-NexusMods
} ElseIf ($SEGame -eq "OBSE") {
    # TODO Need to validate
    $GameName = "Oblivion"
    $url = "https://api.github.com/repos/llde/xOBSE/releases"
    $WebResponse = Invoke-WebRequest $url -Headers @{"Accept"="application/json"} -UseBasicParsing
    $json = $WebResponse.Content | ConvertFrom-Json
    $json = $json[0]
    $dl = [PSCustomObject]@{
        ver = [System.Version]::Parse("0." + ($json.tag_name).Replace("v","") + ".0") # 0. + 5.1.6 = 0.5.1.6
        url = $json.assets.browser_download_url # https://github.com/xNVSE/NVSE/releases/download/5.1.6/nvse_5_1_beta6.7z
        file = $json.assets.name # nvse_5_1_beta6.7z
    }
    $subfolder = ($dl.file).Replace('.7z','') # f4se_0_06_20
} ElseIf ($SEGame -eq "F4SE") {
    $GameName = "Fallout4"
    # 20240718 - Adding new code to check the game version and determine the correct F4SE version to download due to the overhaul patch in April 2024
    # This is going to be weird for a while, until ianpatt adds the 0.7.2 release to the Github repo (currently only available on NexusMods)
    # Also this is in prep for Fallout: London, which will only work with the pre-overhaul patch version of Fallout 4
    Get-GamePath
    $currentGameVer = (Get-Item "$gamepath\Fallout4.exe").VersionInfo.FileVersion
    if ($currentGameVer -eq "1.10.163.0") { # game version 1.10.163.0 is pre-overhaul patch, and uses F4SE 0.6.23
        $url = "https://api.github.com/repos/ianpatt/$($SEGame)/releases"
        $WebResponse = Invoke-WebRequest $url -Headers @{"Accept"="application/json"} -UseBasicParsing
        $json = $WebResponse.Content | ConvertFrom-Json
        $json = $json | Where-Object { $_.assets.name -eq "f4se_0_06_23.7z" }
        $dl = [PSCustomObject]@{
            ver = [System.Version]::Parse("0." + ($json.tag_name).Replace("v","")) # 0. + 5.1.6 = 0.5.1.6
            url = $json.assets.browser_download_url # https://github.com/xNVSE/NVSE/releases/download/5.1.6/nvse_5_1_beta6.7z
            file = $json.assets.name # nvse_5_1_beta6.7z
        }
        $subfolder = ($dl.file).Replace('.7z','') # f4se_0_06_20
    } else { # otherwise assume the game is post-overhaul patch, and uses F4SE 0.7.2+ from NexusMods
        If ($nexusAPI -eq "") { Write-Log -Level Error -Message "Nexus API Key is empty" ; Exit }
        $nexusgameID = "fallout4"
        $nexusmodID = "42147"
        $nexusfileindex = "-1"
        $url = "https://api.nexusmods.com"
        Get-NexusMods
    }
} ElseIf ($SEGame -eq "F76SFE") {
    If ($nexusAPI -eq "") { Write-Log -Level Error -Message "Nexus API Key is empty" ; Exit }
    $GameName = "Fallout76"
    $nexusgameID = "fallout76"
    $nexusmodID = "287"
    $nexusfileindex = "-1"
    $url = "https://api.nexusmods.com"
    Get-NexusMods
    # And because SFE isn't exactly standard, we have to do some extra parsing.
	Get-GamePath
    If (Test-Path "$gamepath\dxgi.dll") {
        $currentSE = (Get-Item "$gamepath\dxgi.dll").VersionInfo.FileVersion # 0, 0, 6, 20
        If ($currentSE -is [System.Array]) { $currentSE = $currentSE[0] }
        $currentSE = [System.Version]::Parse($currentSE.Replace(', ','.'))
    } Else {
        $currentSE = [System.Version]::Parse("0.0.0.0") # Means you don't have it
    }
    $subfolder = ($dl.file).Replace('.7z','')
    $useSubfolder = $true
} ElseIf ($SEGame -eq "NVSE") {
    $GameName = "Fallout New Vegas"
    # NVSE went to a community Github in May 2020
    # https://github.com/xNVSE/NVSE
    $url = "https://api.github.com/repos/xNVSE/$($SEGame)/releases"
    $WebResponse = Invoke-WebRequest $url -Headers @{"Accept"="application/json"}
    $json = $WebResponse.Content | ConvertFrom-Json
    $json = $json[0]
    $dl = [PSCustomObject]@{
        ver = [System.Version]::Parse("0." + $json.tag_name)
        url = $json.assets.browser_download_url
        file = $json.assets.name
    }
    $subfolder = ($dl.file).Replace('.7z','') # nvse_5_1_beta6
    $useSubfolder = $true
} ElseIf ($SEGame -eq "FOSE") {
    # https://www.nexusmods.com/fallout3/mods/8606
    $GameName = "Fallout 3"
    $nexusgameID = "fallout3"
    $nexusmodID = "8606"
    $nexusfileindex = "-1"
    Get-NexusMods
    # FOSE in a post-GFWL has a tag of -newloader, need to trim that off to work properly.
    $global:dl = [PSCustomObject]@{
        ver = [System.Version]::Parse("0.$(($json.version).Replace('-newloader',''))")
        url = $dlResponse.URI
        file = $json.file_name
    }
    $subfolder = ($dl.file).Replace('.7z','') # nvse_5_1_beta6
} ElseIf ($SEGame -eq "MWSE") {
    # TODO Need to validate
    If ($nexusAPI -eq "") { Write-Log -Level Error -Message "Nexus API Key is empty" ; Exit }
    $GameName = "Morrowind"
    $nexusmodID = "45468"
    $nexusgameID = "morrowind"
    $nexusfileindex = "-1"
    Get-NexusMods
} ElseIf ($SEGame -eq "SFSE") {
    # TODO Need to validate
    If ($nexusAPI -eq "") { Write-Log -Level Error -Message "Nexus API Key is empty" ; Exit }
    $GameName = "Starfield"
    $nexusmodID = "106"
    $nexusgameID = "starfield"
    $nexusfileindex = "-1"
    Get-NexusMods
    $subfolder = "$($SEGame.ToLower())_$($dl.nexusver.Replace('.','_'))"
    # TODO Archive Invalidation
    <#
    C:\Users\<USER>\Documents\my games\Starfield
    StarfieldCustom.ini
    [Archive]
    bInvalidateOlderFiles=1
    sResourceDataDirsFinal=
    #>
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
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDhmae72Bvu0Evo
# 16rt1/KOK8gdHV0uWsuQAlv4kswRYqCCB0IwggN5MIIC/qADAgECAhAcz51nzeIZ
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
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAJUeHK/h0hRvEDCh5C
# qeE/xwwRIySbDrP2K1W9AFHshDALBgcqhkjOPQIBBQAEZzBlAjAgkneNETQ6Rcfl
# G4JWMjOQKp0BKBtLtlm2Wbsz+kCwGGEJg+Kh1EUdGxOJ2Hopi5wCMQCNiaZ5LLJG
# 1M9/AWbbfNnIAzc4/1pfBmVQF565y2M0uBuGLXp7Yf3DPMZaH++foJKhgg8VMIIP
# EQYKKwYBBAGCNwMDATGCDwEwgg79BgkqhkiG9w0BBwKggg7uMIIO6gIBAzENMAsG
# CWCGSAFlAwQCATB3BgsqhkiG9w0BCRABBKBoBGYwZAIBAQYMKwYBBAGCqTABAwYB
# MDEwDQYJYIZIAWUDBAIBBQAEIKsPrVQfdEVfX2f6tlbiKNC29lYd4H8TWTvpowQT
# WsTUAggi6FznilsgCRgPMjAyNTAyMDcwMTQ2NTBaMAMCAQGgggwAMIIE/DCCAuSg
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
# V76s3WwMPgKk1bAEFMj+rRXimSC+Ev30hXZdqyMdl/il5Ksd0vhGMYICVzCCAlMC
# AQEwgYcwczELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdI
# b3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNvbSBUaW1l
# c3RhbXBpbmcgSXNzdWluZyBSU0EgQ0EgUjECEFparOgaNW60YoaNV33gPccwCwYJ
# YIZIAWUDBAIBoIIBYTAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwHAYJKoZI
# hvcNAQkFMQ8XDTI1MDIwNzAxNDY1MFowKAYJKoZIhvcNAQk0MRswGTALBglghkgB
# ZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIEJCruywMKtVfhqI5Es+
# RopSNz92ZjA5+pGo/KgvxsLrMIHJBgsqhkiG9w0BCRACLzGBuTCBtjCBszCBsAQg
# nXF/jcI3ZarOXkqw4fV115oX1Bzu2P2v7wP9Pb2JR+cwgYswd6R1MHMxCzAJBgNV
# BAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UE
# CgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5nIElzc3Vp
# bmcgUlNBIENBIFIxAhBaWqzoGjVutGKGjVd94D3HMAoGCCqGSM49BAMCBEYwRAIg
# OOFQoFlsUZtulb6eEYsrIo7Rt6hNAvDP5BuP+wyS6rsCIFXAe9E3QyoISjwexQT0
# KDEeF3q3iaRQPWpia7nLVK6K
# SIG # End signature block
