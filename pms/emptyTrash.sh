#!/bin/bash

# Bail if the media share isn't mounted
if ! ~/bin/video/isMediaMounted; then
	exit 0
fi

# Bail if we are already scanning
if ~/bin/video/pms/isScanning.sh; then
	exit 0
fi

# Empty the trash for each section
for i in `~/bin/video/pms/sections.sh`; do
	curl --silent --upload-file /dev/null "http://localhost:32400/library/sections/${i}/emptyTrash"
done
