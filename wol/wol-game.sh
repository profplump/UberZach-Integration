#!/bin/bash
if [ -e ~/.bashrc ]; then
	source ~/.bashrc
fi

exec wol.sh d8:cb:8a:9c:de:56 172.19.1.255
