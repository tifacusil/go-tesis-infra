# API Gateway = nginx + consul-template (LB round-robin con upstreams
# regenerados desde Consul). consul-template observa el catálogo de salud y
# recarga nginx cuando una instancia se registra o cae.
FROM nginx:1.27-alpine

ARG CONSUL_TEMPLATE_VERSION=0.39.1
ARG TARGETARCH=amd64

RUN apk add --no-cache curl unzip \
 && curl -fsSL -o /tmp/ct.zip \
      "https://releases.hashicorp.com/consul-template/${CONSUL_TEMPLATE_VERSION}/consul-template_${CONSUL_TEMPLATE_VERSION}_linux_${TARGETARCH}.zip" \
 && unzip /tmp/ct.zip -d /usr/local/bin \
 && rm /tmp/ct.zip \
 && apk del curl unzip

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
