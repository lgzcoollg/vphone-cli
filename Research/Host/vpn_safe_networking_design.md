# VPN-safe networking: a design that fits inside the Xcode build

Re-does the network half of #475 against the current tree. The display half of
that PR is already submitted separately (trackpad scroll/pinch and Esc).

## The problem

`VZNATNetworkDeviceAttachment` is not a self-contained NAT. It reuses macOS
Internet Sharing / vmnet, which installs pf rules pinned to the **physical**
interface (`nat on en5 …-> (en5:0)`) and puts the guest on `192.168.64.0/24`.
When a VPN owns the default route (`utun*`), the host's own egress leaves via
the tunnel while the guest's is still written out the physical NIC, and the two
directions stop matching: every guest connection is black-holed. `bridged` does
not help — `VZBridgedNetworkDeviceAttachment` only enumerates physical
interfaces, so a VPN interface cannot be bridged. See #464, and
`Research/Host/userspace_networking_gvproxy.md` for the v1.x investigation.

What is needed is simply: **guest egress that follows the host's routing table**,
VPN included.

## The constraint

From Lakr233 on #475:

> the bundle can only use **system libraries and its own built contents** at
> runtime, so a downloaded `gvproxy` binary can't ship in it. A design that fits
> inside the Xcode build would be needed there.

Read precisely, this excludes *a binary fetched at runtime* (gvproxy, aria2c,
Homebrew). It does **not** exclude source compiled into the bundle — the project
already ships vendored C that way (`VPhoneExecutable/VPhoneCommand/VPhoneRestore`
over libirecovery + idevicestore, both C targets). `Build/ValidateBundle.sh`
enforces this at build time: it walks `otool -L` over the bundle and fails on any
absolute path.

Also excluded by existing project rules:

| Approach | Why it is out |
| --- | --- |
| `pf` anchor + `utun` | needs root; `vphone-cli` never obtains root, and Launchpad's helper has no generic verb |
| `NetworkExtension` | needs an entitlement and user-granted system extension approval |
| Shipping a prebuilt helper | the constraint above |

Unprivileged, self-contained designs only.

One clarification, because it is easy to misread: *unprivileged* here means *no
additional privilege*, not *no entitlements*. `vphone-vm` already carries
`com.apple.vm.networking`, and every attachment in play sits inside that same
set:

| attachment | needs `com.apple.vm.networking` |
| --- | --- |
| `VZNATNetworkDeviceAttachment` | yes |
| `VZBridgedNetworkDeviceAttachment` | yes (it also gates interface enumeration) |
| `VZFileHandleNetworkDeviceAttachment` | no |

The v1.x work emphasised "no entitlement needed" because `gvproxy` was a
separate process and could not inherit `vphone-vm`'s entitlements. A stack built
into the bundle runs inside `vphone-vm` and is in that same set either way. So
the new mode's advantage is **not** privilege — it is the egress path.

## Candidate designs

### A. A userspace stack in Swift

The guest NIC becomes `VZFileHandleNetworkDeviceAttachment` (raw L2 frames over a
socketpair, no entitlement needed). A Swift stack in the bundle terminates ARP,
DHCP, IPv4, ICMP, UDP and TCP, carrying those payloads over ordinary host
sockets — so egress follows the host routing table for free, exactly like the
v1.x gvproxy design did, without the helper binary.

- **Cost**: the largest single piece. Roughly: frame I/O + ARP + DHCP + ICMP
  ≈ 500 lines; UDP + DNS ≈ 300; **TCP ≈ 800–1200** (sequence bookkeeping,
  receive windows, retransmit on a lossless local link).
- **Risk**: TCP correctness. Mitigated by the link being reliable and
  low-latency (a unix socketpair), which is what lets a simplified state machine
  be honest rather than fragile.
- **Fit**: zero third-party code; every line is "its own built contents".

### B. A vendored C stack

Take an existing C stack (lwIP is BSD-licensed, ~50k lines) as a target, then
write a thin forwarding layer that terminates connections and dials out over
host sockets — the shape slirp uses.

- **Cost**: less Swift, but lwIP needs a port layer (`sys_arch`, `lwipopts.h`)
  and has **no ready-made NAT/forward application**, so the forwarding layer is
  still ours (≈400–600 lines).
- **Risk**: a 50k-line dependency the bundle gate cannot inspect beyond its
  binary linkage, against a project that is otherwise careful about
  dependencies. Precedent exists (VPhoneRestore) but it is deliberately narrow.

### C. Guest-side forwarding over vsock

Run a userland forwarder inside the guest (tun2socks-shaped), reachable over
vsock — which does not depend on the NIC at all — and have it hand TCP to a
SOCKS5 server in `vphone-vm` built on Network.framework.

- **Cost**: the host side is the smallest of the three (~400 lines). The guest
  side is the expensive half: cross-compiling a guest component, taking over the
  guest's routing, and keeping that in step with guest updates.
- **Risk**: it changes the guest's whole network behaviour rather than adding a
  mode, and guest components ship as payload (a different review surface).
  Only chosen if the host-side stack proves impractical.

## Recommendation

**A**, built in three stages so each is independently testable:

1. **Frames, ARP, DHCP, ICMP.** The guest gets an address, resolves the
   gateway, and can ping it. Provable without any egress.
2. **UDP and DNS.** Name resolution works through the host resolver.
3. **TCP.** Full egress; this is where the design earns its keep.

Each stage is a separate commit behind the same `VPHONE_NET_*`-style switch as
today's features, so `nat`/`bridged`/`off` stay untouched.

Worth stating plainly: this is a **mode**, not a fix for `nat`. `nat` stays
broken behind a VPN by design of vmnet; the new mode is what a user picks when
they are behind one.

## What the implementation would touch

| File | Role |
| --- | --- |
| `VPhoneKit/VPhoneCoreKit/Support/VPhoneNetworking.swift` | a new mode in `NetworkMode`, device construction |
| new `VPhoneKit/.../Support/VPhoneUserspaceNetwork*.swift` | the stack (frame I/O, ARP/DHCP/ICMP, UDP/DNS, TCP) |
| `VPhoneExecutable/.../VirtualMachine/VPhoneVirtualMachine.swift` | owns the backend's lifetime across a boot |

## Costing A against the privileged designs

With privilege on the table the useful comparison is not "Swift vs C" but **where
the TCP state machine lives**. That is the single largest block of work in A, and
it has a variant that removes it entirely.

### A — a userspace stack (~1900–2400 lines)

| part | lines |
| --- | --- |
| frame I/O over the attachment's socketpair | 150 |
| Ethernet + IPv4 parse/build/checksum | 300 |
| ARP (answer the guest's gateway lookup) | 80 |
| DHCP (discover/offer/request/ack + options) | 200 |
| ICMP echo | 60 |
| UDP termination + forwarding | 200 |
| **TCP termination** (state machine, sequence bookkeeping, windows, MSS, retransmit) | **800–1200** |

Privilege: none. Host state: none. Risk: TCP correctness against iOS's real
stack, and anything that stack does that a simplified peer mishandles.

### E — `utun` plus userland NAT (~900–1100 lines)

The insight is that **an address-and-port translation needs no TCP state at
all**. If the only thing we rewrite is the IPv4 header's source address and the
source port of the transport header — *not* the sequence numbers — then the
guest's TCP talks to the server's TCP end to end, and both ends keep their own
bookkeeping. We never look at a sequence number.

```
guest SYN(src 192.168.127.3:51000 -> 1.1.1.1:443)
  → rewrite to (utun-addr:port) → write to utun → kernel routes it → VPN
  ← reply to (utun-addr:port) → kernel delivers to us → rewrite back → guest
```

Because the rewritten packet is sourced from an address the host owns, the
kernel treats it as its own egress: normal routing, VPN included, no
`ipforwarding`, no pf.

| part | lines |
| --- | --- |
| frame I/O, Ethernet + IPv4, ARP, DHCP, ICMP | (same as A) ≈ 790 |
| **connection table + header rewrite + checksums** (replaces A's TCP block) | **300–400** |
| utun create/configure/teardown | 150 |

Privilege: **root** (creating a utun). Host state: **one utun interface** while
running, which must be torn down on exit, on SIGINT, and swept after a crash.

An alternative variant lets `pf` do the translation instead of us — that trades
~350 lines of rewrite code for ~350 lines of `/dev/pf` rule programming plus a
system dependency, and buys nothing. Rewriting ourselves is smaller and keeps
the failure surface inside our process.

### The comparison, without the round numbers

| | A | E |
| --- | --- | --- |
| lines | 1900–2400 | 900–1100 |
| who runs the TCP stack | **us** | **the guest and the server** |
| privilege | none | root (utun only) |
| host state to clean up | none | one utun |
| main risk | TCP edge cases on a real iOS stack | connection tracking + privilege/teardown |
| fits "system libraries and its own built contents" | yes | yes (still no external binary) |

E is roughly **half** the code, and it deletes the part most likely to be subtly
wrong. Against that: it needs root, and vphone-cli's stated contract is that it
never obtains root itself — so E has to come with an answer for privilege (a new
helper path, or an explicit one-time `sudo`), and with a teardown story for the
interface it leaves behind.

## What each candidate does to the host network

This turned out to matter more than the line count. The failure being fixed is
not only "the guest has no network when a VPN is up" — hosts have also been
observed to lose their VPN once a VM is running, and that points at *how much of
the host's own networking a candidate takes over*.

| | takes over | host impact |
| --- | --- | --- |
| `nat` / `bridged` | vmnet + Internet Sharing: its own pf NAT anchor, `bridge100`, `bootpd` | global. Enabling it installs system-level network configuration, which is the likely cause of the host losing its VPN when a VM starts. Note also that vmnet does not self-heal when the VPN drops; its daemon has to be restarted. |
| **A** (userspace stack) | nothing | none. No interface, no route, no pf rule, no daemon. |
| **E** (utun + NAT) | one utun interface and one `192.168.x.0/24` route | local. The default route is untouched, so a VPN keeps working; the added interface disappears with the process. |

### A discarded variant: keep `nat`, fix the pf rule (J)

The root cause is narrower than "the two directions no longer match". Reading the
v1.x notes again, the actual step is outbound route selection: the guest's packet
enters from `bridge100`, the routing table sees a public destination, and the
default route sends it out `utun5`. Internet Sharing's rule is
`nat on en5 from 192.168.64.0/24 to any`, so it does not match a packet leaving
`utun5`, no translation happens, and a packet sourced from `192.168.64.x` enters
the tunnel and is dropped.

So one could keep the attachment and only re-point the masquerade:

```
nat on utun5 from 192.168.64.0/24 to any -> (utun5:0)
```

~200–400 lines, no userspace stack, no utun. It is rejected here anyway, for two
reasons: it keeps vmnet and Internet Sharing in the picture, so the host-side
impact above stays; and acting on pf needs root, the same objection as E — with
none of E's reduction in code.

## The privilege E would actually need

It is tempting to assume E can copy how `nat` gets its privilege — `vphone-vm`
carries `com.apple.vm.networking`, so vmnet's shared mode works with no root.
That does **not** transfer. `com.apple.vm.networking` is a virtualization-specific
door Apple opened for vmnet's shared/host modes; a utun is a different kernel
object behind a different check.

Measured, from a small C probe (`socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)`
→ `ioctl(CTLIOCGINFO)` → `connect(sockaddr_ctl)`):

```
ctl_id=5
connect: Operation not permitted     <-- EPERM
```

The kernel control is reachable, but `connect` — the call that would create the
interface — is refused. Which matches how the only two VPN clients on this
machine do it:

```
root      Cloudflare WARP   …/Resources/CloudflareWARP          (root daemon)
granger   Tailscale         …/PlugIns/IPNExtension.appex/…      (NetworkExtension)
```

Those are the only two routes on macOS: **root**, or **NetworkExtension** (a
system extension the user installs and authorises). There is no third.

For E that means the utun must be created by either a root helper — which
`vphone-cli`'s contract explicitly rules out, and which Launchpad's helper
deliberately has no verb for — or a NetworkExtension, which is a different
deliverable entirely, not a `vphone-cli` mode.

This is the asymmetry that decides between A and E: **A is the only candidate
that needs no privilege at all**, because it never asks the kernel for an
interface. It just reads and writes frames over a socketpair it owns.

## Validation

Same shape as the v1.x work, but without the helper: drive the transport the
guest will use (`bind` + `connect` a `SOCK_DGRAM` unix socket to the attachment's
socket), synthesise L2 frames, and compare against the host:

| Probe | Expected |
| --- | --- |
| `DHCP DISCOVER` → `OFFER` | a lease in the mode's subnet |
| ARP for the gateway | reply with the gateway's MAC |
| TCP `SYN` to `1.1.1.1:443` | `SYN-ACK` **with the VPN up** |
| UDP DNS for a public name | an answer, `rcode 0` |
| Egress check | same exit address as the host's own (`ip.sb`-style), i.e. the VPN's |

The last row is the whole point of the exercise, and it is the one thing `nat`
cannot pass.
