#!/bin/bash

# Init CURL_OPTS if it's not set
if [ -z ${CURL_OPTS+x} ]; then
	IFS=''
	CURL_OPTS=(--silent --connect-timeout 5 --max-time 30)
fi

# Construct URL
if [ -z "${PMS_URL}" ]; then
	if [ -z "${PMS_HOST}" ]; then
		PMS_HOST="localhost"
	fi
	if [ -z "${PMS_PORT}" ]; then
		PMS_PORT=32400
	fi
	PMS_URL="https://${PMS_HOST}:${PMS_PORT}"
fi

# Append the token
if [ -z "${PMS_TOKEN}" ]; then
	echo "No PMS_TOKEN provided" 1>&2
else
	CURL_OPTS+=(-H "X-Plex-Token: ${PMS_TOKEN}")
fi
