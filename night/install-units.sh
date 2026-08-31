#!/bin/bash
# Make the night coder survive a reboot, on whichever host it lives.
#
# Everything on these boxes has been started with nohup, which means every
# reboot needs a human to hand-restart the model server and both relays. These
# are systemd --user units plus linger, so the machine brings itself back.
#
#   install-units.sh [ctx]      # default 262144
#   install-units.sh --remove
#
# Linger is the part that is easy to miss: without `loginctl enable-linger`
# the user manager stops with your last ssh session, so the units never start
# at boot at all and everything looks mysteriously dead in the morning.
#
# Deliberately NOT Restart=always. The failure mode of this stack is
# overcommitting VRAM until the box cannot fork; a unit that restarts straight
# back into the same allocation turns one crash into a loop that is far harder
# to break into than a single dead service. on-failure with a burst limit means
# systemd tries a few times and then stops and leaves the evidence.

set -u
CTX="${1:-262144}"
UNITS=~/.config/systemd/user
SELF=~/qwen-service.sh
RELAY=~/wgexpose.py

if [ "${1:-}" = "--remove" ]; then
    systemctl --user disable --now qwen-night.service relay-8088.service relay-8089.service 2>/dev/null
    rm -f "$UNITS"/qwen-night.service "$UNITS"/relay-808*.service
    systemctl --user daemon-reload
    echo "[units] removed (linger left alone — disable with: loginctl disable-linger $USER)"
    exit 0
fi

[ -x "$SELF" ] || { echo "[units] $SELF missing or not executable"; exit 1; }
[ -f "$RELAY" ] || { echo "[units] $RELAY missing"; exit 1; }
mkdir -p "$UNITS"

cat > "$UNITS/qwen-night.service" <<EOF
[Unit]
Description=Qwen3.8-27B night coder (llama.cpp)
After=network-online.target

[Service]
Type=simple
# qwen-service.sh refuses to start if the context cannot fit in real VRAM,
# so a bad config fails fast here instead of taking the machine down.
ExecStart=$SELF foreground $CTX
Restart=on-failure
RestartSec=30
StartLimitBurst=3
StartLimitIntervalSec=600
Nice=5

[Install]
WantedBy=default.target
EOF

# One relay per served port. wgexpose runs in the foreground already, which is
# exactly what a Type=simple unit wants.
for pair in "8088:GLM" "8089:Qwen night coder"; do
    port="${pair%%:*}"; what="${pair##*:}"
    cat > "$UNITS/relay-$port.service" <<EOF
[Unit]
Description=wgexpose relay 1$port -> 127.0.0.1:$port ($what)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $RELAY 10.72.0.1:1$port 127.0.0.1:$port --allow 10.72.0.12
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
done

systemctl --user daemon-reload

# Without this the units exist but never run at boot.
if loginctl enable-linger "$USER" 2>/dev/null; then
    echo "[units] linger enabled for $USER"
else
    echo "[units] WARNING: could not enable linger — units will not start at boot."
    echo "[units] ask the admins for: loginctl enable-linger $USER"
fi

systemctl --user enable relay-8088.service relay-8089.service >/dev/null 2>&1
echo "[units] relays enabled at boot"
echo "[units] qwen-night.service installed but NOT enabled — the model is a"
echo "[units] deliberate choice, not something that should seize the cards on"
echo "[units] every reboot. Start a shift with:  systemctl --user start qwen-night"
echo "[units] Enable at boot only if this host is dedicated to it:"
echo "[units]   systemctl --user enable qwen-night"
