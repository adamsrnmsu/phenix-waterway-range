#!/bin/bash
# usage: shot_hmi.sh <out.png>  -- FUXA HMI screenshot via minimega
limactl shell phenix sudo docker exec minimega mm namespace waterway vm screenshot hmi file /tmp/hmi-shot.png >/dev/null 2>&1
limactl shell phenix sudo docker cp minimega:/tmp/hmi-shot.png /tmp/hmi-shot.png && limactl cp phenix:/tmp/hmi-shot.png "$1"
