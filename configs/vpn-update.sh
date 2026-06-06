#!/bin/bash
# Check for and (optionally) apply updates to the pivpn-config on the Pi.
#   vpn-update.sh check   -> prints JSON: {behind, local, remote, log}
#   vpn-update.sh apply   -> git pull + redeploy changed config files, prints JSON result
set -e
REPO="$HOME/pivpn-config"
cd "$REPO"

git fetch -q origin 2>/dev/null || true
LOCAL=$(git rev-parse --short HEAD)
REMOTE=$(git rev-parse --short origin/master 2>/dev/null || git rev-parse --short origin/main)
BEHIND=$(git rev-list --count HEAD..origin/master 2>/dev/null || git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)

if [ "$1" = "check" ]; then
    LOG=$(git log --oneline HEAD..origin/master 2>/dev/null | head -20 || true)
    python3 - "$BEHIND" "$LOCAL" "$REMOTE" "$LOG" << 'PY'
import json,sys
print(json.dumps({
    "behind": int(sys.argv[1]) if sys.argv[1].isdigit() else 0,
    "local": sys.argv[2], "remote": sys.argv[3],
    "log": [l for l in sys.argv[4].splitlines() if l.strip()],
}))
PY
    exit 0
fi

if [ "$1" = "apply" ]; then
    if [ "$BEHIND" = "0" ]; then
        echo '{"applied": false, "reason": "already up to date", "local": "'"$LOCAL"'"}'
        exit 0
    fi
    # Stash any local drift so the pull is clean, then pull.
    git stash -q 2>/dev/null || true
    git pull -q --ff-only origin master 2>/dev/null || git pull -q --ff-only origin main
    NEW=$(git rev-parse --short HEAD)

    # Redeploy the files that live outside the repo working tree.
    sudo cp "$REPO/configs/vpn-router-setup.sh" /usr/local/bin/vpn-router-setup.sh
    sudo chmod +x /usr/local/bin/vpn-router-setup.sh
    [ -f "$REPO/configs/90-wifi-powersave-off" ] && \
        sudo cp "$REPO/configs/90-wifi-powersave-off" /etc/NetworkManager/dispatcher.d/90-wifi-powersave-off && \
        sudo chmod +x /etc/NetworkManager/dispatcher.d/90-wifi-powersave-off
    [ -f "$REPO/configs/cpu-performance.service" ] && \
        sudo cp "$REPO/configs/cpu-performance.service" /etc/systemd/system/cpu-performance.service && \
        sudo systemctl daemon-reload

    # Redeploy the control-app helper scripts (incl. this one) so they stay
    # current. The new copy of vpn-update.sh takes effect on the NEXT run.
    for helper in vpn-status.sh switch-server.sh vpn-update.sh vpn-audit.sh vpn-stats.sh vpn-ctl.sh; do
        [ -f "$REPO/configs/$helper" ] && \
            sudo cp "$REPO/configs/$helper" "/usr/local/bin/$helper" && \
            sudo chmod +x "/usr/local/bin/$helper"
    done

    # Re-apply the live router rules (kill switch, NAT, NAS allowlist, DNS).
    sudo /usr/local/bin/vpn-router-setup.sh >/dev/null 2>&1 || true

    python3 - "$NEW" << 'PY'
import json,sys
print(json.dumps({"applied": True, "now_at": sys.argv[1]}))
PY
    exit 0
fi

echo '{"error": "usage: vpn-update.sh check|apply"}'
exit 1
