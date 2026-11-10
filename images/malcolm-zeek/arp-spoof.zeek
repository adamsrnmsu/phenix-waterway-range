##! ARP spoof detector: raise ArpSpoof::Conflict when one IP is claimed by two different MACs
##! (or an IP's MAC changes) within ArpSpoof::window. Uses Zeek's built-in ARP analyzer
##! (Zeek::ARP, present in Malcolm's zeek 9.0.1). Shipped via zeek/custom (see images/malcolm-stage.sh).
@load base/frameworks/notice

module ArpSpoof;

export {
	redef enum Notice::Type += { Conflict };
	const window = 10min &redef;
}

type Claim: record { mac: string; ts: time; };
global claims: table[addr] of Claim &read_expire=window;

function check(ip: addr, mac: string)
	{
	if ( ip == 0.0.0.0 || mac == "00:00:00:00:00:00" || mac == "ff:ff:ff:ff:ff:ff" )
		return;
	if ( ip in claims && claims[ip]$mac != mac && network_time() - claims[ip]$ts <= window )
		NOTICE([$note=Conflict, $src=ip,
		        $msg=fmt("ARP spoofing: %s claimed by %s then %s", ip, claims[ip]$mac, mac),
		        $sub=fmt("%s -> %s", claims[ip]$mac, mac),
		        $identifier=cat(ip, claims[ip]$mac, mac), $suppress_for=window]);
	claims[ip] = [$mac=mac, $ts=network_time()];
	}

# SPA/SHA are the sender IP/MAC; requests carry them too (ettercap sends both)
event arp_reply(mac_src: string, mac_dst: string, SPA: addr, SHA: string, TPA: addr, THA: string)
	{ check(SPA, SHA); }
event arp_request(mac_src: string, mac_dst: string, SPA: addr, SHA: string, TPA: addr, THA: string)
	{ check(SPA, SHA); }
