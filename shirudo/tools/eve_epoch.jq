# Suricata timestamp ("2026-11-26T05:23:29.379018+0000", any offset, or Z) -> epoch seconds. Used by collect.sh.
def eve_epoch:
  sub("\\.[0-9]+"; "")
  | capture("^(?<d>.{19})(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2}))$")
  | ((.d + "Z") | fromdateiso8601)
    - (if .z == "Z" then 0 else ((.h | tonumber) * 3600 + (.m | tonumber) * 60) * (if .s == "+" then 1 else -1 end) end);
