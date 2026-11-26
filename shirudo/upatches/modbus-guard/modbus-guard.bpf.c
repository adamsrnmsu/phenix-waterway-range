// SPDX-License-Identifier: GPL-2.0 OR BSD-2-Clause
/*
 * modbus-guard: an XDP shield for a Modbus/TCP field device. On every VM-class NIC (xdp/8: virtio-net), each IPv4
 * TCP segment to port 502 that carries data must hold one well-formed Modbus request:
 *   - at least the 7-byte MBAP header plus a function code (8 bytes), so a truncated MBAP is dropped, and at most
 *     260 bytes (MBAP 7 + the largest PDU, 253);
 *   - MBAP protocol id 0 and MBAP length == payload length - 6 (the length the #81 cases lie about);
 *   - a function code the device serves: 1, 2, 3, 4, 5, 6, 15 or 16 (unassigned codes like 0x00/0x2B/0x5A/0x7F,
 *     which this RTU answers with an empty PDU, are dropped).
 * Anything else is XDP_DROP; the sender sees no answer. IPv4 TCP fragments are dropped on every port (see below).
 * Everything else that is not TCP to 502 passes.
 * ponytail: one ADU per segment; a master that pipelines several requests in one segment, or splits one across
 * segments, is dropped too. Reassembly would need a socket-level program, which a upatch cannot be here.
 */
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#define ETH_P_IP_BE 0x0008	/* htons(0x0800) */
#define MODBUS_PORT 502

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 4);	/* 0 passed, 1 short, 2 bad header, 3 bad function code */
	__type(key, __u32);
	__type(value, __u64);
} verdicts SEC(".maps");

static __always_inline int count(__u32 k, int action)
{
	__u64 *v = bpf_map_lookup_elem(&verdicts, &k);

	if (v)
		__sync_fetch_and_add(v, 1);
	return action;
}

SEC("xdp/8")
int modbus_guard(struct xdp_md *ctx)
{
	void *data = (void *)(long)ctx->data, *end = (void *)(long)ctx->data_end;
	struct ethhdr *eth = data;
	struct iphdr *ip;
	struct tcphdr *tcp;
	unsigned char *p;
	__u32 iplen, thlen, len;

	if ((void *)(eth + 1) > end || eth->h_proto != ETH_P_IP_BE)
		return XDP_PASS;
	ip = (void *)(eth + 1);
	if ((void *)(ip + 1) > end || ip->protocol != IPPROTO_TCP)
		return XDP_PASS;
	/* A fragment after the first has no TCP header to read the port from, and a split request could hide a second
	 * ADU behind a clean first one: drop every IPv4 TCP fragment (TCP sets DF; none are expected on these links). */
	if (ip->frag_off & bpf_htons(0x3FFF))
		return count(2, XDP_DROP);
	iplen = ip->ihl * 4;
	if (iplen < sizeof(*ip) || (void *)ip + iplen + sizeof(*tcp) > end)
		return XDP_PASS;
	tcp = (void *)ip + iplen;
	if (tcp->dest != bpf_htons(MODBUS_PORT))
		return XDP_PASS;
	thlen = tcp->doff * 4;
	if (thlen < sizeof(*tcp))
		return XDP_PASS;
	len = bpf_ntohs(ip->tot_len);
	if (len < iplen + thlen)
		return XDP_PASS;
	len -= iplen + thlen;		/* TCP payload length per the IP header */
	if (len == 0)
		return XDP_PASS;	/* SYN, ACK, FIN */
	if (len < 8)
		return count(1, XDP_DROP);
	if (len > 260)			/* MBAP 7 + the largest PDU, 253 */
		return count(2, XDP_DROP);
	p = (void *)tcp + thlen;
	if ((void *)(p + 8) > end)
		return count(1, XDP_DROP);
	if (p[2] || p[3] || ((__u32)p[4] << 8 | p[5]) != len - 6)
		return count(2, XDP_DROP);
	switch (p[7]) {
	case 1: case 2: case 3: case 4: case 5: case 6: case 15: case 16:
		return count(0, XDP_PASS);
	}
	return count(3, XDP_DROP);
}

char _license[] SEC("license") = "Dual BSD/GPL";
