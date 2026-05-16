# forge-backup — sidecar that takes scheduled snapshots of the Forge
# Postgres database + MinIO buckets onto a host-mounted volume.
#
# Why a sidecar (not a Hangfire job in forge-api): backups must keep
# running when forge-api is down — that's the main scenario you need
# backups for. Sidecar also keeps the bulk I/O out of the app process.
#
# v1 destination is local volume (./backups). S3 / SFTP destinations
# land later as alternate mc remote configs driven by env vars (and,
# eventually, by admin-UI config read from the DB).

FROM postgres:17-alpine

ARG SUPERCRONIC_VERSION=v0.2.29

RUN apk add --no-cache bash ca-certificates curl tzdata \
 && curl -fsSL "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
      -o /usr/local/bin/supercronic \
 && chmod +x /usr/local/bin/supercronic \
 && curl -fsSL "https://dl.min.io/client/mc/release/linux-amd64/mc" \
      -o /usr/local/bin/mc \
 && chmod +x /usr/local/bin/mc

COPY backup.sh entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh

WORKDIR /backups
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
