#!/bin/bash

SCAN_CMD="/Applications/Zach/Media/Plex Media Server.app/Contents/MacOS/Plex Media Scanner"

# Bail if the media share isn't mounted
if ! ~/bin/video/isMediaMounted; then
	exit 0
fi

# Bail if we are already scanning
if ~/bin/video/pms/isScanning.sh; then
	exit 0
fi

# Scan each section individually if no section number is provided
if echo "${@}" | grep -q -- '--section'; then
	"${SCAN_CMD}" --scan ${@}
else
	for i in `~/bin/video/pms/sections.sh`; do
		"${SCAN_CMD}" --section "${i}" --scan ${@}
	done
fi

# Check the return; kill the PMS if things did not go well
if [ $? -ne 0 ]; then
	~/bin/video/pms/killPMS.sh
fi

# Clean the trash, if conditions are safe
~/bin/video/pms/emptyTrash.sh

# Force an optimization after deep scans
if echo "${@}" | grep -q -- '--deep'; then
	~/bin/video/pms/optimize.sh
fi
