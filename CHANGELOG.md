# Changelog

## 0.1.1

- New app icon.
- Ply opens its menu in a window on first launch, when you open the app again, or when the menu bar icon is hidden (a full menu bar on a MacBook with a notch).
- New action `show_window` (`ply open`, MCP `ply_show_window`) so agents can show the window too.
- The local API serves an OpenAPI 3.1 description at `/openapi.json`; the README starts with a section for AI agents.
- Install with Homebrew: `brew install mustafaTokmak/tap/ply`.

## 0.1.0

- USB first: keep iPhone/iPad USB above Wi-Fi in the service order, leave the iPhone's Wi-Fi hotspot when cabled, optional Wi-Fi off while cabled.
- Combine: local SOCKS5/SOCKS4a/HTTP proxy that spreads connections over Wi-Fi, iPhone USB and Ethernet, with health checks, failover, per-connection or per-site splitting, and macOS auto-proxy (PAC) setup.
- Speed test per link and combined.
- Diagnose with one-click fixes and agent prompts.
- Agent interfaces for every action: CLI, local HTTP API, MCP server, llms.txt, SKILL.md.
