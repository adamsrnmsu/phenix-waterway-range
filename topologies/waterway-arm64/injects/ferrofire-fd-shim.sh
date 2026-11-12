#!/bin/sh
# Stand-in for bennu-field-deviced on the DNP3 range: runs ferrofire's field device (Modbus 502 + DNP3 20000 from the
# sceptre config.xml). bennu-watcherd calls `bennu-field-deviced --c start|stop --env default --file <xml>`.
# ponytail: shim instead of native --c/--env support in ferrofire (field-device-spec 2.3); replace when ferrofire grows an argv0 drop-in.
PID=/run/ferrofire-field-device.pid
LOG=/var/log/ferrofire-field-device.log
cmd=; file=
while [ $# -gt 0 ]; do
  case $1 in
    --c) cmd=$2; shift 2 ;;
    --file) file=$2; shift 2 ;;
    --env) shift 2 ;;
    *) shift ;;
  esac
done
stop() {
  [ -f "$PID" ] && kill "$(cat "$PID")" 2>/dev/null
  rm -f "$PID"
}
start() {
  [ -n "$file" ] || { echo "bennu-field-deviced shim: --file required" >&2; exit 2; }
  setsid /usr/local/bin/ferrofire field-device --file "$file" </dev/null >>"$LOG" 2>&1 &
  echo $! >"$PID"
}
case $cmd in
  start) start ;;
  stop) stop ;;
  restart) stop; sleep 1; start ;;
  *) echo "bennu-field-deviced shim: unsupported --c '$cmd' (start|stop|restart)" >&2; exit 2 ;;
esac
