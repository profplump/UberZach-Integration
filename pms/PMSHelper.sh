#!/bin/bash

# Always re-trigger a mount (to fix links if the network changes)
~/bin/video/mountMedia

# Wait for the media share to be mounted
if ! ~/bin/video/isMediaMounted; then
	sleep 5
	exit 1
fi

# Kill previous instances
~/bin/video/pms/killPMS.sh

# Exec
exec '/Applications/Zach/Media/Plex Media Server.app/Contents/MacOS/Plex Media Server'
