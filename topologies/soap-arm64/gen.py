#!/usr/bin/env python3
"""soap-arm64-mini: the SOAP power range (sceptre-phenix-topologies/soap) cut down to what the pybennu-power-solver drop-in needs:
power-provider (PyPower, case300) + rtu-1..4 (DNP3 fd-servers). No Ignition/netmonitor/attacker/siren/scorch.
usage: gen.py [PROVIDER_IMAGE]   -> soap-arm64-topology.yaml, soap-arm64-scenario.yaml (ww-1df.9, ww-90o.6)"""
import sys, yaml
img = sys.argv[1] if len(sys.argv) > 1 else 'bennu-ferrofire-arm64.qc2'
adv = {'machine': 'virt', 'vga': 'virtio', 'qemu-append': '-bios /usr/share/AAVMF/AAVMF_CODE.fd'}
def node(host, image, mem, vcpus, ifaces):
    return {'general': {'hostname': host},
            'hardware': {'cpu': 'host', 'memory': mem, 'vcpus': vcpus, 'os_type': 'linux',
                         'drives': [{'image': image, 'interface': 'virtio', 'inject_partition': 2}]},
            'advanced': adv, 'overrides': {'bus=usb-bus.0': 'bus=xhci.0'},
            'network': {'interfaces': ifaces}, 'type': 'VirtualMachine'}
def nic(name, addr, mask, vlan):
    return {'name': name, 'address': addr, 'mask': mask, 'proto': 'static', 'type': 'ethernet', 'vlan': vlan}
nodes = [node('power-provider', img, 2048, 2, [nic('mgmt', '172.16.1.2', 16, 'MGMT')])]
for i in range(1, 5):
    nodes.append(node(f'rtu-{i}', 'bennu-arm64.qc2', 1024, 1,
                      [nic('exp', f'10.117.4.{100 + i}', 24, 'EXP'), nic('mgmt', f'172.16.1.{3 + i}', 16, 'MGMT')]))
topo = {'apiVersion': 'phenix.sandia.gov/v1', 'kind': 'Topology', 'metadata': {'name': 'soap-arm64'}, 'spec': {'nodes': nodes}}
A = '/phenix/topologies/soap-arm64'
def rtu(n, dnp3, infra='power-transmission'):
    return {'hostname': f'rtu-{n}', 'metadata': {'dnp3': [{'name': a, 'type': b} for a, b in dnp3], 'infrastructure': infra,
            'provider': 'power-provider', 'type': 'fd-server'}}
hosts = [{'hostname': 'power-provider', 'metadata': {'case': f'{A}/injects/case300.py', 'publish_endpoint': 'udp://*;239.0.0.1:40000',
                                                      'simulator': 'PyPower', 'type': 'provider'}},
         rtu(1, [('bus-242', 'bus'), ('generator-1_bus-242', 'generator'), ('bus-alert', 'bus')]),
         rtu(2, [('bus-243', 'bus'), ('load-1_bus-243', 'load'), ('generator-1_bus-243', 'generator')]),
         rtu(3, [('bus-244', 'bus'), ('branch-1_243-244', 'branch')]),
         rtu(4, [('bus-245', 'bus'), ('load-1_bus-245', 'load'), ('branch-1_242-245', 'branch'), ('branch-1_243-245', 'branch')])]
scen = {'apiVersion': 'phenix.sandia.gov/v2', 'kind': 'Scenario', 'metadata': {'name': 'soap-arm64', 'annotations': {'topology': 'soap-arm64'}},
        'spec': {'apps': [{'name': 'sceptre', 'assetDir': A, 'hosts': hosts}]}}
for n, d in (('topology', topo), ('scenario', scen)):
    yaml.safe_dump(d, open(f'soap-arm64-{n}.yaml', 'w'), sort_keys=False)
