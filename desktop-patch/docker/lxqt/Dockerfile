# Build: docker build -t tzshim-lxqt -f desktop-patch/docker/lxqt/Dockerfile .
#
# LXQt's clock widget reads its timezone from ~/.config/lxqt/panel.conf
# (INI). We install lxqt-panel so the config path and file schema match
# a real LXQt session; the check seeds that file, runs the adapter, and
# verifies the INI round-trips. No D-Bus session is required because
# LXQt's panel backend is file-based.
FROM docker.io/library/debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        tzdata \
        lxqt-panel \
        liblxqt2 \
        dconf-cli \
        python3 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY . /opt/canadian-tz-shim
RUN chmod 0755 /opt/canadian-tz-shim/install.sh \
              /opt/canadian-tz-shim/lib/custom_zones.sh \
              /opt/canadian-tz-shim/desktop-patch/desktop-patch.sh

# Preseed /etc/localtime so install.sh's auto-detection picks Vancouver
# (Debian slim defaults to Etc/UTC, which would drop the installer into its
# interactive menu and exit non-zero.)
RUN ln -sf /usr/share/zoneinfo/America/Vancouver /etc/localtime
RUN bash /opt/canadian-tz-shim/install.sh

COPY desktop-patch/docker/common/entrypoint.sh /usr/local/bin/dtp-entrypoint
COPY desktop-patch/docker/common/check_lib.sh  /usr/local/bin/dtp-check-lib
COPY desktop-patch/docker/lxqt/check.sh        /usr/local/bin/dtp-check
RUN chmod 0755 /usr/local/bin/dtp-entrypoint /usr/local/bin/dtp-check

ENV DESKTOP_ID=lxqt \
    CAP_VALIDATION=integration \
    DTP_NEEDS_DBUS=0 \
    REPO_DIR=/opt/canadian-tz-shim

ENTRYPOINT ["/usr/local/bin/dtp-entrypoint"]
CMD ["dtp-check"]
