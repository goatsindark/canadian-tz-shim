# Build: docker build -t tzshim-gnome -f desktop-patch/docker/gnome/Dockerfile .
FROM docker.io/library/debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
# Only what the clock widget's config path needs: the org.gnome.desktop.datetime
# schema (shipped by gsettings-desktop-schemas), dconf backend so gsettings
# can persist writes, dbus for the session bus, python3 for the patcher.
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
        libnotify4 \
    && rm -rf /var/lib/apt/lists/*

COPY . /opt/canadian-tz-shim
RUN chmod 0755 /opt/canadian-tz-shim/install.sh \
              /opt/canadian-tz-shim/lib/custom_zones.sh \
              /opt/canadian-tz-shim/desktop-patch/desktop-patch.sh

# Install the custom Canadian/* zones (still as root inside the container).
# Preseed /etc/localtime so install.sh's auto-detection picks Vancouver
# (Debian slim defaults to Etc/UTC, which would drop the installer into its
# interactive menu and exit non-zero.)
RUN ln -sf /usr/share/zoneinfo/America/Vancouver /etc/localtime
RUN bash /opt/canadian-tz-shim/install.sh

# Per-desktop check environment (consumed by common/gsettings_check.sh).
ENV DESKTOP_ID=gnome \
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
