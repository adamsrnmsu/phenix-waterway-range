Q() { echo "=== $1 ==="; curl -sk -m 60 --config /opt/malcolm/.opensearch.primary.curlrc -H 'Content-Type: application/json' "https://127.0.0.1:9200/arkime_sessions3-*/$2" ${3:+-d "$3"}; echo; }
Q count-iccp  _count '{"query":{"term":{"event.dataset":"iccp"}}}'
Q count-mms   _count '{"query":{"term":{"event.dataset":"mms"}}}'
Q iccp-by-class _search?size=0 '{"query":{"term":{"event.dataset":"iccp"}},"aggs":{"class":{"terms":{"field":"zeek.iccp.class","size":20}},"op":{"terms":{"field":"zeek.iccp.op"}}}}'
Q mms-by-service _search?size=0 '{"query":{"term":{"event.dataset":"mms"}},"aggs":{"svc":{"terms":{"field":"zeek.mms.mms_service","size":20}},"pdu":{"terms":{"field":"zeek.mms.pdu"}}}}'
Q sample-iccp _search?size=1 '{"query":{"bool":{"filter":[{"term":{"event.dataset":"iccp"}},{"term":{"zeek.iccp.class":"data"}}]}},"sort":[{"@timestamp":"desc"}]}'
Q sample-mms _search?size=1 '{"query":{"bool":{"filter":[{"term":{"event.dataset":"mms"}},{"term":{"zeek.mms.pdu":"confirmed_resp"}}]}},"sort":[{"@timestamp":"desc"}]}'
Q weird _search?size=3 '{"query":{"bool":{"filter":[{"term":{"event.dataset":"weird"}},{"term":{"zeek.weird.source":"ICCP"}}]}}}'
echo "=== index-pattern fields ==="
curl -sk -m 60 -u 'admin:MalcolmBlue1!' 'https://127.0.0.1/dashboards/api/saved_objects/index-pattern/arkime_sessions3-*' | python3 -c 'import sys,json;d=json.load(sys.stdin);f=[x["name"] for x in json.loads(d["attributes"]["fields"]) if x["name"].startswith(("zeek.iccp.","zeek.mms."))];print(len(f),"fields",f)'
echo "=== zeek packages ==="; docker exec malcolm-zeek-live-1 true 2>/dev/null; docker ps --format '{{.Names}}' | grep zeek | head -2
