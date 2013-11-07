#!/bin/bash

# Bail if the media share isn't mounted
if ! ~/bin/video/isMediaMounted; then
	exit 0
fi

# Bail if we are already scanning
if ~/bin/video/pms/isScanning.sh; then
	exit 0
fi

# Scan, appending any parameters passed to us
'/Applications/Zach/Media/Plex Media Server.app/Contents/MacOS/Plex Media Scanner' --scan ${@}

# Check the return; kill the PMS if things did not go well
if [ $? -ne 0 ]; then
	~/bin/video/pms/killPMS.sh
fi

# Force an optimization after deep scans
if echo "${@}" | grep -q -- '--deep'; then
	~/bin/video/pms/optimize.sh
fi

# Clean the trash, if conditions are safe
~/bin/video/pms/emptyTrash.sh
