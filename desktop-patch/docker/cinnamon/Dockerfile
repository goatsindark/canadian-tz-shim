# Build: docker build -t tzshim-check-cinnamon -f desktop-patch/docker/cinnamon/Dockerfile .
#
# On Debian trixie, cinnamon's packages do not ship a per-user gsettings
# timezone key (the schema org.cinnamon.desktop.datetime does not exist
# in any cinnamon-desktop-data or related package). The check verifies
# that fact against the real installed schemas and reports the correct
# "adapter not needed" outcome. We keep the schema name in the Dockerfile
# env for future runs on Mint proper, where the schema does exist.
FROM docker.io/library/debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        tzdata \
        cinnamon-desktop-data \
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

ENV DESKTOP_ID=cinnamon \
    SCHEMA=org.cinnamon.desktop.datetime \
    KEY=timezone \
    HAS_EXPLICIT_KEY=0 \
    EXPECTED_CANON=Canadian/PCT \
    ID_FORMAT=variant \
    CAP_VALIDATION=integration \
    DTP_NEEDS_DBUS=1 \
    REPO_DIR=/opt/canadian-tz-shim

COPY desktop-patch/docker/common/entrypoint.sh    /usr/local/bin/dtp-entrypoint
COPY desktop-patch/docker/common/check_lib.sh     /usr/local/bin/dtp-check-lib
COPY desktop-patch/docker/common/gsettings_check.sh /usr/local/bin/dtp-gsettings-check
RUN chmod 0755 /usr/local/bin/dtp-entrypoint /usr/local/bin/dtp-gsettings-check

ENTRYPOINT ["/usr/local/bin/dtp-entrypoint"]
CMD ["dtp-gsettings-check"]
