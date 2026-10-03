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

# telem_register.py

Registration experiment (see `docs/telemetry-registration-sequence.md`): it sends, as
app `0x02`, the `00:88` "APP" registration that DJI Fly sends (identical byte for byte to a real N3 capture),
1 Hz heartbeat candidates, a few gets, and the N3 `00:99 camcap_common` DDS subscribe.
It auto-answers device `00:88/0x19` queries and prints every new `src>dst set:id` with its
count and Hz. Log: `~/telem/register-<ts>.jsonl`.

    sudo pkill -9 -f "GogglesHelper --xpc"
    sudo DYLD_LIBRARY_PATH=/opt/homebrew/lib <venv>/bin/python3 telem_register.py
