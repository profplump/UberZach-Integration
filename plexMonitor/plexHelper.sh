#!/bin/bash

# Wait for the media share to be mounted
if ! ~/bin/video/isMediaMounted; then
	~/bin/video/mountMedia
	sleep 5
	exit 1
fi

# Kill previous instances
killall Plex

# Exec
exec '/Applications/Zach/Media/Plex Home Theater.app/Contents/MacOS/Plex Home Theater'
