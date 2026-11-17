#!/usr/bin/env bash
# Put service-tray on PATH, seed the config, and start it with the desktop session.
#   linux/install.sh            install + autostart
#   linux/install.sh --remove   undo (keeps ~/.config/service-tray)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$HOME/.local/bin/service-tray"
conf="${XDG_CONFIG_HOME:-$HOME/.config}"
desktop="$conf/autostart/service-tray.desktop"

if [[ "${1:-}" == "--remove" ]]; then
    rm -f "$bin" "$desktop"
    echo "removed $bin and $desktop"
    exit 0
fi

mkdir -p "$HOME/.local/bin" "$conf/autostart" "$conf/service-tray"
ln -sfn "$here/service-tray" "$bin"
[[ -e "$conf/service-tray/services.json" ]] || cp "$here/services.example.json" "$conf/service-tray/services.json"
cat > "$desktop" <<EOF
[Desktop Entry]
Type=Application
Name=ServiceTray
Comment=Tray monitor for local services, Docker containers and the home server
Exec=$bin
Icon=network-server
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
echo "installed: $bin -> $here/service-tray; autostart $desktop"
echo "config:    $conf/service-tray/services.json"
