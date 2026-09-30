# A question about the privilege cost of the utun route

Before we commit to an implementation, we would like your read on one thing:
whether the `utun` approach is acceptable at all, given what it needs.

## Context

`nat` and `bridged` both break when the host is behind a VPN (#464). vmnet's
masquerade is pinned to a physical interface (`nat on en5 … -> (en5:0)`), so
once a VPN owns the default route the guest's egress is written out a physical
NIC while replies come back through the tunnel, and every guest connection is
black-holed.

There are two unprivileged-looking ways to fix it, and they differ in exactly
one respect: **who runs the TCP stack**.

| | egress | consequence |
| --- | --- | --- |
| **A — userspace stack** | a host socket we open ourselves | we must terminate the guest's TCP → ~2000 lines, **no privilege** |
| **E — utun + userland NAT** | the kernel, via a utun we create | the guest's TCP talks to the server's TCP end to end → ~1000 lines, but **we must create a utun** |

The saving in E is precisely the TCP state machine. The cost is the utun.

## What creating a utun actually requires

Measured on this machine, from a small C probe (`socket(PF_SYSTEM, SOCK_DGRAM,
SYSPROTO_CONTROL)` → `ioctl(CTLIOCGINFO)` → `connect(sockaddr_ctl)`):

```
ctl_id=5
connect: Operation not permitted     <-- EPERM
```

The kernel control is reachable and `CTLIOCGINFO` resolves; the call that would
create the interface is refused.

What is worth flagging is that **`com.apple.vm.networking` does not help here**,
even though `vphone-vm` carries it. That entitlement is a virtualization-specific
door Apple opened for vmnet's shared/host modes; a utun sits behind a different
kernel check. The two VPN clients on this machine illustrate the only two routes
that do exist:

```
root      Cloudflare WARP   …/Resources/CloudflareWARP          (root daemon)
granger   Tailscale         …/PlugIns/IPNExtension.appex/…      (NetworkExtension)
```

So E needs one of:

| route | what it costs this project |
| --- | --- |
| **root** | `vphone-cli` is documented as "the unentitled entry point … it never obtains root itself", and Launchpad's helper is deliberately narrow — "It is not a general privilege service … there is no generic command verb". Using root here means changing that model. |
| **NetworkExtension** | needs `com.apple.developer.networking.networkextension` (Apple approval), must ship as an app bundle with an embedded appex rather than a CLI, and requires the user to authorise a system extension. |

There is no third route.

## The question

**Would either of those be acceptable, and if so which? Or should the mode stay
unprivileged?**

Our own instinct is A, because it needs nothing new from `vphone-vm`, touches no
host state, and fits the project's existing posture. But E is half the code and
deletes the part most likely to be subtly wrong, so if you would rather have the
shorter implementation we would like to know before building either.

## Where things stand

Stage 1 of A is already written and validated: frame I/O over
`VZFileHandleNetworkDeviceAttachment` (a `SOCK_DGRAM` socketpair), plus ARP, DHCP
and ICMP for a single guest. 38 synthesised-frame checks pass without a VM, and a
real guest takes a lease on `192.168.127.0/24` and can ping the gateway. It
deliberately stops at the gateway — UDP/DNS is stage 2 and TCP stage 3.

That first stage is **shared** between A and E: it is the same ~790 lines that
would feed a utun. So whichever way this goes, nothing built so far is wasted.
