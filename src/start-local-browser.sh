#!/usr/bin/env bash
set -euo pipefail

DISPLAY_NUM="${DISPLAY_NUM:-99}"
export DISPLAY=":${DISPLAY_NUM}"
SCREEN_GEOM="${SCREEN_GEOM:-1440x900x24}"
NOVNC_PORT="${NOVNC_PORT:-8988}"
VNC_PORT="${VNC_PORT:-5090}"
START_URL="${START_URL:-http://127.0.0.1:7870/}"
GUI_STATE_DIR="${GUI_STATE_DIR:-/tmp/local-browser}"
BROWSER_CMD="${BROWSER_CMD:-google-chrome --no-sandbox --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

mkdir -p "${GUI_STATE_DIR}" /tmp/.X11-unix
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"
mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}" || true

for bin in Xvfb openbox x11vnc websockify google-chrome curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[err] missing browser command: $bin" >&2; exit 1; }
done

/usr/local/bin/stop-local-browser >/dev/null 2>&1 || true

Xvfb "${DISPLAY}" -screen 0 "${SCREEN_GEOM}" -ac +extension GLX +render -noreset \
  >"${GUI_STATE_DIR}/xvfb.log" 2>&1 &
sleep 1
openbox >"${GUI_STATE_DIR}/openbox.log" 2>&1 &
sleep 1
x11vnc -display "${DISPLAY}" -forever -shared -nopw -listen 0.0.0.0 -rfbport "${VNC_PORT}" \
  >"${GUI_STATE_DIR}/x11vnc.log" 2>&1 &
sleep 1
websockify --web=/usr/share/novnc/ "0.0.0.0:${NOVNC_PORT}" "127.0.0.1:${VNC_PORT}" \
  >"${GUI_STATE_DIR}/novnc.log" 2>&1 &
sleep 1

mkdir -p "${GUI_STATE_DIR}/browser-profile"
nohup bash -lc \
  "${BROWSER_CMD} --user-data-dir='${GUI_STATE_DIR}/browser-profile' '${START_URL}'" \
  >"${GUI_STATE_DIR}/browser.log" 2>&1 &

cat <<EOF

BROWSER READY
  Studio : ${START_URL}
  noVNC  : http://127.0.0.1:${NOVNC_PORT}/vnc.html
  VNC    : 127.0.0.1:${VNC_PORT}
  Display: ${DISPLAY} (${SCREEN_GEOM})

RunPod HTTP services to expose:
  ${NOVNC_PORT}  -> in-pod Chrome/noVNC
  7870           -> direct SeedVR Studio UI (optional)

EOF
