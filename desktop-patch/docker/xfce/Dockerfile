# Build: docker build -t tzshim-xfce -f desktop-patch/docker/xfce/Dockerfile .
#
# XFCE's clock plugin stores its timezone in the Xfconf `xfce4-panel`
# channel. We install xfce4-panel + xfce4-settings (xfsettingsd provides
# the Xfconf backend D-Bus service) so `xfconf-query` works inside a
# private dbus session, exactly as it would on a live XFCE desktop.
FROM docker.io/library/debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        tzdata \
        xfce4-panel \
        xfce4-settings \
        xfconf \
        dbus \
        dbus-x11 \
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
COPY desktop-patch/docker/xfce/check.sh        /usr/local/bin/dtp-check
RUN chmod 0755 /usr/local/bin/dtp-entrypoint /usr/local/bin/dtp-check

ENV DESKTOP_ID=xfce \
    CAP_VALIDATION=integration \
    DTP_NEEDS_DBUS=1 \
    REPO_DIR=/opt/canadian-tz-shim

ENTRYPOINT ["/usr/local/bin/dtp-entrypoint"]
CMD ["dtp-check"]
