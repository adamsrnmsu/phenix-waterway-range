# everything-burger switchboard `fuxa` (ebwes-fuxa)

- apps: `e429b7926f` = branch fork/feat-sceptre-linux-fuxa
- bennu: stock bennu.qc2
- topologies: `site route`
- synced 2026-11-10T04:04:39+00:00

| item | check | verdict | reason | paths |
|---|---|---|---|---|
| - | phenix-apps install | ok |  |  |
| - | experiment + VMs running | ok |  |  |
| - | phenix-scorch-validate | ok |  | `/Users/ryanadams/git/everything-burger-with-extra-sauce/work/fuxa/out/models.yaml` |
| health | status start | ok |  | `/Users/ryanadams/git/everything-burger-with-extra-sauce/work/fuxa/results/run-0/health` |
| field-device | vm rtu-1: ss -Hltn '( sport = :502 )' / grep -q . | ok |  |  |
| field-device | vm rtu-2: ss -Hltn '( sport = :502 )' / grep -q . | ok |  |  |
| field-device | vm rtu-1: pgrep -f '(^//)bennu-field-deviced?( /$)' | ok |  |  |
| field-device | vm rtu-2: pgrep -f '(^//)bennu-field-deviced?( /$)' | ok |  |  |
| field-device | vm rtu-1: ep=$(sed -n 's#.*<endpoint>\(tcp://[^<]*\)</endpoint>.*#\1#p | ok |  |  |
| field-device | vm rtu-2: ep=$(sed -n 's#.*<endpoint>\(tcp://[^<]*\)</endpoint>.*#\1#p | ok |  |  |
| simulink-provider | vm waterway-provider: pgrep -f '(^//)bennu-simulink-provider(-helics)?( /$)' | ok |  |  |
| simulink-provider | vm waterway-provider: pgrep -f '(^//)simulinksolver( /$)' | ok |  |  |
| modbus-polled | vm rtu-1: ss -Htn state established '( sport = :502 )' / grep -q . | ok |  |  |
| modbus-polled | vm rtu-2: ss -Htn state established '( sport = :502 )' / grep -q . | ok |  |  |

**PASS**
