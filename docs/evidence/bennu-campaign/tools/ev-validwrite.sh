cd /tmp/miniccc/files; M=$(ls -t *mb.py | head -1)
echo "--- positive control: well-formed FC16 addr 40000 qty 1 bytecount 2 data 0000"; python3 $M raw 10.1.1.101 109c400001020000
echo "--- well-formed FC16 with 2 registers 40000-40001"; python3 $M raw 10.1.1.101 109c4000020400000000
