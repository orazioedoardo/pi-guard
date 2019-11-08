# Update Oct 14 2019

Developement of WireGuard support continues in the PiVPN repository [here](https://github.com/pivpn/pivpn/tree/test-wireguard). This repository will no longer be updated.

# Pi-guard

Modified version of the original [PiVPN](https://github.com/pivpn/pivpn) script that sets up a WireGuard server and provides management scripts.

## Installation
`curl -L https://raw.githubusercontent.com/orazioedoardo/pi-guard/master/auto-install/install.sh | bash`

## Caveats
* Only Raspbian 9 (stretch) is supported.
* WireGuard module needs to be reinstalled on kernel upgrades.
* `pi-guard -c` only runs `wg show`.
