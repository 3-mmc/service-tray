# ServiceTray

A Windows system-tray monitor for services on Windows **and** in WSL: what is listening
on which port, whether it answers, and whether its Docker container is healthy. Written
in [Xojo](https://xojo.com); a sibling of [LlamaTray](https://github.com/3-mmc/llama-tray).

- **Icon colour:** green when every service is up, orange when one is degraded (port open
  but the health check fails, or Docker says unhealthy), red when one is down, grey
  before the first probe or when the config is missing.
- **Tooltip:** counts plus the names of anything not up.
- **Click:** services grouped by Windows / WSL, each with Open, Restart… and Copy port,
  plus an *Unlisted listeners* submenu for ports nobody put in the config.
- **Double-click:** refresh now.
- **`%APPDATA%\ServiceTray\status.txt`:** the same view, tab-separated, rewritten only
  when something changes, for scripts and agents.

## Where the data comes from

| Source | How | Default interval |
|---|---|---|
| Windows listeners | `GetExtendedTcpTable` + a Toolhelp snapshot, in-process (no netstat) | 5 s |
| WSL listeners + Docker | one `wsl.exe -e sh -c "ss -ltnH; docker ps -a …"` call | 15 s |
| Health | HTTP GET per service, only while its port is listening | per service (`every`), default 30 s |

Under WSL's **mirrored networking**, WSL's listening ports do not show up in Windows'
TCP table at all, which is why the WSL side is probed separately. Before probing, the app
checks `wsl.exe -l --running`, so it never boots a stopped distro.

Measured cost: about 0.2 CPU-seconds per minute and 37 MB of RAM.

## Configuration

`%APPDATA%\ServiceTray\services.json`. See `services.example.json`. An empty file is
created on first run. Use *Reload services.json* in the menu after editing.

| Key | Meaning |
|---|---|
| `side` | `win` or `wsl` |
| `port` | the port that must be listening (0 = don't check) |
| `health` | URL; any HTTP status below 500 counts as alive |
| `every` | seconds between health checks for this service |
| `docker` | container name; not running = down, unhealthy = degraded |
| `optional` | down shows as idle (grey ○) and does not turn the icon red |
| `open` | URL for the Open item |
| `restart` | command; a `wsl:` prefix runs it inside the distro |

The top-level keys are `wslDistro`, `windowsEvery`, `wslEvery`, `healthEvery`,
`ignorePorts`, and `ignoreFrom` (unlisted ports at or above this are hidden; the
default is 49152, the ephemeral range).

Health checks send `Accept-Encoding: identity`: URLConnection fails on Brotli bodies
(Gramps Web serves them) with "Error occurred while receiving data".

## Building

Same as LlamaTray: open `ServiceTray.xojo_project` in Xojo 2026r2+ and build for Windows
64-bit, or from WSL:

```sh
tools/xojo-ide build 'D:\Projekte\service-tray\ServiceTray.xojo_project'
```

Quit the running ServiceTray before rebuilding; the exe is locked while it runs.

## Licence

MIT
