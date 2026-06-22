# consul-template — regenera el nginx.conf desde el catálogo de Consul y
# recarga nginx cuando cambian las instancias sanas de un servicio.

consul {
  address = "consul-1:8500"

  retry {
    enabled  = true
    attempts = 0          # reintentos infinitos (espera a que Consul esté arriba)
    backoff  = "1s"
    max_backoff = "10s"
  }
}

# Re-evalúa con un pequeño debounce para agrupar cambios en ráfaga (varias
# instancias registrándose/cayendo a la vez) en un solo render+reload.
wait {
  min = "2s"
  max = "10s"
}

log_level = "info"

template {
  source      = "/etc/consul-template/nginx.conf.ctmpl"
  destination = "/etc/nginx/nginx.conf"

  # Valida la config antes de aplicar; si falla, NO sobreescribe ni recarga.
  command         = "nginx -t && nginx -s reload"
  command_timeout = "15s"

  # Genera aunque algún servicio no tenga instancias (el template emite un
  # backend caído -> 502) para que nginx siempre tenga config válida.
  error_on_missing_key = false
  wait {
    min = "2s"
    max = "10s"
  }
}
