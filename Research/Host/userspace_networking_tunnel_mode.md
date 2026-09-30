# `tunnel` mode, stage 1: frames, ARP, DHCP, ICMP

First of three stages of the userspace network described in
`vpn_safe_networking_design.md`. This stage makes the guest believe it is on a
LAN with a gateway; it does **not** yet reach the internet.

## What exists now

A new network mode, `tunnel`, alongside `nat` / `bridged` / `none`:

```
vphone-cli vm config <name> --network tunnel
```

It attaches `VZFileHandleNetworkDeviceAttachment` — the one attachment that
performs no networking of its own, handing raw Ethernet frames to this process
over a `SOCK_DGRAM` socket pair (`socketpair(AF_UNIX, SOCK_DGRAM, 0, …)`; each
`send`/`recv` is exactly one frame, no length prefix).

| file | role |
| --- | --- |
| `VPhoneCoreKit/Network/VPhoneUserspaceNetwork.swift` | socket pair, read source, frame loop, lifetime |
| `VPhoneCoreKit/Network/VPhoneInternetProtocol.swift` | addresses, checksums, Ethernet/IPv4/UDP codecs |
| `VPhoneCoreKit/Network/VPhoneUserspaceNetworkResponder.swift` | ARP, DHCP, ICMP; learned guest MAC |

## Addressing

Identical to the v1.x tunnel work, and for the same reasons:

| | |
| --- | --- |
| Subnet | `192.168.127.0/24` — deliberately not vmnet's `192.168.64.0/24`, so `tunnel` and `nat` can coexist |
| Gateway / DNS / `server-id` | `192.168.127.1` |
| Lease | `192.168.127.3` |
| DHCP options | `1` netmask, `3` router, `6` DNS, `26` MTU 1280, `51` lease, `53` type, `54` server-id |
| Gateway MAC | `02:00:00:00:00:01` (locally administered) |

The guest's own MAC is **not** configurable: Virtualization.framework assigns it
and never reports it, so the responder learns it from the first frame the guest
sends. That is the only piece of state the protocol handling keeps.

## Threading

One serial queue (`com.vphone.userspace-network`). Frame reads arrive as
`DispatchSource` events on it, `stop()` hops onto it before tearing down, and
every field is touched only there — which is the whole invariant behind the
class's `@unchecked Sendable`.

`stop()` is one-way: cancelling the read source closes our descriptor once no
handler is running, so `start()` after `stop()` does nothing rather than
resurrecting a closed pair.

## Verified

Unlike the firmware work, this needs no VM and no privilege — the responder is a
pure function from frame to frame, so it can be driven directly. A throwaway
driver compiled the two Foundation-only files and synthesised frames, 38 checks,
all passing: DHCP `DISCOVER`→`OFFER` and `REQUEST`→`ACK` (message type, lease in
`yiaddr`, echoed `chaddr`, ports 67→68, broadcast MAC, and each addressing
option), ARP request/reply/ignore cases, ICMP echo with a checksum that verifies
to zero, and the robustness cases (short frames, missing DHCP magic cookie,
fragments, empty input).

Reproduce it without the driver:

```
swiftc -O -o /tmp/nettest \
  VPhoneKit/VPhoneCoreKit/Network/VPhoneInternetProtocol.swift \
  VPhoneKit/VPhoneCoreKit/Network/VPhoneUserspaceNetworkResponder.swift \
  <driver>.swift && /tmp/nettest
```

The same checks exist as Swift Testing cases in
`VPhoneCoreKitTests/Network/VPhoneUserspaceNetworkTests.swift`; run them with the
`VPhoneCoreKitTests` target.

Two bugs were found this way rather than in a VM: a duplicate `datagram`
binding in the DHCP path (a compile error), and a test that fed the payload into
the IPv4 header checksum (the checksum covers the header only).

## Stage 2: UDP and DNS

The guest's UDP now leaves through the host and comes back.

| file | role |
| --- | --- |
| `Network/VPhoneUDPForwarder.swift` | one connected `SOCK_DGRAM` socket per flow, plus the host resolver lookup |

The design turns on two things:

- **A connected UDP socket per flow.** `connect()` on a `SOCK_DGRAM` socket makes
  the kernel demultiplex for us: a datagram can only arrive from the address we
  sent to, so an unrelated sender cannot reach the guest. That is the whole
  security story for an unprivileged forwarder, and it is why the sockets are
  connected rather than bound.
- **The reply is addressed as if it came from where the guest sent it.** A DNS
  lookup is addressed to `192.168.127.1`, so the answer has to appear to come
  from there or the guest's stack discards it. `sendUDPReply` uses the flow's
  *destination* as the reply's source for exactly this reason.

DNS specifically: the guest is told its resolver is the gateway, so lookups
arrive addressed to us. `resolveDestination` sends those to the host's own
resolver, read through `SystemConfiguration` rather than a file — that is what
changes when a VPN connects, and the point of the mode is that the guest follows
the host. Everything else is forwarded to the address the guest named.

Flows are forgotten after 30 seconds without traffic, which is the only thing
bounding the session table since UDP has no teardown.

### Verified

19 checks, all passing, from a driver compiled over the same Foundation-only
files: the outcome classes (ARP/ICMP still plain replies, DHCP still finished
locally, UDP for elsewhere becoming a forward carrying both ends and the guest's
MAC, a `0.0.0.0` source refused), and a **real round trip** against a local UDP
echo server — payload returned intact, the same flow reusing its one socket, a
second destination opening a second session, and `stop()` clearing them.

That round trip earned its keep: it found a real bug. `sin_addr` was left in
host order while `sin_port` was converted, which asks for an entirely different
address and fails with `EADDRNOTAVAIL`. Nothing in a VM would have said so
clearly.

## Stage 3: TCP

The guest's TCP is **terminated**, not relayed. That is the difference from UDP:
a datagram can be forwarded as bytes, a stream cannot, because the guest's TCP
expects a peer that speaks TCP. So this side answers the handshake, keeps its own
sequence space, and carries the payload over an ordinary host socket whose other
end is the host kernel's TCP.

| file | role |
| --- | --- |
| `Network/VPhoneTCPForwarder.swift` | connection table, state machine, host socket per flow |
| `Network/VPhoneInternetProtocol.swift` | `VPhoneTCPSegment` codec (header + flags + checksum) |

The flow is: guest SYN → non-blocking `connect()` to the host → on writability,
SYN-ACK back → guest ACK → both directions pump. Data the guest sends before the
host has connected is buffered and flushed on the handshake's completion, so the
guest never sees an unexplained stall.

Three deliberate simplifications, each defensible because the guest-facing link
is a local socketpair that neither reorders nor drops:

- **No options are sent** — no SACK, no timestamps, no window scaling, so the
  advertised window is capped at 65535. A guest that offers them is ignored,
  which is the correct response from a peer that never did.
- **We do not retransmit.** If a segment to the guest is lost anyway the guest
  retransmits, and the duplicate is handled by the sequence check.
- **No congestion control.** The path is host memory.

The two sequence spaces are kept strictly apart, and that is the whole reason
this stage is bigger than the last one. It is also the reason the alternative was
rejected: doing this in the kernel is what would need a utun, and therefore
privilege.

### Verified

20 checks, all passing: the segment codec (round trip, pseudo-header checksum
verified by summing to zero, SYN/FIN each costing a sequence number, options
parsed past rather than misread as payload, truncation rejected), the responder
routing a SYN to `forwardTCP` with both ends and the guest's MAC, and — the one
that matters — a **real handshake against a local TCP echo server**: SYN out,
SYN-ACK back acknowledging it, guest ACK, payload, echo returned with the right
acknowledgment, one connection tracked, and `stop()` clearing it.

## Where this leaves the mode

`tunnel` now has the full path: address, gateway, name resolution, and a real
egress for both transports. It is the first time the mode could actually carry
traffic.

What has **not** happened yet is a run inside a real guest. Everything above is
frame-level and socket-level against the host, which is what makes it cheap to
run and what caught the two bugs so far (`sin_addr` byte order here, `sin_addr`
again in UDP, and a double-advanced sequence number on SYN-ACK). A guest
exercising Safari is a different kind of test and has not been done.
