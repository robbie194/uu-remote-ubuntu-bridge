#!/usr/bin/env bash

set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bridge_user="${USER:-$(id -un)}"
wine_prefix="${WINEPREFIX:-$HOME/.local/share/wineprefixes/uu-remote}"
environment_file="$HOME/.config/uu-remote-bridge/environment"
saved_setting() {
    local name="$1"

    [[ -f "$environment_file" ]] || return 0
    /usr/bin/sed -n "s/^${name}=//p" "$environment_file" | \
        /usr/bin/tail -n 1
}
release_manifest="${UURB_RELEASE_MANIFEST:-$wine_prefix/compat/release-manifest.json}"
if [[ ! -f "$release_manifest" ]]; then
    release_manifest="$repo_dir/patches/uu-remote-4.33.0.8907.json"
fi
manifest_field() {
    /usr/bin/python3 "$repo_dir/scripts/patch-gameviewer.py" field "$1" \
        --manifest "$release_manifest"
}
release_version="$(manifest_field version)"
server="$wine_prefix/drive_c/Program Files/Netease/GameViewer/bin/$(manifest_field server.filename)"
healthd="$wine_prefix/drive_c/Program Files/Netease/GameViewer/bin/$(manifest_field health_monitor.filename)"
healthd_original_sha256="$(manifest_field health_monitor.original_sha256)"
healthd_stub="$repo_dir/build/compat/uu-healthd-stub.exe"
devcon="$wine_prefix/drive_c/Program Files/Netease/GameViewer/bin/drivers/devcon.exe"
devcon_backup="$devcon.uu-original"
case "$release_version" in
    4.33.0.8907|4.34.0.8979)
        devcon_original_sha256='46731d6ea59dd9b63ad641c79646bb5ff64e1b877a1226536e3fe34d1ab4ee10'
        ;;
    *)
        devcon_original_sha256=''
        ;;
esac
freerdp="$wine_prefix/drive_c/Program Files/FreeRDP/sdl-freerdp.exe"
cursor_guard="$wine_prefix/compat/uu-cursor-guard.dll"
cursor_guard_log="$wine_prefix/drive_c/users/$bridge_user/Temp/uu-cursor-guard.log"
cursor_reader_guard_log="$wine_prefix/drive_c/users/$bridge_user/AppData/Local/Temp/uu-cursor-guard.log"
libei_backport="$wine_prefix/compat/libei/libei.so.1.2.1"
network_filter="$wine_prefix/compat/uu-network-filter.so"
x11_input_helper="$wine_prefix/compat/uu-x11-input"
x11_input_ready_file="${XDG_RUNTIME_DIR:-/run/user/$UID}/uu-remote-bridge/x11-input.port"
runtime_digest_file="$wine_prefix/compat/.runtime-source-sha256"
# GameViewerServer is launched by Wine's service manager, which intentionally
# does not inherit UU_INPUT_BRIDGE_LOG. The injected DLL therefore uses the
# target process's normal GetTempPathW() location.
bridge_log="$wine_prefix/drive_c/users/$bridge_user/AppData/Local/Temp/uu-input-bridge.log"
broker_log="$wine_prefix/drive_c/users/$bridge_user/Temp/uu-input-broker.log"
server_log_dir="$wine_prefix/drive_c/Program Files/Netease/GameViewer/log/server/log"
stability_seconds=270
allow_runtime_drift=false
errors=0
systemctl_user=(
    /usr/bin/env
    "DBUS_SESSION_BUS_ADDRESS=unix:path=${XDG_RUNTIME_DIR:-/run/user/$UID}/bus"
    /usr/bin/systemctl --user
)
system_profile_unit="${UURB_SYSTEM_PROFILE_UNIT:-io.github.lachlanchen.AstrillLazyRouter.ApplicationProfile@uuremote.service}"
bridge_service_kind=""
saved_rdp_port="$(saved_setting UURB_RDP_PORT)"
rdp_port="${UURB_RDP_PORT:-${saved_rdp_port:-3390}}"
saved_keyboard_route="$(saved_setting UURB_KEYBOARD_ROUTE)"
keyboard_route="${UURB_KEYBOARD_ROUTE:-${saved_keyboard_route:-rdp}}"
saved_cursor_guard="$(saved_setting UURB_CURSOR_GUARD)"
cursor_guard_setting="${UURB_CURSOR_GUARD:-${saved_cursor_guard:-off}}"
saved_x11_shared_desktop_guard="$(
    saved_setting UURB_X11_SHARED_DESKTOP_GUARD
)"
x11_shared_desktop_guard="${UURB_X11_SHARED_DESKTOP_GUARD:-${saved_x11_shared_desktop_guard:-off}}"

bridge_service_active() {
    if "${systemctl_user[@]}" is-active --quiet uu-remote-bridge.service; then
        bridge_service_kind=user
        return 0
    fi
    if /usr/bin/systemctl is-active --quiet "$system_profile_unit" \
        2>/dev/null; then
        bridge_service_kind=system-profile
        return 0
    fi
    bridge_service_kind=""
    return 1
}

bridge_service_property() {
    local property="$1"

    bridge_service_active || return 1
    if [[ "$bridge_service_kind" == user ]]; then
        "${systemctl_user[@]}" show uu-remote-bridge.service \
            -p "$property" --value 2>/dev/null
    else
        /usr/bin/systemctl show "$system_profile_unit" \
            -p "$property" --value 2>/dev/null
    fi
}

grd_pid_for_port() {
    pgrep -o -u "$UID" -f \
        "^/usr/libexec/gnome-remote-desktop-daemon --rdp-port $rdp_port( |$)" \
        2>/dev/null || true
}

process_namespace_listener_ready() {
    local pid="$1"
    local port_hex
    local table

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    printf -v port_hex '%04X' "$rdp_port"
    for table in "/proc/$pid/net/tcp" "/proc/$pid/net/tcp6"; do
        [[ -r "$table" ]] || continue
        if /usr/bin/awk -v port="$port_hex" '
            $4 == "0A" {
                split($2, local_address, ":")
                if (toupper(local_address[2]) == port)
                    found = 1
            }
            END { exit !found }
        ' "$table"; then
            return 0
        fi
    done
    return 1
}

relay_listener_ready() {
    local pid

    if /usr/bin/ss -H -ltnp "sport = :$rdp_port" 2>/dev/null | \
        /usr/bin/grep -q 'gnome-remote-de'; then
        return 0
    fi
    pid="$(grd_pid_for_port)"
    process_namespace_listener_ready "$pid"
}

x11_route_ready() {
    [[ "$keyboard_route" != x11 ]] || {
        [[ -x "$x11_input_helper" ]] &&
        pgrep -u "$UID" -f "$x11_input_helper" >/dev/null &&
        [[ -s "$x11_input_ready_file" ]]
    }
}

server_startup_ready() {
    local modified

    [[ "$service_start_epoch" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$latest_server_log" && -f "$latest_server_log" ]] || return 1
    modified="$(stat -c %Y "$latest_server_log" 2>/dev/null || true)"
    [[ "$modified" =~ ^[0-9]+$ ]] || return 1
    ((modified >= service_start_epoch)) || return 1
    grep -q 'update_gvinput.*end' "$latest_server_log" &&
        grep -q 'room_state_changed: created' "$latest_server_log"
}

while (($#)); do
    case "$1" in
        --quick)
            stability_seconds=0
            shift
            ;;
        --stability-seconds)
            stability_seconds="${2:?--stability-seconds requires a number}"
            shift 2
            ;;
        --allow-runtime-drift)
            allow_runtime_drift=true
            shift
            ;;
        *)
            printf 'unknown verifier option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done
if [[ ! "$stability_seconds" =~ ^[0-9]+$ ]]; then
    printf 'usage: scripts/verify.sh [--quick|--stability-seconds N] [--allow-runtime-drift]\n' >&2
    exit 2
fi

pass() {
    printf 'PASS  %s\n' "$1"
}

fail() {
    printf 'FAIL  %s\n' "$1" >&2
    errors=$((errors + 1))
}

for _ in {1..180}; do
    if bridge_service_active && \
       pgrep -u "$UID" -f 'GameViewerServer\.exe' >/dev/null && \
       pgrep -u "$UID" -f 'sdl-freerdp\.exe' >/dev/null && \
       relay_listener_ready && \
       x11_route_ready; then
        break
    fi
    sleep 0.25
done

if bridge_service_active; then
    if [[ "$bridge_service_kind" == user ]]; then
        pass 'systemd user service is active'
    else
        pass "system application-profile service is active ($system_profile_unit)"
    fi
else
    fail 'no supported bridge service is active'
fi

if [[ "$x11_shared_desktop_guard" == on ]]; then
    shared_desktop_helper="$HOME/.local/libexec/uu-configure-shared-desktop"
    managed_shell_unit="$HOME/.local/share/uu-remote-bridge/systemd/org.gnome.Shell@x11.service"
    installed_shell_unit="$HOME/.config/systemd/user/org.gnome.Shell@x11.service"
    if [[ -x "$shared_desktop_helper" &&
          -f "$managed_shell_unit" &&
          -f "$installed_shell_unit" ]] &&
       /usr/bin/cmp -s "$managed_shell_unit" "$installed_shell_unit"; then
        pass 'X11 Shell recovery unit is installed from the managed source'
    else
        fail 'X11 shared-desktop guard files are missing or differ from the managed source'
    fi
    shell_on_failure="$(
        "${systemctl_user[@]}" show org.gnome.Shell@x11.service \
            --property=OnFailure --value 2>/dev/null || true
    )"
    if [[ "$shell_on_failure" == *org.gnome.Shell-disable-extensions.service* &&
          "$shell_on_failure" != *gnome-session-failed.target* ]]; then
        pass 'GNOME Shell failure recovery no longer logs out the X11 session'
    else
        fail 'GNOME Shell still includes the session-failed logout dependency'
    fi
    if shared_desktop_output="$(
        /usr/bin/timeout --kill-after=2s 5s \
            "$shared_desktop_helper" check \
            --bus "unix:path=${XDG_RUNTIME_DIR:-/run/user/$UID}/bus" \
            --display auto --xauthority auto \
            --config-dir "$HOME/.config/uu-remote-bridge" 2>&1
    )"; then
        pass 'physical seat0 X11 desktop uses the managed identity profile'
    else
        printf '%s\n' "$shared_desktop_output" >&2
        fail 'physical seat0 X11 desktop failed the shared-desktop guard'
    fi
else
    printf 'INFO  X11 shared-desktop capture guard is disabled\n'
fi

service_started_at="$(bridge_service_property ExecMainStartTimestamp || true)"
service_start_epoch="$(date -d "$service_started_at" +%s 2>/dev/null || true)"
latest_server_log=''
for _ in {1..240}; do
    latest_server_log="$(
        find "$server_log_dir" -maxdepth 1 -type f -name 'log_*.txt' \
            -printf '%T@ %p\n' 2>/dev/null | \
            sort -nr | head -n 1 | cut -d' ' -f2-
    )"
    if server_startup_ready; then
        break
    fi
    sleep 0.25
done
if server_startup_ready; then
    pass 'current cold start completed device initialization and signaling'
else
    fail 'current service start did not complete device initialization and signaling'
fi

pass "approved UU release manifest $release_version is active"

expected_runtime_digest="$("$repo_dir/scripts/runtime-source-digest")"
installed_runtime_digest="$(cat "$runtime_digest_file" 2>/dev/null || true)"
if [[ "$installed_runtime_digest" == "$expected_runtime_digest" ]]; then
    pass 'installed runtime matches this source checkout'
elif [[ "$allow_runtime_drift" == true ]]; then
    printf 'INFO  installed runtime differs from pulled source and will be refreshed\n'
else
    fail 'installed runtime is older or differs from this source checkout; reinstall it'
fi

if /usr/bin/python3 "$repo_dir/scripts/patch-gameviewer.py" verify "$server" \
    --manifest "$release_manifest" --expect patched >/dev/null; then
    pass 'GameViewerServer.exe is the audited patched build'
else
    fail 'GameViewerServer.exe verification failed'
fi

if [[ -f "$healthd.uu-original" ]] && \
   [[ "$(sha256sum "$healthd.uu-original" | awk '{print $1}')" == \
      "$healthd_original_sha256" ]] && \
   [[ -f "$healthd_stub" ]] && \
   /usr/bin/python3 "$repo_dir/scripts/compare-pe-normalized.py" \
       "$healthd" "$healthd_stub" >/dev/null; then
    pass 'health monitor stub is installed with an audited backup'
else
    fail 'health monitor stub or backup verification failed'
fi

if [[ -n "$devcon_original_sha256" ]] &&
   [[ ! -e "$devcon" ]] &&
   [[ -f "$devcon_backup" ]] &&
   [[ "$(sha256sum "$devcon_backup" | awk '{print $1}')" == \
      "$devcon_original_sha256" ]]; then
    pass 'unsupported Windows driver installer is suppressed with an audited backup'
else
    fail 'devcon suppression or audited backup verification failed'
fi

if "$repo_dir/scripts/inspect-wine-device-registry.py" verify \
    "$wine_prefix" >/dev/null; then
    pass 'Wine device registry cannot accumulate unsupported input or Bluetooth devices'
else
    fail 'Wine device registry hygiene is missing or stale devices remain'
fi

if [[ -f "$freerdp" ]] && \
   [[ "$(sha256sum "$freerdp" | awk '{print $1}')" == \
      1534187d731b2e4a6cb6d1107c0129727517fe3acf1441b5a2567aea5ea31d60 ]]; then
    pass 'pinned Windows FreeRDP SDL client is installed'
else
    fail 'Windows FreeRDP SDL client verification failed'
fi

relay_pid="$(pgrep -n -u "$UID" -x 'sdl-freerdp.exe' || true)"
cursor_server_pid="$(
    pgrep -o -u "$UID" -f 'GameViewerServer\.exe' || true
)"
if [[ "$cursor_guard_setting" == on ]]; then
    if [[ -f "$cursor_guard" && -n "$relay_pid" &&
          -n "$cursor_server_pid" ]] &&
       grep -Fq "$cursor_guard" "/proc/$relay_pid/maps" 2>/dev/null &&
       grep -Fq "$cursor_guard" "/proc/$cursor_server_pid/maps" 2>/dev/null &&
       grep -q 'UU relay cursor guard active' \
           "$cursor_guard_log" 2>/dev/null &&
       grep -q 'UU cursor reader guard active' \
           "$cursor_reader_guard_log" 2>/dev/null; then
        pass 'opt-in relay and UU cursor guards are active'
    else
        fail 'opt-in relay or UU cursor guard is missing or inactive'
    fi
elif [[ "$cursor_guard_setting" == off ]]; then
    if { [[ -z "$relay_pid" ]] ||
         ! grep -Fq "$cursor_guard" "/proc/$relay_pid/maps" 2>/dev/null; } &&
       { [[ -z "$cursor_server_pid" ]] ||
         ! grep -Fq "$cursor_guard" \
             "/proc/$cursor_server_pid/maps" 2>/dev/null; }; then
        pass 'optional cursor guard is disabled and not loaded'
    else
        fail 'cursor guard state does not match the disabled setting'
    fi
else
    fail 'cursor guard setting is neither off nor on'
fi

if [[ -f "$bridge_log" ]] && \
   grep -q 'UU SendInput bridge active' "$bridge_log" && \
   grep -q 'UU Wine event-log compatibility active' "$bridge_log"; then
    pass 'input and Wine event-log hooks are active'
else
    fail 'input or Wine event-log hook did not initialize'
fi

if [[ -f "$broker_log" ]] && \
   grep -q 'UU input broker active' "$broker_log"; then
    pass 'local input broker is active'
else
    fail 'local input broker did not initialize'
fi

saved_text_key_delay_ms="$(saved_setting UURB_TEXT_KEY_DELAY_MS)"
text_key_delay_ms="${UURB_TEXT_KEY_DELAY_MS:-${saved_text_key_delay_ms:-8}}"
broker_configuration="$(
    grep 'UU input broker active text-delay-ms=' "$broker_log" 2>/dev/null | \
        tail -n 1 || true
)"
if [[ "$text_key_delay_ms" =~ ^[0-9]+$ ]] &&
   ((text_key_delay_ms <= 50)) &&
   [[ "$broker_configuration" == *"text-delay-ms=$text_key_delay_ms "* ]]; then
    pass "input broker uses a ${text_key_delay_ms} ms text-key delay"
else
    fail 'input broker text-key pacing is missing or differs from saved settings'
fi

saved_physical_key_delay_ms="$(saved_setting UURB_PHYSICAL_KEY_DELAY_MS)"
physical_key_delay_ms="${UURB_PHYSICAL_KEY_DELAY_MS:-${saved_physical_key_delay_ms:-0}}"
if [[ "$physical_key_delay_ms" =~ ^[0-9]+$ ]] &&
   ((physical_key_delay_ms <= 50)) &&
   [[ "$broker_configuration" == *"physical-delay-ms=$physical_key_delay_ms "* ]]; then
    pass "input broker uses a ${physical_key_delay_ms} ms physical-key delay"
else
    fail 'input broker physical-key pacing is missing or differs from saved settings'
fi

active_keyboard_route="$(
    /usr/bin/sed -n 's/.* keyboard-route=\([^[:space:]]*\).*/\1/p' \
        <<<"$broker_configuration"
)"
if [[ "$keyboard_route" != rdp && "$keyboard_route" != x11 &&
      "$keyboard_route" != auto ]]; then
    fail "saved keyboard route is invalid: $keyboard_route"
elif [[ "$active_keyboard_route" != rdp &&
        "$active_keyboard_route" != x11 ]]; then
    fail 'input broker did not report an active keyboard route'
elif [[ "$keyboard_route" == rdp && "$active_keyboard_route" != rdp ]]; then
    fail 'input broker unexpectedly bypasses the requested RDP keyboard route'
elif [[ "$keyboard_route" == x11 && "$active_keyboard_route" != x11 ]]; then
    fail 'the requested direct X11 keyboard route is not active'
elif [[ "$active_keyboard_route" == x11 ]]; then
    if [[ -x "$x11_input_helper" ]] &&
       pgrep -u "$UID" -f "$x11_input_helper" >/dev/null &&
       [[ -s "$x11_input_ready_file" ]]; then
        pass 'direct X11 physical-key helper is active'
    else
        fail 'input broker reports X11 routing but its native helper is unavailable'
    fi
else
    pass 'compatible RDP physical-key route is active'
fi

configured_rdp_port="$(
    /usr/bin/gsettings get org.gnome.desktop.remote-desktop.rdp port | \
        /usr/bin/awk '{print $2}'
)"
if [[ "$configured_rdp_port" != "$rdp_port" ]]; then
    fail "GNOME RDP is configured for port $configured_rdp_port, expected $rdp_port"
elif relay_listener_ready; then
    pass "GNOME RDP relay owns localhost:$rdp_port"
else
    fail "GNOME RDP relay is unavailable on localhost:$rdp_port"
fi

grd_pid="$(grd_pid_for_port)"
saved_grd_fd_restart_threshold="$(
    saved_setting UURB_GRD_FD_RESTART_THRESHOLD
)"
grd_fd_restart_threshold="${UURB_GRD_FD_RESTART_THRESHOLD:-${saved_grd_fd_restart_threshold:-4096}}"
if [[ -n "$grd_pid" ]]; then
    grd_fd_count="$(
        /usr/bin/find "/proc/$grd_pid/fd" -maxdepth 1 -type l \
            -printf '.\n' 2>/dev/null | /usr/bin/wc -l
    )"
    grd_soft_limit="$(
        /usr/bin/awk '$1 == "Max" && $2 == "open" && $3 == "files" {print $4}' \
            "/proc/$grd_pid/limits"
    )"
    if [[ -f "$libei_backport" ]] &&
       /usr/bin/grep -Fq "$libei_backport" "/proc/$grd_pid/maps"; then
        pass 'GNOME RDP uses the isolated patched libei keymap-FD backport'
    else
        fail 'GNOME RDP is not using the patched libei keymap-FD backport'
    fi
    if [[ "$grd_soft_limit" =~ ^[0-9]+$ ]] &&
       ((grd_soft_limit >= 65536)); then
        pass "GNOME RDP descriptor limit is $grd_soft_limit"
    else
        fail "GNOME RDP descriptor limit is only ${grd_soft_limit:-unknown}"
    fi
    if ((grd_fd_restart_threshold == 0)); then
        printf 'INFO  GNOME RDP descriptor restart guard is disabled\n'
    elif ((grd_fd_count < grd_fd_restart_threshold)); then
        pass "GNOME RDP uses $grd_fd_count/$grd_fd_restart_threshold guarded descriptors"
    else
        fail "GNOME RDP uses $grd_fd_count descriptors, at or above the $grd_fd_restart_threshold restart threshold"
    fi
fi

server_pid="$(pgrep -o -u "$UID" -f 'GameViewerServer\.exe' || true)"
if [[ -n "$server_pid" ]]; then
    pass "UU server is running as process $server_pid"
else
    fail 'UU server is not running'
fi

saved_network_interface="$(saved_setting UURB_NETWORK_INTERFACE)"
network_interface="${UURB_NETWORK_INTERFACE:-${saved_network_interface:-all}}"
active_network_interface=''
if [[ -n "$server_pid" && -r "/proc/$server_pid/environ" ]]; then
    active_network_interface="$(
        /usr/bin/tr '\0' '\n' <"/proc/$server_pid/environ" | \
            /usr/bin/sed -n 's/^UURB_NETWORK_INTERFACE=//p' | \
            /usr/bin/tail -n 1
    )"
fi
if [[ "$network_interface" == all ]]; then
    printf 'INFO  UU can use all host network interfaces\n'
elif [[ ! -f "$network_filter" ]]; then
    fail 'the configured UU network-interface filter is missing'
elif [[ -n "$server_pid" ]] &&
     /usr/bin/grep -Fq "$network_filter" "/proc/$server_pid/maps" &&
     [[ -n "$active_network_interface" ]] &&
     [[ -d "/sys/class/net/$active_network_interface" ]] &&
     { [[ "$network_interface" == default ]] ||
       [[ "$active_network_interface" == "$network_interface" ]]; }; then
    pass "UU network-interface filter is active ($network_interface -> $active_network_interface)"
else
    fail "UU network-interface filter is not active ($network_interface)"
fi

account_state="$({
    find "$wine_prefix/drive_c/users/$bridge_user/AppData/Local/GameViewer" \
        -maxdepth 1 -type f -name 'setting_*.ini' \
        ! -name 'setting_guest_anonymous_id.ini' -print -quit 2>/dev/null
} || true)"
if [[ -n "$account_state" ]]; then
    pass 'UU account state is present'
else
    printf 'INFO  UU account login has not been observed yet\n'
fi

if ((stability_seconds > 0)) && [[ -n "$server_pid" ]]; then
    printf 'WAIT  checking one server PID for %s seconds\n' "$stability_seconds"
    sleep "$stability_seconds"
    current_pid="$(pgrep -o -u "$UID" -f 'GameViewerServer\.exe' || true)"
    if [[ "$current_pid" == "$server_pid" ]]; then
        pass "UU server remained stable for $stability_seconds seconds"
    else
        fail "UU server changed from $server_pid to ${current_pid:-none}"
    fi
    if [[ -n "$grd_pid" ]]; then
        current_grd_pid="$(
            grd_pid_for_port
        )"
        if [[ "$current_grd_pid" != "$grd_pid" ]]; then
            fail 'GNOME RDP changed during the descriptor-stability check'
        else
            current_grd_fd_count="$(
                /usr/bin/find "/proc/$grd_pid/fd" -maxdepth 1 -type l \
                    -printf '.\n' 2>/dev/null | /usr/bin/wc -l
            )"
            grd_fd_growth=$((current_grd_fd_count - grd_fd_count))
            if ((grd_fd_growth <= 16)); then
                pass "GNOME RDP descriptor growth stayed bounded (${grd_fd_growth} over ${stability_seconds}s)"
            else
                fail "GNOME RDP leaked $grd_fd_growth descriptors over ${stability_seconds}s"
            fi
        fi
    fi
fi

broker_success_pattern='route=broker .*result=1 error=0'
if [[ -f "$bridge_log" ]] && \
   grep -Eq "$broker_success_pattern" < <(tail -500 "$bridge_log"); then
    pass 'at least one real input event completed through the broker'
elif [[ -f "$bridge_log" ]] && \
     grep -Eq "$broker_success_pattern" "$bridge_log"; then
    pass 'historical controller input completed through the broker'
else
    printf 'INFO  no remote input event has been observed yet\n'
fi

if ((errors > 0)); then
    printf '%s verification check(s) failed\n' "$errors" >&2
    exit 1
fi
printf 'All bridge verification checks passed.\n'
