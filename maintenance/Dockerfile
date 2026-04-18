FROM nginx:alpine

RUN apk add --no-cache openssl

COPY maintenance.html /usr/share/nginx/html/maintenance.html
COPY nginx.conf /etc/nginx/conf.d/nginx-plain.conf
COPY nginx-ssl.conf /etc/nginx/conf.d/nginx-ssl.conf
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && rm -f /etc/nginx/conf.d/default.conf

ENTRYPOINT ["/entrypoint.sh"]
