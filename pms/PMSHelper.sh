#!/bin/bash

# Run interactively if requested
INTERACTIVE=0
if basename "${0}" | grep -iq interactive; then
	INTERACTIVE=1
fi

# This looks like it always loops
# But if we exec at the end bash just goes away and the loop doesn't matter
while [ 1 ]; do

	# Always re-trigger a mount (to fix links if the network changes)
	~/bin/video/mountMedia

	# Wait for the media share to be mounted
	if ! ~/bin/video/isMediaMounted; then
		sleep 5
		if [ $INTERACTIVE -gt 0 ]; then
			continue
		else
			exit 1
		fi
	fi

	# Kill previous instances
	~/bin/video/pms/killPMS.sh

	# Exec
	EXEC=""
	if [ $INTERACTIVE -le 0 ]; then
		EXEC="exec"
	fi
	$EXEC '/Applications/Zach/Media/Plex Media Server.app/Contents/MacOS/Plex Media Server'
done
