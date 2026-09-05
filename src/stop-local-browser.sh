#!/usr/bin/env bash
set -u
DISPLAY_NUM="${DISPLAY_NUM:-99}"
NOVNC_PORT="${NOVNC_PORT:-8988}"
VNC_PORT="${VNC_PORT:-5090}"
pkill -f "websockify.*${NOVNC_PORT}" >/dev/null 2>&1 || true
pkill -f "x11vnc.*${VNC_PORT}" >/dev/null 2>&1 || true
pkill -x openbox >/dev/null 2>&1 || true
pkill -f "Xvfb :${DISPLAY_NUM}" >/dev/null 2>&1 || true
pkill -f "google-chrome.*local-browser/browser-profile" >/dev/null 2>&1 || true
