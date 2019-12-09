#!/bin/bash

SCAN_CMD="/Applications/Zach/Media/Plex Media Server.app/Contents/MacOS/Plex Media Scanner"

# Default to "scan" if no action is provided
if ! echo "${@}" | grep -q -E -- '--(refresh|analyze|index|scan|info|list|generate|tree|reset|add-section|del-section)'; then
	exec "${0}" '--scan' ${@}
fi

# Bail if the media share isn't mounted
if ! ~/bin/video/isMediaMounted; then
	exit 0
fi

# Bail if we are already scanning
if ~/bin/video/pms/isScanning.sh; then
	exit 0
fi

# Scan each section individually if no scope is provided
if echo "${@}" | grep -q -E -- '--(section|item|directory|file)'; then
	"${SCAN_CMD}" ${@}
else
	for i in `~/bin/video/pms/sections.sh`; do
		if [ -n "${QUIET}" ]; then
			"${SCAN_CMD}" --section "${i}" ${@} >/dev/null 2>&1
		else
			"${SCAN_CMD}" --section "${i}" ${@}
		fi
	done
fi

# Empty the trash if we scanned and conditions are safe
if echo "${@}" | grep -q -- '--scan'; then
	~/bin/video/pms/emptyTrash.sh
fi
