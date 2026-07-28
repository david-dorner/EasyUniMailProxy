# Third-Party Notices

EasyUniMailProxy is licensed under the GNU General Public License v3.0 or later (see [LICENSE](LICENSE)). Its container images install the third-party components listed below from their official distribution points at build time. Each component remains under its own license; the license texts are available at the linked upstream sources.

## Modified third-party source in this repository

| Component | License | Notes |
|---|---|---|
| [openconnect-saml](https://github.com/mschabhuettl/openconnect-saml) (Matthias Schabhuettl) | GPL-3.0-or-later | `vpn/headless.py` is a modified copy of `openconnect_saml/headless.py`. The modifications are documented in the file header and are also licensed GPL-3.0-or-later. It is copied over the unmodified package (installed from PyPI) when the vpn image is built. |

## Base image

| Component | License | Source |
|---|---|---|
| Python 3.12 (`python:3.12-slim`, Debian based) | PSF-2.0 for Python; the Debian base packages under their own licenses | <https://hub.docker.com/_/python> |

## System packages installed in the vpn image (Debian apt)

| Component | License | Source |
|---|---|---|
| OpenConnect (`openconnect`) | LGPL-2.1 | <https://gitlab.com/openconnect/openconnect> |
| vpnc-scripts | GPL-2.0-or-later | <https://gitlab.com/openconnect/vpnc-scripts> |
| socat | GPL-2.0-or-later | <http://www.dest-unreach.org/socat/> |
| iproute2 | GPL-2.0-or-later | <https://wiki.linuxfoundation.org/networking/iproute2> |
| iputils (`ping`) | BSD-3-Clause / GPL-2.0-or-later | <https://github.com/iputils/iputils> |
| bash | GPL-3.0-or-later | <https://www.gnu.org/software/bash/> |
| ca-certificates (Mozilla CA bundle) | MPL-2.0 | <https://packages.debian.org/ca-certificates> |

## Python packages installed from PyPI (vpn image)

`pip install openconnect-saml keyrings.alt` pulls these and their dependencies:

| Package | License |
|---|---|
| openconnect-saml | GPL-3.0-or-later |
| keyrings.alt, attrs, keyring, jaraco.*, more-itertools, toml, urllib3, charset-normalizer, idna, PyOTP | MIT |
| requests, structlog | Apache-2.0 |
| certifi | MPL-2.0 |
| lxml, PySocks | BSD |
| pyxdg | LGPL-2.1 |

## Base image (mail container)

| Component | License | Source |
|---|---|---|
| Debian 12 "bookworm" (`debian:12-slim`) | Debian packages under their own licenses | <https://hub.docker.com/_/debian> |

## System packages installed in the mail image (Debian apt)

| Component | License | Source |
|---|---|---|
| Dovecot (`dovecot-core`, `dovecot-imapd`) | LGPL-2.1 and MIT (parts) | <https://www.dovecot.org/> |
| Postfix (`postfix`) | IBM Public License 1.0 / Eclipse Public License 2.0 | <http://www.postfix.org/> |
| isync / mbsync (`isync`) | GPL-2.0-or-later | <https://isync.sourceforge.io/> |
| gocryptfs (`gocryptfs`) | MIT | <https://nuetzlich.net/gocryptfs/> |
| libfuse / fuse3 (`fuse3`) | LGPL-2.1 (library), GPL-2.0 (utilities) | <https://github.com/libfuse/libfuse> |
| tpm2-tools | BSD-3-Clause | <https://github.com/tpm2-software/tpm2-tools> |
| OpenSSL (`openssl`) | Apache-2.0 | <https://www.openssl.org/> |
| curl | curl license (MIT-style) | <https://curl.se/> |
| ca-certificates (Mozilla CA bundle) | MPL-2.0 | <https://packages.debian.org/ca-certificates> |
| bash | GPL-3.0-or-later | <https://www.gnu.org/software/bash/> |
| Python 3 (`python3`) | PSF-2.0 | <https://www.python.org/> |
| python3-cryptography | Apache-2.0 or BSD-3-Clause | <https://cryptography.io/> |

## Downloaded binaries (mail image)

| Component | License | Source |
|---|---|---|
| lego (ACME / Let's Encrypt client) | MIT | <https://github.com/go-acme/lego> |

## External services (not redistributed)

| Service | Notes |
|---|---|
| [ntfy](https://ntfy.sh) | The watchdog sends push notifications to an ntfy topic you configure. ntfy is Apache-2.0; you can use the public ntfy.sh server or a self-hosted instance. Nothing from ntfy is bundled in this project. |

## Trademarks

"University of Graz", "uniLOGIN", "Cisco", "AnyConnect", "Microsoft Exchange", and "Keycloak" are trademarks of their respective owners. EasyUniMailProxy is an independent project and is not affiliated with, endorsed by, or supported by any of them.
