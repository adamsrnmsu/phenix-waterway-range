#!/usr/bin/env python3
"""xpcap.py <cc-output.txt> <out.pcap> : pull the base64 pcap out of a cc response and strip it from the text file."""
import base64, re, sys
s = open(sys.argv[1]).read()
m = re.search(r"PCAP-B64-BEGIN\n(.*?)\nPCAP-B64-END\n?", s, re.S)
open(sys.argv[2], "wb").write(base64.b64decode(m.group(1)))
open(sys.argv[1], "w").write(s[:m.start()] + "(pcap saved as " + sys.argv[2].rsplit("/", 1)[-1] + ")\n" + s[m.end():])
