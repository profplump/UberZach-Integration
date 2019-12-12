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
launchctl unload com.uberzach.ola.plist
# Unload all deps, which will automatially stop when OLA does
for i in com.uberzach.ola.*.plist; do
	launchctl unload "${i}"
done

# Launch the non-jerky version
${HOME}/bin/video/dmx/dmxLauncher.sh &
sleep 2

# Reload all the deps
for i in com.uberzach.ola.*.plist; do
	launchctl load "${i}"
done

echo
echo "Success"
exit 0
