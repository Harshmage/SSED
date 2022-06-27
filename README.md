Powershell scripting that downloads and extracts the Silverlock Script Extenders for most Bethesda Gamebryo/Creation Engine games.

The Silverlock Team builds script extensions for Bethesda games, expanding the modding capability said games.
Currently supports:
    Fallout 3
    Fallout: New Vegas
    Fallout 4
    Skyrim Special Edition
    
To Do:
    Skyrim - Plain Jane Elder Scrolls 5: Skyrim.  Should work, but I've not tested it
    Oblivion - The page and file format are radically different from the others, and has not been updated since 2013, so I'll get to it eventually.
    
Checks matching Silverlock SE page for latest file version against locally installed
Updates if available
Runs if flag set

Parameters:
    -SEGame <designation> (four character game designation on silverlock.org)
    -RunGame (bool, default false)
Usage:
    se-downloader.ps1 -SEGame F4SE -RunGame
        Checks game for Fallout 4 Script Extender, and launches the game when completed
    se-downloader.ps1 -SEGame SKSE64
        Checks game for Skyrim Special Edition Script Extender
