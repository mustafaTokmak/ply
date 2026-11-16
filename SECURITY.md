# Security

Ply has one privileged part: the helper LaunchDaemon (`app.ply.helper`). Its whole vocabulary is in
`Sources/PlyHelper/main.swift`: version, reorder existing network services, set services' auto-proxy to
`http://127.0.0.1:<port>/proxy.pac` (any other URL is refused), restore the backed-up proxy settings, and
enable/disable one existing service. It runs no shell commands and only answers root or the console user.

The local API (127.0.0.1:7590) requires a per-user bearer token and a 127.0.0.1/localhost Host header.

Please report vulnerabilities privately through GitHub's "Report a vulnerability" (Security tab) rather than in a public issue.
