# GNOME Shell Capture Crash and Display Scaling Recovery (2026-08-02)

## Executive conclusion

The apparent UU outage was downstream of a physical GNOME Shell crash. Three
incidents, on 2026-07-31, 2026-08-02, and 2026-08-03, contained the same X11
MIT-SHM `BadMatch`/`SIGTRAP` signature. Shell failed before GNOME Remote
Desktop and FreeRDP lost their pipe, and UU disconnected only after its
captured desktop disappeared.

The third incident was bracketed by a persisted identity configuration and an
identity check immediately after restart; no log shows a geometry change in
between, but there is no synchronous RandR snapshot at the fault. Continuous
GNOME Remote Desktop capture on Mutter X11 remains inside the supported
trigger boundary. Fractional geometry is an observed complicating factor, not
a proven necessary cause. The recovery keeps native geometry and automatically
restarts Shell without ending the physical login, but it contains rather than
prevents this failure class.

## Before and after

| Property | Before or reproduced failure state | Stable profile |
| --- | --- | --- |
| Physical primary | transformed `3424x1926` | native `2560x1440` |
| Combined XRandR root | up to `8544x2880` during 150% reproduction | `5120x1440` |
| Active transforms | `1.337494` primary and `2.0` secondary | identity |
| Mutter feature | `x11-randr-fractional-scaling` enabled | disabled |
| UU relay | `3424x1926` | `2560x1440` |
| Windows controller | `1920x1080` | `1920x1080` |
| UI sizing | approximately 150% display transform | text `1.0`, DING `standard`, Dock default |

The controller remains smaller than the host source. UU rejected the
controller's host-resize request with `screen not support resolution` and
`error_code:501`; the supported behavior is to transmit the full native source
and fit it on the controller.

## Evidence timeline

- **2026-07-31 22:59:** GNOME Shell recorded the first matching MIT-SHM
  `GetImage` `BadMatch`/`SIGTRAP` failure while the desktop was being captured.
- **2026-08-02 15:03:44:** the current Shell process received `BadMatch` on
  MIT-SHM request 130, minor opcode 4, followed by signal 5.
- **2026-08-02 15:03:57:** systemd recorded `code=dumped, status=5/TRAP` for
  GNOME Shell.
- GNOME Remote Desktop and FreeRDP then reported a broken pipe. UU lost the
  desktop after those failures; no UU-first or network-first event preceded
  the Shell fault.
- **2026-08-02 15:22-15:23:** the relay setting changed from `3424x1926` to
  native `2560x1440`, and the supervised bridge restarted with that geometry.
- **2026-08-02 15:34:** selecting 150% reproduced transformed geometry: an
  `8544x2880` root, `3424x1926` primary, and non-identity transforms.
- **2026-08-02 15:36:** cleanup restored the `5120x1440` native root, two
  `2560x1440` identity outputs, and monitor scale 1.
- **2026-08-03 13:34:** the dconf database was last written before inspection.
  The UI-only profile was later observed at text `1.0`, DING `standard`, and
  Dock `38`; available logs do not identify the writer.
- **2026-08-03 14:00:54:** Shell received the same MIT-SHM request 130, minor
  opcode 4 `BadMatch` and exited with `status=5/TRAP`. The persisted profile
  disabled fractional features, and the bridge revalidated both identity
  transforms at 14:01:00 after the recovery unit restarted Shell at 14:00:58.
  No event reports an intervening geometry change, but the journal is not a
  fault-time RandR snapshot.

The crashes repeated after a Mutter/Shell package update and after restoring
identity geometry. Updating packages and removing fractional transforms were
reasonable mitigations but were not, by themselves, complete fixes.

## Root-cause boundary

The following facts are confirmed by logs and live geometry:

- GNOME Shell failed before the local RDP pipe and UU connection failed.
- All three Shell failures used the MIT-SHM `BadMatch`/`SIGTRAP` signature.
- The physical X11 session used fractional RandR transforms during the first
  investigated profile. The third matching crash was bracketed by identity
  configuration, although no synchronous transform sample exists at the fault.
- Removing those transforms restored a native, internally consistent capture
  geometry and avoids the previously observed transformed capture path.

The exact Mutter source function and race are not proven. The strongest common
boundary is Shell plus continuous GNOME Remote Desktop capture through the X11
MIT-SHM path; the nearby `Not using GLX TFP` and stage-view allocation warnings
are investigative leads, not proof. It would overstate the evidence to call
fractional scaling the root cause or attribute the crash to UU's network, one
proprietary UU function, or a single known upstream Mutter bug.

## Applied recovery

1. Disable `x11-randr-fractional-scaling` in Mutter's experimental features.
2. Persist native `2560x1440` modes and identity transforms for both physical
   outputs.
3. Set the UU relay to the native primary `2560x1440`; do not use the old
   transformed `3424x1926` size.
4. Keep GNOME Display scale at 100%.
5. Configure the X11 Shell user unit for delayed automatic restart and remove
   its stock `gnome-session-failed.target` linkage. This contains a future
   Shell process exit instead of deliberately ending the complete login.
6. Keep UI-only settings at the native baseline: text scale `1.0`, DING
   `standard`, and the distribution Dock default.

The declarative bridge profile is:

```bash
./install.sh --skip-packages --skip-account-login \
  --resolution 2560x1440 \
  --x11-shared-desktop-guard on --desktop-text-scale 1.0 \
  --desktop-icon-size standard --dock-icon-size 48
```

On this host, the operator-selected physical modes and relay remain
`2560x1440`; the guard itself enforces only the no-fractional-feature and
identity-transform invariants plus Shell recovery ownership. UI settings are
applied independently, are not continuously enforced, and cannot change the
capture rectangle.

The implementation never rewrites `monitors.xml` or forces an output mode. It
preflights the live physical X11 display, refuses non-identity geometry, and
removes only Mutter's two fractional-scaling tokens while preserving unrelated
experimental features. The running bridge repeats the geometry check
approximately every 10 seconds and tears down that relay attempt after three
consecutive failures; its normal systemd restart backoff and rate limit then
apply.

## Why the UI became smaller

Before recovery, GNOME's fractional display scaling rendered text and icons at
approximately 150% before capture. The relay was aligned to the resulting
`3424x1926` transformed geometry, so the Windows controller saw large desktop
elements even though that geometry was fragile.

After recovery, GNOME renders a native `2560x1440` desktop at 100%, then UU fits
that complete frame into the controller's `1920x1080` canvas. Unadjusted UI is
therefore visibly smaller. A `1.5`/`large`/`57` UI-only profile was tried, but
the persistent dconf values later returned to `1.0`/`standard`/`38` through an
unidentified writer. The guard intentionally does not continuously overwrite
ordinary UI preferences, so the conservative profile now uses native UI
sizing as well as native capture geometry.

## Validation

Check the geometry from the logged-in physical X11 session:

```bash
gsettings get org.gnome.mutter experimental-features
xrandr --current --verbose | rg ' connected|Transform:'
sed -n 's/^UURB_RESOLUTION=//p' \
  ~/.config/uu-remote-bridge/environment
```

Expected invariants are:

- `x11-randr-fractional-scaling` is absent;
- both active outputs use identity transforms;
- the combined two-monitor root is `5120x1440`;
- the primary and relay are both `2560x1440`; and
- UU shows the complete desktop on the `1920x1080` controller without clipping.

Inspect a suspected recurrence in chronological order:

```bash
journalctl -b --no-pager | \
  rg 'gnome-shell|MIT-SHM|BadMatch|status=5/TRAP|Broken pipe'
```

The 2026-08-03 recurrence proves that identity geometry does not guarantee
indefinite uptime. Confirm the Shell-first failure order rather than assuming
that a visible UU disconnect started in UU or the network.

## Residual risks and operator guardrails

- Do not re-enable 125%, 150%, or 175% GNOME Display scaling on this shared X11
  desktop. It restores non-identity fractional transforms and invalidates the
  recovered geometry.
- Keep the native UI defaults for the least stateful profile. Explicit
  `--desktop-text-scale`, `--desktop-icon-size`, and `--dock-icon-size` values
  remain available, but the runtime guard does not enforce them.
- Shell automatic restart limits the outage and protects the login session. It
  does not make Shell immune to another crash.
- A future Mutter, GNOME Remote Desktop, UU, Wine, or GPU failure can still
  interrupt capture. Evidence must again establish which component failed
  first.
- Removing an inherited `OnFailure` dependency cannot be expressed safely as
  a systemd drop-in, so this profile installs a complete Ubuntu 24.04 Shell
  user-unit override. Re-run installation and review the vendor-unit diff
  after a GNOME Shell package upgrade; the override does not automatically
  inherit future vendor directives.
- NVIDIA GSP/Xid hard locks are a separate host/GPU failure class. Do not merge
  them with this MIT-SHM finding without matching evidence.
- Wayland may avoid this exact X11 transform path, but moving the shared desktop
  would change the direct X11 input and physical-session assumptions and needs
  separate validation.

## Rollback boundary

For normal operation, keep the guard, 100% Display scale, intended relay, and
identity transforms. Restoring the old fractional monitor scale or
`3424x1926` relay would restore risky geometry and is not a supported
operational rollback.

`--x11-shared-desktop-guard off` and uninstall are reversible ownership
operations: they conditionally restore each GSettings value and Shell unit only
when it still equals the bridge-managed value. That may restore the previously
saved fractional-scaling feature tokens, although it never restores an old
`monitors.xml`, monitor mode, transform, or relay size. Do not keep capture
running on the former transformed profile after disabling the guard.
