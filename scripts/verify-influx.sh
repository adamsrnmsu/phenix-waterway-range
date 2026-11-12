#!/bin/bash
# Runs ON the historian (use .build/ccrun.sh historian scripts/verify-influx.sh): lock.height rows in the last 5 min.
export INFLUX_HOST=http://127.0.0.1:8086 INFLUX_TOKEN=waterway-historian-token INFLUX_ORG=sceptre
influx query 'from(bucket:"waterway")|>range(start:-5m)|>filter(fn:(r)=>r._field=="lock.height")|>group(columns:["rtu"])|>count()' 
echo ---- last values
influx query 'from(bucket:"waterway")|>range(start:-5m)|>filter(fn:(r)=>r._field=="lock.height" and r.rtu=="rtu-1")|>tail(n:5)|>keep(columns:["_time","_value","rtu"])'
