# NM VPN — Omarchy shell plugin

Bar widget that lists every **OpenVPN** and **WireGuard** connection configured in
NetworkManager and lets you switch each one on or off independently.

- Left-click the shield: popup with one switch per connection (↑/↓ + Enter work too).
- Right-click: opens `nm-connection-editor`.
- Icon shows a locked shield while any VPN is connected; the tooltip names them.
- Follows changes made elsewhere (`nmcli`, other applets) via `nmcli monitor`.
- Failures are reported with a notification. If a connection needs a password
  (e.g. OpenVPN with password auth), a terminal opens running `nmcli --ask connection up`.

## Install

```bash
omarchy plugin add <git-url-or-path-to-this-repo> --enable
```

Remove with `omarchy plugin remove pointpack.nm-vpn`.

## Settings (`~/.config/omarchy/shell.json` entry)

| key                  | default | meaning                                       |
|----------------------|---------|-----------------------------------------------|
| `refreshIntervalSec` | 30      | fallback poll interval                        |
| `hideWhenEmpty`      | false   | hide the bar icon if no VPN profiles exist    |

Requires: `networkmanager`, `jq`, `libnotify`; `networkmanager-openvpn` for OpenVPN profiles.
