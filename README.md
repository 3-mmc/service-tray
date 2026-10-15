# ServiceTray

A Windows system-tray monitor for services on Windows **and** in WSL: what is listening
on which port, whether it answers, and whether its Docker container is healthy. Written
in [Xojo](https://xojo.com); a sibling of [LlamaTray](https://github.com/3-mmc/llama-tray).

- **Icon colour:** green when every service is up, orange when one is degraded (port open
  but the health check fails, or Docker says unhealthy), red when one is down, grey
  before the first probe or when the config is missing. Inside the disc, LlamaTray's
  white bar shows VRAM use.
- **Tooltip:** counts plus the names of anything not up, running models, VRAM.
- **Click:** every service at a glance. The name is on the left; the status mark and
  `:port` sit in a right-aligned column. Each service has a submenu (Open, Restart…,
  Copy port); the llama-swap entry also has LlamaTray's Unload / Unload all / Load menu,
  with the running models listed beneath it.
- **Ephemeral:** listeners nobody configured that appeared *after* ServiceTray started,
  such as a dev server or a demo on `localhost:xxxx`, with owner and start time. WSL
  processes are named when they run as your user (`python3 (WSL)`). Whatever was already
  listening at start goes under *Other listeners*.
- **Details…:** a window with the same sections as a table (status, port, side, owner,
  detail). Double-click opens a service; right-click gives the same actions as the menu.
  WSL is polled every 5 s while it is open.
- **Preferences…:** sort by environment (Windows / WSL, categories as grey sub-labels;
  the default), by category, by port or by name; fold fully healthy sections; hide idle
  optional services; show only a port range (e.g. 3000–9999). Saved to `settings.json`.
- **Check ports…:** see below.
- **Double-click:** refresh now.
- **`%APPDATA%\ServiceTray\status.txt`:** the same view, tab-separated, rewritten only
  when something changes, for scripts and agents.

## Where the data comes from

| Source | How | Default interval |
|---|---|---|
| Windows listeners | `GetExtendedTcpTable` + a Toolhelp snapshot, in-process (no netstat) | 5 s |
| WSL listeners + Docker | one `wsl.exe -e sh -c "ss -ltnH; docker ps -a …"` call | 15 s |
| Health | HTTP GET per service, only while its port is listening | per service (`every`), default 30 s |
| llama-swap | `/running`, `/v1/models` (as in LlamaTray) | 3 s / 30 s |
| VRAM | `nvml.dll` in-process (no `nvidia-smi`) | 3 s |

Under WSL's **mirrored networking**, WSL's listening ports do not show up in Windows'
TCP table at all, which is why the WSL side is probed separately. Before probing, the app
checks `wsl.exe -l --running`, so it never boots a stopped distro.

Measured cost (2026-10-15): about 0.8 CPU-seconds per minute and 82 MB private memory,
of which roughly 45 MB is `nvml.dll` and the driver bits it loads. Without the llama-swap
and VRAM polling it was 0.2 s/min and 37 MB.

## Port check

Ports get "eaten" on this machine in two ways that look the same from the outside (the
service cannot bind, `netstat` shows nothing):

1. **Windows excluded ranges.** Hyper-V/WinNAT lease port blocks, listed by
   `netsh int ipv4 show excludedportrange protocol=tcp`.
2. **Mirrored-networking phantoms.** A dead WSL process leaks the mirrored reservation:
   Windows refuses the port, nothing lists a holder, but WSL can still bind it.

*Check ports…* takes every configured port that nothing is listening on, plus
`checkPorts` from `services.json` (numbers or `"from-to"`). It tries a real bind on
Windows (Winsock, microseconds per port), compares failures against the excluded ranges,
and for the remaining failures asks WSL to bind the same ports. Each failure gets a
verdict: *reserved by Windows (range a–b)*, *phantom*, or *unbindable on both sides*. The
verdict also shows up next to the affected service. When a required Windows service goes
down, its port is checked automatically (at most every 5 minutes).

Being inside an excluded range does not by itself block a bind. On 2026-10-15,
11520–11535 and 11600 were administered exclusions and all of them bound fine. So the
check only reports ports that actually fail.

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
| `group` | category (AI, Media, …), shown as a sub-label or used for the category sort |

The top-level keys are `wslDistro`, `windowsEvery`, `wslEvery`, `healthEvery`,
`ignorePorts`, `ignoreFrom` (unlisted ports at or above this are hidden; the default is
49152, the ephemeral range), `checkPorts`, and `llamaSwap` (`{"url": …, "service": <name
of the llama-swap entry>}`, which turns on the model menu).

View options live separately in `settings.json`, written by the Preferences window.

Command-line flags: `--details` and `--prefs` open those windows at start;
`--check-ports` runs the port check after 8 s (results land in `status.txt`); `--menu`
pops the tray menu up at the mouse after 6 s (for screenshots).

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
