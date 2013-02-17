#!/bin/bash

# Wait for the media share to be mounted
if ! ~/bin/video/isMediaMounted; then
	~/bin/video/mountMedia
	sleep 5
	exit 1
fi

# Kill previous instances
~/bin/video/pms/killPMS.sh

# Exec
exec '/Applications/Zach/Media/Plex Media Server.app/Contents/MacOS/Plex Media Server'
