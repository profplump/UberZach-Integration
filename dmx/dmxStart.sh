#!/bin/sh

LA_DIR="${HOME}/Library/LaunchAgents"
if [ ! -d "${LA_DIR}" ]; then
	echo "Invalid LaunchAgents directory: ${LA_DIR}" 1>&2
	exit 1
fi
cd $LA_DIR

BIN="${HOME}/bin/video/dmx/dmxLauncher.sh"
if [ ! -x "${BIN}" ]; then
	echo "Invalid binary: ${BIN}" 1>&2
	exit 2
fi

# Unload the jerky version
launchctl unload com.uberzach.ola.dmx.plist
# Unload all deps, which will automatially stop when OLA does
for i in com.uberzach.ola.*.plist; do
	if [ "${i}" == "com.uberzach.ola.plist" ]; then
		continue
	elif [ "${i}" == "com.uberzach.ola.dmx.plist" ]; then
		continue
	elif [ "${i}" == "com.uberzach.ola.rave.plist" ]; then
		continue
	fi
	launchctl unload "${i}"
done

# Launch the non-jerky version
${HOME}/bin/video/dmx/dmxLauncher.sh &
sleep 2

# Reload all the deps
for i in com.uberzach.ola.*.plist; do
	if [ "${i}" == "com.uberzach.ola.plist" ]; then
		continue
	elif [ "${i}" == "com.uberzach.ola.dmx.plist" ]; then
		continue
	elif [ "${i}" == "com.uberzach.ola.rave.plist" ]; then
		continue
	fi
	launchctl load "${i}"
done

launchctl list | grep uberzach
echo
echo "launchctl list | grep uberzach"
exit 0
