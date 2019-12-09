#!/bin/bash

# Build URL and cURL opts
source ~/bin/video/pms/curl.sh

IFS=''
curl ${CURL_OPTS[@]} "${PMS_URL}/library/sections" | \
	grep '<Directory ' | sed 's%^.* key="\([0-9]*\)".*$%\1%'
