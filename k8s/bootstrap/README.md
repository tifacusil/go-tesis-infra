# Bootstrap del cluster (k3s + sealed-secrets)

Pasos para dejar el VPS listo y desplegar el sistema. Se ejecutan **una vez**
(salvo el sellado de secrets, que se repite si cambian valores).

## 1. Instalar k3s en el VPS

```bash
curl -sfL https://get.k3s.io | sh -
# kubeconfig queda en /etc/rancher/k3s/k3s.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes        # debe verse Ready
```

k3s ya trae: Traefik (ingress), ServiceLB/Klipper (LoadBalancer), local-path
(storage class default). No hace falta instalar nada más para esos.

## 2. Instalar el controller sealed-secrets

```bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml
```

Instalar la CLI `kubeseal` (en el VPS o en tu máquina con acceso al cluster):
descargar el binario del release de `bitnami-labs/sealed-secrets` y ponerlo en PATH.

### Respaldar la clave privada del controller (IMPORTANTE)

Sin esta clave no se pueden descifrar los SealedSecret tras reinstalar el cluster.

```bash
kubectl -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > sealed-secrets-key.backup.yaml
# guardar FUERA de git, en lugar seguro.
```

## 3. Crear el namespace y el imagePullSecret de GHCR

```bash
kubectl create namespace landslide

# PAT de GitHub con scope read:packages (no va a git):
kubectl -n landslide create secret docker-registry ghcr \
  --docker-server=ghcr.io \
  --docker-username=<TU_USUARIO> \
  --docker-password=<PAT_read:packages>
```

## 4. Sellar los secrets de aplicación

```bash
cd k8s/bootstrap
cp secrets.example.env secrets.env     # secrets.env está gitignored
# rellenar secrets.env con los valores REALES
./seal-secrets.sh secrets.env          # genera ../overlays/prod/sealed-secrets/*.yaml
```

Los `SealedSecret` cifrados resultantes **sí** se commitean.

## 5. Desplegar

```bash
kubectl apply -k k8s/overlays/prod
```

## 6. Verificar

```bash
kubectl -n landslide get pods,svc,ingressroute
kubectl -n landslide rollout status deploy/data-management
# Swagger vía Traefik (IP del VPS):
curl -s http://<IP-VPS>/api/v1/data/docs/ -o /dev/null -w '%{http_code}\n'
# Ingesta TCP de sensores (Service LoadBalancer):
kubectl -n landslide get svc data-receiving-tcp   # EXTERNAL-IP / puerto 5000
```

## Notas

- **Discovery:** lo da el DNS de los Services K8s; Consul queda deshabilitado
  (`CONSUL_ENABLED=false`, o host inexistente para las apps sin flag).
- **Load balancing:** lo hace cada Service (ClusterIP) sobre sus réplicas; el
  Ingress (Traefik) rutea la entrada por path.
- **Migraciones DB:** las apps Go corren goose al arranque; no hay Job aparte.
- **TLS:** HTTP plano (entrypoint `web`). Para HTTPS: añadir cert-manager +
  Let's Encrypt y un entrypoint `websecure` (TODO).
