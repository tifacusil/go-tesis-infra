#!/bin/sh
# Entrypoint del gateway: render inicial -> arranca nginx -> consul-template
# al frente regenerando la config y recargando nginx ante cambios en Consul.
set -eu

# 1) Render inicial SIN command (nginx aún no corre): produce un nginx.conf
#    válido aunque no haya instancias todavía (backend caído -> 502).
consul-template \
  -consul-addr="${CONSUL_ADDR:-consul-1:8500}" \
  -template="/etc/consul-template/nginx.conf.ctmpl:/etc/nginx/nginx.conf" \
  -once

# 2) Valida y arranca nginx (master + workers) en background.
nginx -t
nginx -g 'daemon off;' &
NGINX_PID=$!

# 3) consul-template en foreground con el .hcl (incluye command=nginx -s reload):
#    observa Consul, re-renderiza y recarga nginx en cada cambio.
consul-template -config=/etc/consul-template/consul-template.hcl &
CT_PID=$!

# Si cualquiera de los dos muere, termina el contenedor (restart:unless-stopped).
wait -n "$NGINX_PID" "$CT_PID"
exit $?
