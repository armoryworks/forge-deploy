#!/bin/sh
# Maintenance container entrypoint
#
# Always generates a self-signed cert and serves the maintenance page on
# BOTH :80 and :443, so the page reaches users regardless of:
#   - whether the real UI was HTTP or HTTPS
#   - whether the browser auto-upgrades HTTP -> HTTPS (LibreWolf HTTPS-Only,
#     cached HSTS, etc.)
#   - whether a reverse proxy upstream targets the HTTP or HTTPS side
#
# The refresh script decides which host ports to publish.

mkdir -p /etc/nginx/certs

# If the host mounted real certs (e.g. Cloudflare Origin Cert for Full-strict),
# reuse them so CF / reverse proxies don't reject the maintenance page during
# refresh. Otherwise fall back to a throwaway self-signed cert.
if [ -s /etc/nginx/certs/selfsigned.crt ] && [ -s /etc/nginx/certs/selfsigned.key ]; then
    echo "[maintenance] Using mounted certificate from /etc/nginx/certs"
else
    echo "[maintenance] No mounted cert found — generating self-signed fallback"
    openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
        -keyout /etc/nginx/certs/selfsigned.key \
        -out /etc/nginx/certs/selfsigned.crt \
        -subj "/CN=maintenance" 2>/dev/null
fi

cp /etc/nginx/conf.d/nginx-dual.conf /etc/nginx/conf.d/default.conf

# Remove the source configs to avoid duplicate server blocks
rm -f /etc/nginx/conf.d/nginx-dual.conf /etc/nginx/conf.d/nginx-plain.conf /etc/nginx/conf.d/nginx-ssl.conf

echo "[maintenance] Dragon is standing guard on :80 and :443"
exec nginx -g 'daemon off;'
