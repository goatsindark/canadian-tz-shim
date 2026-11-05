# Build: docker build -t tzshim-budgie -f desktop-patch/docker/budgie/Dockerfile .
#
# Ubuntu Budgie's clock reuses org.gnome.desktop.datetime.timezone (the
# Budgie panel applet is a GNOME-derived implementation). This container
# is functionally the GNOME container with a different DESKTOP_ID.
FROM docker.io/library/debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        tzdata \
        gsettings-desktop-schemas \
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

ENV DESKTOP_ID=budgie \
    SCHEMA=org.gnome.desktop.datetime \
    KEY=timezone \
    ID_FORMAT=variant \
    SEED_VALUE_VARIANT="(uv '(0, 'America/Vancouver'))" \
    EXPECTED_VARIANT="(uv '(0, 'Canadian/PCT'))" \
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
