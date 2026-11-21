-- NXM Handler: receives nxm:// links from the browser and hands them to nxm-fetch.py in the background.
on open location theURL
	set homePath to POSIX path of (path to home folder)
	set fetcher to homePath & ".local/bin/nxm-fetch.py"
	set logFile to homePath & "Library/Logs/nxm-handler.log"
	do shell script "/usr/bin/nohup /usr/bin/python3 " & quoted form of fetcher & " " & quoted form of theURL & " >> " & quoted form of logFile & " 2>&1 &"
end open location

on run
	display dialog "NXM Handler is installed. On a Nexus Mods page click “Mod Manager Download”; the archive is fetched into ~/Games and, for Skyrim SE, installed by skymod." buttons {"OK"} default button 1
end run
