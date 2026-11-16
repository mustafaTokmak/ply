---
name: ply
description: Control the Ply macOS app, which keeps a Mac on its iPhone's USB hotspot and combines Wi-Fi + iPhone USB for more bandwidth. Use when the user wants their Mac to use the iPhone over USB, wants faster internet from Wi-Fi plus their phone, or asks why tethering or the connection is not working.
---

# Ply

Ply is a free, open-source macOS menu bar app that keeps your Mac on your iPhone's USB hotspot instead of Wi-Fi, and can combine Wi-Fi + iPhone USB (and Ethernet) so many connections at once use every link. No VPN, no account, no server: everything runs on the Mac.

## Tools

Prefer the MCP server (`ply mcp`, tools `ply_<action>`). Otherwise use the CLI (`ply ... --json`). Both return JSON.

| Action | CLI | MCP |
| --- | --- | --- |
| Status | `ply status [--json|--md]` | `ply_status` |
| Diagnose | `ply diagnose [--json]` | `ply_diagnose` |
| Copy agent prompt | `ply agent-prompt` | `ply_agent_prompt` |
| Put iPhone USB first | `ply prefer-usb` | `ply_prefer_usb` |
| Combine Wi-Fi + iPhone | `ply combine on [--split connection|site] [--no-system-proxy]` | `ply_combine_start` |
| Stop combining | `ply combine off` | `ply_combine_stop` |
| Speed test | `ply speedtest [--seconds 5] [--mode both]` | `ply_speed_test` |
| Wi-Fi power | `ply wifi on|off` | `ply_set_wifi_power` |
| Leave Wi-Fi network | `ply wifi disconnect` | `ply_disconnect_wifi` |
| Settings | `ply settings` | `ply_get_settings` |
| Change settings | `ply settings set key=value [key=value ...]` | `ply_update_settings` |
| Repair iPhone USB | `ply repair` | `ply_repair_tether` |
| Restore proxy settings | `ply restore-proxies` | `ply_restore_proxies` |
| Install helper | `ply helper install (or: sudo ply helper install)` | `ply_install_helper` |
| Uninstall helper | `ply helper uninstall` | `ply_uninstall_helper` |
| Open at login | `ply login-item on|off` | `ply_set_launch_at_login` |
| Open Ply window | `ply open` | `ply_show_window` |
| About Ply | `ply about` | `ply_about` |
| Quit Ply | `ply quit` | `ply_quit` |

## Workflows

### Put the Mac on iPhone USB
1. `ply diagnose --json`. If a finding says the iPhone is not sharing, tell the user: on the iPhone open Settings > Personal Hotspot and turn on Allow Others to Join, then keep the phone unlocked.
2. If `helper.installed` is false, run `ply helper install`. It shows a macOS password dialog to the user; over SSH use `sudo ply helper install`. Tell the user before you do this.
3. `ply prefer-usb`, then `ply status --json`. Done when `primary` is the link whose `kind` is `tether`.
4. Optional: `ply settings set wifiOffWhenUSB=true` to turn Wi-Fi off whenever the cable is up.

### Combine Wi-Fi + iPhone for more bandwidth
1. Check `ply status --json` shows two links with `up: true` (Wi-Fi on a normal network plus iPhone USB). If Wi-Fi is on the iPhone's own hotspot, combining adds nothing.
2. `ply combine on` (add `--split site` if the user logs in to sites that dislike changing IPs).
3. `ply speedtest --json` to show each link alone versus combined. Warn first: it uses mobile data (up to `speedTestMaxMB` per link per phase).
4. To keep it on automatically: `ply settings set combineAuto=true`.
5. To stop: `ply combine off`. It restores the proxy settings.

### Something is broken
1. `ply diagnose --json`; each finding has `fix` (an action) and `agentPrompt`.
2. iPhone plugged in but no internet: `ply repair`, then check the cable and Personal Hotspot.
3. Web pages fail while combining: `ply combine off` restores normal networking at once. `ply restore-proxies` is always safe.

## Rules
- Ask before `install_helper`, `uninstall_helper`, `set_wifi_power` and `speed_test` (password prompt, losing Wi-Fi, mobile data).
- Combine helps many connections at once, not one single download. Say so when you report speed results.
- Never edit macOS proxy or network settings directly; use Ply so it can restore them.
