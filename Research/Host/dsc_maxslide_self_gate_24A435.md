# `dsc_maxslide` self-gate misfires on `24A435`

Observed 2026-09-30 on a source build of `2.1.5`. Reported separately from the
trackpad work because it is a firmware-patch bug, not a feature.

## Symptom

A VM created from `17,3_27.0_24A435` + cloudOS `26.4-23E5207q` (`vm create`,
`Preset = standard`) boots to a black screen. The host side is healthy — the
window opens, `[hostctl] listening on …/vphone.sock` is printed, and the socket
answers — but vphoned never connects:

```console
$ echo '{"t":"rpc","method":"health","params":{}}' | nc -U ~/.vphone/machines/<vm>/vphone.sock
{"error":"guest not connected","ok":false}
```

The guest serial log ends in a pid-1 panic:

```text
panic(cpu 1 caller 0xfffffe0048417820):  initproc failed to start -- exit reason namespace 6
subcode 0x1 description: Library not loaded: /usr/lib/libSystem.B.dylib
Debugger message: panic
```

## Evidence

`dsc_maxslide.zero` **is** in the resolved plan — the install gate worked:

```console
$ plutil -p ~/.vphone/machines/<vm>/PatchPlan.plist | grep -n dsc_maxslide
23 => "dsc_maxslide.zero"
```

with `IOSBaseVersion => "27.0"`, `CloudOSVersion => "26.4"`,
`Preset => "standard"`, and 115 patches enabled overall.

So the patch was selected and the guest still panicked, which means the
patcher's own fits-check declined to write it.

## Inference

`DyldSharedCacheMaxSlidePatcher` decides on
`sharedRegionSize + maxSlide > 0x1_8000_0000` (6 GiB), and no-ops otherwise:

```swift
case .fits(combined:region:)     // span + maxSlide already fits, force not set
case .alreadyZero                // maxSlide already 0
case .overflow(combined:region:) // the patch applies
case .forced(combined:region:)   // fits, but --force was set
```

Its documented validation is on **`24A5380h`**, whose cache is quoted at span
`0x17c830000` + `0x20000000` = `0x19c830000` (> 6 GiB, so it patches). Nothing
in the research notes records the numbers for **`24A435`**, the RC this was hit
on — a different cache build, and evidently one whose `sharedRegionSize` +
`maxSlide` reads as fitting even though the map still fails at runtime.

The install gate is already hard-gated to `27.*`, so on this path the
self-gate's only effect is to skip a patch the base needs.

## Workaround (verified)

Force the patch, then boot:

```sh
vphone-cli vm stop <vm>
sudo vphone-cli cfw install <vm> --force-dsc-maxslide
vphone-cli vm launch <vm>
```

`--force` bypasses the fits-check and zeroes `maxSlide` unconditionally (still
idempotent). With it the guest boots normally, reaches the lock screen, and
vphoned connects — the trackpad work could be tested from there.

## Capturing the numbers a fix needs

The patcher is reachable on its own, against a chunk directory, without a VM:

```sh
vphone-cli cfw patch-dsc-maxslide <chunks-directory> [--dry-run] [--force]
```

`<chunks-directory>` is the guest's `/System/Library/Caches/com.apple.dyld`. On
a cache that has already been patched `maxSlide` reads `0x0` (`.alreadyZero`),
so the *first* `cfw install` on a fresh restore is the run whose
`[.] dyld_shared_cache_arm64e: start=… size=… maxSlide=…` line matters.

## Suggestion

Either

- let the `27.*` base skip the fits-check (`install gate already gates it`), or
- relax the gate so a non-zero `maxSlide` on a 27 base always patches, or
- re-derive the threshold with margin instead of relying on the header's own
  `sharedRegionSize`.

Whichever it is, `24A435` needs a recorded entry: today the notes only cover
`24A5380h` and `24A5390f`.
