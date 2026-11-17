# run on kali: Modbus bench of both RTUs (input + holding registers) with the mb.py sent alongside
cd /tmp/miniccc/files; M=$(ls -t *mb.py | head -1)
date -u +%FT%TZ
for h in 10.1.1.101 10.1.1.102; do
  python3 $M bench $h 4 30000 2000
  python3 $M bench $h 3 40000 2000
done
