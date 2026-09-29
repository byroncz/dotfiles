# devkit: proxy de salida con lista blanca. Único contenedor con acceso a
# internet; el contenedor de trabajo solo puede hablar con él.
FROM alpine:3.22
# bash: el shim del editor (DEVKIT-259) necesita `read -u` sobre un fd
# explícito y expansión de subcadena (`${var:i:n}`), que busybox ash no
# tiene. Alpine no la trae por defecto.
RUN apk add --no-cache tinyproxy socat bash \
 && mkdir -p /var/log/tinyproxy \
 && chown tinyproxy:tinyproxy /var/log/tinyproxy
COPY tinyproxy.conf allowlist.base /etc/tinyproxy/
COPY entrypoint.sh /entrypoint.sh
COPY proxy-shim.sh /opt/devkit/proxy-shim.sh
RUN chmod +x /entrypoint.sh /opt/devkit/proxy-shim.sh
EXPOSE 8888 45454 3001
ENTRYPOINT ["/entrypoint.sh"]
