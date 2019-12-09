#!/bin/bash

# Build URL and cURL opts
source ~/bin/video/pms/curl.sh

# Bail if the media share isn't mounted
if ! ~/bin/video/isMediaMounted; then
	exit 0
fi

# Bail if we are already scanning
if ~/bin/video/pms/isScanning.sh; then
	exit 0
fi

# Empty the trash for each section
IFS=$'\n'
for i in `~/bin/video/pms/sections.sh`; do
	curl ${CURL_OPTS[@]} --upload-file /dev/null "${PMS_URL}/library/sections/${i}/emptyTrash"
done
