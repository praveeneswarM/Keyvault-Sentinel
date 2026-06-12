# Sentinel AKS Manifests

These are plain Kubernetes manifests for a simple AKS deployment. Helm is not used.

This folder assumes:

- one AKS cluster
- Docker Hub images
- one user-assigned managed identity for the Sentinel pods
- Key Vault Secrets Store CSI Driver
- one public AKS `LoadBalancer` Service named `sentinel-gateway`

## Replace Placeholders

Before applying anything, replace every placeholder:

```bash
rg -n "REPLACE_ME_" kubernetes
```

Common values:

```text
REPLACE_ME_DOCKERHUB_USERNAME
REPLACE_ME_IMAGE_TAG
REPLACE_ME_SENTINEL_PUBLIC_IP
keyvaultdemo-1
7a0d7710-a801-403c-96d0-c08e7e259f25
6206e18c-53ff-46fb-856b-d8435455825a
REPLACE_ME_IDENTITY_APP_CLIENT_ID
REPLACE_ME_POSTGRES_PRIVATE_IP_OR_CIDR
```

`REPLACE_ME_SENTINEL_PUBLIC_IP` is known only after Azure creates the
`sentinel-gateway` LoadBalancer. You can deploy once with placeholders, get the IP,
then update `keyvault-values.yaml`, rerun the seeding script, rebuild the web image
with the real API URL, and restart the web/identity pods.

## Images

Push these images to Docker Hub:

```text
<dockerhub>/sentinel-web:<tag>
<dockerhub>/sentinel-identity-service:<tag>
<dockerhub>/sentinel-inventory-service:<tag>
<dockerhub>/sentinel-relationship-service:<tag>
<dockerhub>/sentinel-change-intelligence-service:<tag>
<dockerhub>/sentinel-operations-service:<tag>
<dockerhub>/sentinel-audit-service:<tag>
```

The migration image is not deployed to AKS now. Build it on the Docker VM and run it
once to create/update PostgreSQL tables:

```text
<dockerhub>/sentinel-migration:<tag>
```

Build the web image with the public API URL baked in:

```text
NEXT_PUBLIC_API_BASE_URL=http://REPLACE_ME_SENTINEL_PUBLIC_IP/api/v1
```

`NEXT_PUBLIC_*` values are compiled into Next.js. Changing Key Vault later does not
change the already-built web image.

## Apply Order

Seed Key Vault before applying the workloads. Keep real values in the gitignored
`keyvault-values.yaml` file:

```bash
cp kubernetes/keyvault-values.example.yaml kubernetes/keyvault-values.yaml
chmod +x scripts/set-sentinel-keyvault-values.sh
./scripts/set-sentinel-keyvault-values.sh \
  --values-file kubernetes/keyvault-values.yaml
```

The script automatically installs `jq` and Mike Farah `yq` v4 into
`~/.local/bin`. If Azure CLI is missing, it installs it on Ubuntu/Debian using
Microsoft's installer; that step requires `sudo`. When no Azure CLI session exists,
the script attempts `az login --identity` for an Azure VM managed identity. Otherwise,
authenticate interactively with `az login`.

Preview the upload without changing Azure:

```bash
./scripts/set-sentinel-keyvault-values.sh \
  --values-file kubernetes/keyvault-values.yaml \
  --dry-run
```

Application settings and credentials are both stored as Key Vault secrets because
the Azure CSI provider exposes Key Vault values through the Kubernetes Secret API.
The `config` and `secrets` sections in the values file are tagged separately in Key
Vault for visibility.

The Key Vault CSI driver does not create Kubernetes ConfigMaps. The two
`runtime-config` SecretProviderClasses in `03-secret-provider-classes.yaml` synchronize
the config values into a Kubernetes Secret named `sentinel-runtime-config` in each
namespace. Workloads inject those values with:

```yaml
envFrom:
  - secretRef:
      name: sentinel-runtime-config
```

The `runtime-config` CSI volume mounted at `/mnt/runtime-config` causes the provider
to fetch and synchronize those values. Therefore there is no `configMapRef`, and the
old `01-config.yaml` ConfigMap is no longer needed.

The workload identity client ID, Key Vault name, and provider tenant ID in
`02-service-accounts.yaml` and `03-secret-provider-classes.yaml` are bootstrap
settings. They must be present before the CSI driver can authenticate to Key Vault,
so they cannot be loaded from that same vault. Replace their `REPLACE_ME_*`
placeholders during deployment. Application-facing tenant/client IDs are stored in
Key Vault through `keyvault-values.yaml`.

```bash
kubectl apply -f kubernetes/00-namespaces.yaml
kubectl apply -f kubernetes/02-service-accounts.yaml
kubectl apply -f kubernetes/03-secret-provider-classes.yaml
kubectl apply -f kubernetes/04-resource-governance.yaml
kubectl apply -f kubernetes/10-web.yaml
kubectl apply -f kubernetes/11-identity-service.yaml
kubectl apply -f kubernetes/12-inventory-service.yaml
kubectl apply -f kubernetes/13-relationship-service.yaml
kubectl apply -f kubernetes/14-change-intelligence-service.yaml
kubectl apply -f kubernetes/15-operations-service.yaml
kubectl apply -f kubernetes/16-audit-service.yaml
kubectl apply -f kubernetes/20-workers.yaml
kubectl apply -f kubernetes/40-network-policies.yaml
kubectl apply -f kubernetes/50-gateway-loadbalancer.yaml
```

Get the public IP:

```bash
kubectl get svc sentinel-gateway -n sentinel-app
```

## Current Public IP Caveat

The checked-in gateway exposes HTTP on port `80`. This is fine for a first AKS smoke
test, but Microsoft login may require HTTPS for a public redirect URI. If Entra blocks
the raw `http://<public-ip>/auth/callback` redirect, keep the same manifests and add
DNS/TLS later.

For DNS/TLS later, change:

```text
SENTINEL_FRONTEND_URL=https://your-domain
SENTINEL_MICROSOFT_REDIRECT_URI=https://your-domain/auth/callback
SENTINEL_SESSION_COOKIE_SECURE=true
NEXT_PUBLIC_API_BASE_URL=https://your-domain/api/v1
```

## Secrets

Key Vault is the source of truth. The CSI provider syncs Key Vault values into
workload-specific Kubernetes Secrets because the current services read environment
variables. Do not commit real secret values to this repository.

After changing a Key Vault value, restart the affected deployments so environment
variables are recreated:

```bash
kubectl rollout restart deployment -n sentinel-app
kubectl rollout restart deployment -n sentinel-workers
```
