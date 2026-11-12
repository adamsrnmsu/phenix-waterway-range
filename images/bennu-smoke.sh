#!/bin/sh
# Mirrors sceptre-bennu .github/workflows/build.yml "test bennu". Run in bennu:arm64 with the repo data/ at /data.
cd /tmp; export LD_LIBRARY_PATH=/usr/local/lib
bennu-test-ep-server --d 1 >ep.out 2>&1 &
bennu-field-device --f /data/configs/ep/dnp3-server.xml >fd-server.out 2>&1 &
bennu-field-device --f /data/configs/ep/dnp3-client.xml >fd-client.out 2>&1 &
sleep 5
bennu-probe --c query >probe.out; grep brkr probe.out
sleep 10
bennu-probe --c read --t brkr >>probe.out; bennu-probe --c read --t load-power >>probe.out
sleep 3; grep "brkr:true" probe.out; grep "load-power:400.5" probe.out
echo -e "help\nexit" | bennu-brash >brash.out 2>&1; grep "SCEPTRE Field-Device" brash.out
bennu-watcherd --help >/dev/null; bennu-simulink-provider --help | head -3
pybennu-power-solver --help | head -3
echo SMOKE-DONE
