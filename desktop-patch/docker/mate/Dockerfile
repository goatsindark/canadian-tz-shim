# Build: docker build -t tzshim-mate -f desktop-patch/docker/mate/Dockerfile .
#
# MATE's clock applet reads its timezone via the org.mate.clock schema
# when it exists, or a per-applet org.mate.panel.applet.clock schema.
# Neither is guaranteed on every MATE build; the check script reports
# the desktop as "unsupported" if the schema/key is absent.
FROM docker.io/library/debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        tzdata \
        mate-settings-daemon \
        mate-panel \
        dconf-cli \
        libglib2.0-bin \
        dconf-gsettings-backend \
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

# MATE's clock on Debian ships without a per-user timezone gsettings key.
# The check will confirm "no key → follows /etc/localtime" as a valid
# integration finding.
ENV DESKTOP_ID=mate \
    SCHEMA=org.gnome.desktop.datetime \
    KEY=timezone \
    HAS_EXPLICIT_KEY=0 \
    EXPECTED_CANON=Canadian/PCT \
    CAP_VALIDATION=integration \
    DTP_NEEDS_DBUS=1 \
    REPO_DIR=/opt/canadian-tz-shim

COPY desktop-patch/docker/common/entrypoint.sh    /usr/local/bin/dtp-entrypoint
COPY desktop-patch/docker/common/check_lib.sh     /usr/local/bin/dtp-check-lib
COPY desktop-patch/docker/common/gsettings_check.sh /usr/local/bin/dtp-gsettings-check
RUN chmod 0755 /usr/local/bin/dtp-entrypoint /usr/local/bin/dtp-gsettings-check

ENTRYPOINT ["/usr/local/bin/dtp-entrypoint"]
CMD ["dtp-gsettings-check"]
