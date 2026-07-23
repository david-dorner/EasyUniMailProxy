# Black-box VPN/mail-path monitor with ntfy alerts. Pure stdlib, no deps.
FROM python:3.12-slim

LABEL org.opencontainers.image.title="EasyUniMailProxy - watchdog" \
      org.opencontainers.image.description="Monitors the mail path and sends ntfy alerts on failure" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.source="https://github.com/david-dorner/EasyUniMailProxy"

COPY watchdog.py /watchdog.py

ENTRYPOINT ["python3", "-u", "/watchdog.py"]
