# devkit: proxy de salida con lista blanca. Único contenedor con acceso a
# internet; el contenedor de trabajo solo puede hablar con él.
FROM alpine:3.22
RUN apk add --no-cache tinyproxy socat \
 && mkdir -p /var/log/tinyproxy \
 && chown tinyproxy:tinyproxy /var/log/tinyproxy
COPY tinyproxy.conf allowlist.base /etc/tinyproxy/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 8888 54546
ENTRYPOINT ["/entrypoint.sh"]
