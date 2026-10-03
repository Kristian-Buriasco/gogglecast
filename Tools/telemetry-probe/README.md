# telem_probe.py

Read-only DUML prober for the goggles' vendor control interface (IF4, bulk EP
0x04 out / 0x85 in). Sends empty-payload "get"-style commands (no set/start/
stop/erase/upgrade commands; filtered by name) to every reachable DUML address
and logs replies to `~/telem/probe.jsonl`.

Needs: the goggles in OTG-computer mode, the GogglesHelper daemon stopped
(`sudo pkill -9 -f "GogglesHelper --xpc"`) so IF4 is free, `pip install pyusb`,
libusb (`DYLD_LIBRARY_PATH=/opt/homebrew/lib`), and the lab notes at
`~/PycharmProjects/dji-goggles3-videoout` (`duml.py` codec and
`duml-commands.md` command table).
