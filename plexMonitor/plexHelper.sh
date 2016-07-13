#!/bin/bash

# Always re-trigger a mount (to fix links if the network changes)
~/bin/video/mountMedia

# Wait for the media share to be mounted
if ! ~/bin/video/isMediaMounted; then
	sleep 5
	exit 1
fi

# Kill previous instances
killall OpenPHT
killall 'Plex Home Theater'
killall 'Plex Media Player'

# Exec
exec '/Applications/Zach/Media/OpenPHT.app/Contents/MacOS/OpenPHT'
#exec '/Applications/Zach/Media/Plex Home Theater.app/Contents/MacOS/Plex Home Theater'
#exec '/Applications/Zach/Media/Plex Media Player.app/Contents/MacOS/Plex Media Player'
