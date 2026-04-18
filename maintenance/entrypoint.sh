#!/bin/sh
# Maintenance container entrypoint
# Generates a self-signed cert if SSL mode is enabled, then starts nginx.

if [ "${SSL_MODE}" = "true" ]; then
    echo "[maintenance] SSL mode — generating self-signed certificate"
    mkdir -p /etc/nginx/certs
    openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
        -keyout /etc/nginx/certs/selfsigned.key \
        -out /etc/nginx/certs/selfsigned.crt \
        -subj "/CN=maintenance" 2>/dev/null
    cp /etc/nginx/conf.d/nginx-ssl.conf /etc/nginx/conf.d/default.conf
    echo "[maintenance] Using SSL config (port 443)"
else
    cp /etc/nginx/conf.d/nginx-plain.conf /etc/nginx/conf.d/default.conf
    echo "[maintenance] Using plain HTTP config (port 80)"
fi

# Remove the source configs to avoid duplicate server blocks
rm -f /etc/nginx/conf.d/nginx-plain.conf /etc/nginx/conf.d/nginx-ssl.conf

echo "[maintenance] Dragon is standing guard"
exec nginx -g 'daemon off;'
