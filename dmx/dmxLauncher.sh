#!/bin/sh

# Ensure we have a valid TMP path
if [ -z "${TMPDIR}" ]; then
	TMPDIR="/tmp"
fi
if [ ! -d "${TMPDIR}" ]; then
	echo "Invalid TMPDIR: ${TMPDIR}" 1>&2
	exit 1
fi

# Grab the existing PID, if any
PID=0
PIDFILE="${TMPDIR}/dmx.pid"
if [ -s "${PIDFILE}" ]; then
	read p < "${PIDFILE}"
	if [ -n "${p}" ] && [ $p -gt 1 ]; then
		PID=$p
	fi
fi

# Validate the PID, if it exists
if [ $PID -gt 1 ]; then
	if ! ps -o command= -p "${PID}" | \
		grep -q -E '^\S+/Python.app/Contents/MacOS/Python /Users/tv/bin/video/dmx/dmx.py'; then
			PID=0
	fi
fi

# Exit if we're running
if [ $PID -gt 1 ]; then
	exit 0
fi

# Launch if we are not running
echo $$ > "${PIDFILE}"
exec "${HOME}/bin/video/dmx/dmx.py"
