#!/bin/bash

killall 'Plex Media Server' >/dev/null 2>&1
killall 'Plex Media Scanner' >/dev/null 2>&1
sleep 1

if ! ~/bin/video/isMediaMounted; then
	sleep 5
	exit 1
fi

exec '/Applications/Zach/Media/Plex Media Server.app/Contents/MacOS/Plex Media Server'
