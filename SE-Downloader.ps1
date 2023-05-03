<#
Silverlock Script Extender Downloader

The Silverlock Team builds script extensions for Bethesda games, expanding the modding capability said games.
Currently supports:
    Fallout 3 (FOSE)
    Fallout: New Vegas (NVSE)
    Fallout 4 (F4SE)
	Fallout 76 (only the SFE tool for Text Chat and Perk Loader mods) (F76SFE)
    Skyrim Special/Anniversary Edition (SKSE64)
        GOG version needs validation
    Skyrim Original Edition (No Longer Updated!) (SKSE)
    Skyrim VR (SKSEVR)
    Oblivion (OBSE)

Nexusmods API Reference: https://app.swaggerhub.com/apis-docs/NexusMods/nexus-mods_public_api_params_in_form_data/1.0#/
Nexusmods API AUP: https://help.nexusmods.com/article/114-api-acceptable-use-policy

Checks matching Silverlock SE page for latest file version against locally installed
Updates if available
Runs if flag set

Parameters:
    -SEGame <designation> (four character game designation on silverlock.org)
    -RunGame (bool, default false)
    -dlkeep (bool, default false)
    -hardpath (string, file path to game folder)
    -nexusAPI (string, generated from https://www.nexusmods.com/users/myaccount?tab=api)

Usage:
    se-downloader.ps1 -SEGame F4SE -RunGame
        Checks game for Fallout 4 Script Extender, and launches the game when completed
    se-downloader.ps1 -SEGame FOSE -hardpath "G:\FO3GOTY"
        Checks game for Fallout 3 with a direct install path
    se-downloader.ps1 -SEGame SKSE64
        Checks game for Skyrim Special Edition Script Extender
    se-downloader.ps1 -SEGame F76SFE -dlkeep -nexusAPI "NexusMods API Key"
        Checks game for Fallout 76 SFE, an overlay DLL for Text Chat, requires NexusMods API Key, and does not delete the extracted download

#>

param(
    [Parameter(Mandatory)]
    [ValidateSet("FOSE","NVSE","F4SE","F76SFE","OBSE","SKSE","SKSE64","SKSEVR")]
    [string]$SEGame,

    [Parameter()]
    [switch]$RunGame = $false,

    [Parameter()]
    [switch]$dlkeep = $false,

    [Parameter()]
    [string]$hardpath,

    [Parameter()]
    [string]$nexusAPI # NexusMods API Key (https://www.nexusmods.com/users/myaccount?tab=api)
)

<#  # For Debug
$SEGame = "FOSE"
$RunGame = $false 
#$dlkeep = $true
$nexusAPI = Get-Content ..\nexus.api #>

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
$nexusHeaders = @{
    "Accept"="application/json"
    "apikey"="$nexusAPI"
}

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
    If ($nexusAPI = "") { Write-Log -Level Error -Message "Nexus API Key is empty" ; Exit }
    $GameName = "Skyrim VR"
    $nexusmodID = "30457"
    $nexusgameID = "skyrimspecialedition"
    $url = "https://api.nexusmods.com"
    $WebResponse = (Invoke-WebRequest "https://api.nexusmods.com/v1/games/$nexusgameID/mods/$nexusmodID/files.json" -Headers $nexusHeaders -UseBasicParsing).Content | ConvertFrom-Json | Select-Object -Property @{L='files';E={$_.files[0]}}
    $json = $WebResponse.files
    $latestfileid = $json.file_id[0]
    $dlResponse = (Invoke-WebRequest "https://api.nexusmods.com/v1/games/$nexusgameID/mods/$nexusmodID/files/$latestfileid/download_link.json" -Headers $nexusHeaders).Content | ConvertFrom-Json | Select-Object -Property @{L='URI';E={$_.URI[0]}}
    $dl = [PSCustomObject]@{
        ver = [System.Version]::Parse("0.$($json.version)")
        url = $dlResponse.URI
        file = $json.file_name
    }
    $subfolder = ($dl.file).Replace('.7z','') # f4se_0_06_20
} ElseIf ($SEGame -eq "SKSE") {
    # TODO Need to validate
    If ($nexusAPI = "") { Write-Log -Level Error -Message "Nexus API Key is empty" ; Exit }
    $GameName = "Skyrim"
    $nexusmodID = "100216"
    $nexusgameID = "skyrim"
    $url = "https://api.nexusmods.com"
    $WebResponse = (Invoke-WebRequest "https://api.nexusmods.com/v1/games/$nexusgameID/mods/$nexusmodID/files.json" -Headers $nexusHeaders -UseBasicParsing).Content | ConvertFrom-Json | Select-Object -Property @{L='files';E={$_.files[0]}}
    $json = $WebResponse.files
    $latestfileid = $json.file_id[0]
    $dlResponse = (Invoke-WebRequest "https://api.nexusmods.com/v1/games/$nexusgameID/mods/$nexusmodID/files/$latestfileid/download_link.json" -Headers $nexusHeaders).Content | ConvertFrom-Json | Select-Object -Property @{L='URI';E={$_.URI[0]}}
    $dl = [PSCustomObject]@{
        ver = [System.Version]::Parse("0.$($json.version)")
        url = $dlResponse.URI
        file = $json.file_name
    }
    $subfolder = ($dl.file).Replace('.7z','') # f4se_0_06_20
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
    $url = "https://api.github.com/repos/ianpatt/$($SEGame)/releases"
    $WebResponse = Invoke-WebRequest $url -Headers @{"Accept"="application/json"} -UseBasicParsing
    $json = $WebResponse.Content | ConvertFrom-Json
    $json = $json[0]
    $dl = [PSCustomObject]@{
        ver = [System.Version]::Parse("0." + ($json.tag_name).Replace("v","")) # 0. + 5.1.6 = 0.5.1.6
        url = $json.assets.browser_download_url # https://github.com/xNVSE/NVSE/releases/download/5.1.6/nvse_5_1_beta6.7z
        file = $json.assets.name # nvse_5_1_beta6.7z
    }
    $subfolder = ($dl.file).Replace('.7z','') # f4se_0_06_20
} ElseIf ($SEGame -eq "F76SFE") {
    If ($nexusAPI = "") { Write-Log -Level Error -Message "Nexus API Key is empty" ; Exit }
    $GameName = "Fallout76"
    $url = "https://api.nexusmods.com"
    $WebResponse = (Invoke-WebRequest "https://api.nexusmods.com/v1/games/fallout76/mods/287/files.json" -Headers $nexusHeaders).Content | ConvertFrom-Json | Select-Object -Property @{L='files';E={$_.files[-1]}}
    $json = $WebResponse.files
    $latestfileid = $json.id[0]
    $dlResponse = (Invoke-WebRequest "https://api.nexusmods.com/v1/games/fallout76/mods/287/files/$latestfileid/download_link.json" -Headers $nexusHeaders).Content | ConvertFrom-Json | Select-Object -Property @{L='URI';E={$_.URI[0]}}
    $dl = [PSCustomObject]@{
        ver = [System.Version]::Parse("0.$($json.version)")
        url = $dlResponse.URI
        file = $json.file_name
    }
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
    $url = "https://api.github.com/repos/x$($SEGame)/$($SEGame)/releases"
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
    $GameName = "Fallout 3"
    $subfolder = ($dl.file).Replace('.7z','') # nvse_5_1_beta6
    $useSubfolder = $true
} 

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
    Write-Log -Message "Cleaning up extracted files from $($gamepath)\$($subfolder)" -Level Info
    If ($dlkeep -eq $false) { Remove-Item -Path $gamepath\$subfolder -Recurse -Force }
} Else {
    Write-Log -Message "Source version ($($dl.ver)) is NOT higher than Local version ($currentSE), no action taken" -Level Info
}
If ($RunGame) {
    If ($SEGame -eq "F76SFE") {
        Write-Log -Message "RunGame flag True, running Fallout76.exe" -Level Info
        Start-Process -FilePath "$gamepath\Fallout76.exe" -WorkingDirectory $gamepath -PassThru
    } Else {
        Write-Log -Message "RunGame flag True, running $($SEGame)_loader.exe" -Level Info
        Start-Process -FilePath "$gamepath\$($SEGame)_loader.exe" -WorkingDirectory $gamepath -PassThru
    }
}