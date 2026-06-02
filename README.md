# Ingress-to-Gateway-API-Migration-Lab

This GitHub lab demonstrates a practical migration path from Kubernetes Ingress (NGINX) to Gateway API on Azure, using the Azure Application Gateway for Containers (AGC) migration utility.

> You can follow and copy/paste the commands in **Azure Cloud Shell (Bash)** or **PowerShell**.

## Section 1 - Initial Setup

### 1.1 Prerequisites
- Azure subscription with permission to create resource groups, AKS, and networking resources
- Azure CLI (`az`) installed and logged in
- `kubectl` installed
- `helm` installed

### 1.2 Set environment variables (Bash / Cloud Shell)
```bash
export SUBSCRIPTION_ID="<your-subscription-id>"
export LOCATION="eastus"
export RG_NAME="rg-ingress-gateway-lab"
export AKS_NAME="aks-ingress-gateway-lab"
export NODE_COUNT="2"
export APP_NS="lab-app"

az account set --subscription "$SUBSCRIPTION_ID"
```

### 1.3 Set environment variables (PowerShell)
```powershell
$SUBSCRIPTION_ID = "<your-subscription-id>"
$LOCATION = "eastus"
$RG_NAME = "rg-ingress-gateway-lab"
$AKS_NAME = "aks-ingress-gateway-lab"
$NODE_COUNT = "2"
$APP_NS = "lab-app"

az account set --subscription $SUBSCRIPTION_ID
```

### 1.4 Create resource group
```bash
az group create --name "$RG_NAME" --location "$LOCATION"
```

```powershell
az group create --name $RG_NAME --location $LOCATION
```

---

## Section 2 - Create AKS apps and NGINX Ingress Controller

### 2.1 Create AKS cluster
```bash
az aks create \
  --resource-group "$RG_NAME" \
  --name "$AKS_NAME" \
  --node-count "$NODE_COUNT" \
  --generate-ssh-keys

az aks get-credentials --resource-group "$RG_NAME" --name "$AKS_NAME" --overwrite-existing
```

```powershell
az aks create `
  --resource-group $RG_NAME `
  --name $AKS_NAME `
  --node-count $NODE_COUNT `
  --generate-ssh-keys

az aks get-credentials --resource-group $RG_NAME --name $AKS_NAME --overwrite-existing
```

### 2.2 Install NGINX Ingress Controller
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace
```

```powershell
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx `
  --namespace ingress-nginx `
  --create-namespace
```

### 2.3 Deploy sample app and Ingress
```bash
kubectl create namespace "$APP_NS"
kubectl -n "$APP_NS" create deployment demo --image=mcr.microsoft.com/azuredocs/aks-helloworld:v1
kubectl -n "$APP_NS" expose deployment demo --port 80 --target-port 80

cat <<YAML | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-ingress
  namespace: $APP_NS
spec:
  ingressClassName: nginx
  rules:
  - host: demo.contoso.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: demo
            port:
              number: 80
YAML
```

```powershell
kubectl create namespace $APP_NS
kubectl -n $APP_NS create deployment demo --image=mcr.microsoft.com/azuredocs/aks-helloworld:v1
kubectl -n $APP_NS expose deployment demo --port 80 --target-port 80

@"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-ingress
  namespace: $APP_NS
spec:
  ingressClassName: nginx
  rules:
  - host: demo.contoso.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: demo
            port:
              number: 80
"@ | kubectl apply -f -
```

---

## Section 3 - Migration Utility Setup

### 3.1 Install Gateway API CRDs (if not already installed)
```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
```

```powershell
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
```

### 3.2 Export existing ingress configuration
```bash
kubectl get ingress -A -o yaml > ingress-export.yaml
```

```powershell
kubectl get ingress -A -o yaml | Out-File -Encoding utf8 ingress-export.yaml
```

### 3.3 Run migration utility (example)
> Install and follow the official AGC migration utility instructions for your environment. Use the generated Gateway manifest output path in the next step.

```bash
# Example command pattern
# agc-migrate ingress --input ingress-export.yaml --output gateway-output.yaml
```

```powershell
# Example command pattern
# agc-migrate ingress --input ingress-export.yaml --output gateway-output.yaml
```

### 3.4 Review generated Gateway API resources
> If your migration tool uses a different output file name/path, replace `gateway-output.yaml` below.

```bash
cat gateway-output.yaml
```

```powershell
Get-Content .\gateway-output.yaml
```

---

## Section 4 - Application Gateway for Container (with managed ALB Controller) Setup

### 4.1 Register required Azure providers
```bash
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.ServiceNetworking
az provider register --namespace Microsoft.Network
```

```powershell
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.ServiceNetworking
az provider register --namespace Microsoft.Network
```

### 4.2 Enable AGC/ALB-related AKS features (example)
> These AKS feature flags are typically required for managed ALB/AGC setup. Feature names can vary by region and release stage. Confirm latest Azure documentation before running: https://learn.microsoft.com/azure/application-gateway/for-containers/

```bash
# Example commands (verify before use)
# az aks update -g "$RG_NAME" -n "$AKS_NAME" --enable-oidc-issuer --enable-workload-identity
```

```powershell
# Example commands (verify before use)
# az aks update -g $RG_NAME -n $AKS_NAME --enable-oidc-issuer --enable-workload-identity
```

### 4.3 Install/enable managed ALB Controller (example)
```bash
# Follow official AGC + ALB Controller installation guide:
# https://learn.microsoft.com/azure/application-gateway/for-containers/
# kubectl get pods -n azure-alb-system
```

```powershell
# Follow official AGC + ALB Controller installation guide:
# https://learn.microsoft.com/azure/application-gateway/for-containers/
# kubectl get pods -n azure-alb-system
```

### 4.4 Apply migrated Gateway API manifests
```bash
kubectl apply -f gateway-output.yaml
kubectl get gateway,httproute -A
```

```powershell
kubectl apply -f .\gateway-output.yaml
kubectl get gateway,httproute -A
```

---

## Section 5 - Apply Web Application Firewall to the AGC

### 5.1 Install AGC CLI extension and create or identify WAF policy
```bash
az extension add --name application-gateway-container

export WAF_POLICY_NAME="waf-agc-lab-policy"
az network application-gateway waf-policy create \
  --resource-group "$RG_NAME" \
  --name "$WAF_POLICY_NAME" \
  --location "$LOCATION"
```

```powershell
az extension add --name application-gateway-container

$WAF_POLICY_NAME = "waf-agc-lab-policy"
az network application-gateway waf-policy create `
  --resource-group $RG_NAME `
  --name $WAF_POLICY_NAME `
  --location $LOCATION
```

### 5.2 Enable prevention mode and capture WAF policy ID
```bash
az network application-gateway waf-policy policy-setting update \
  --resource-group "$RG_NAME" \
  --policy-name "$WAF_POLICY_NAME" \
  --mode Prevention

WAF_POLICY_ID=$(az network application-gateway waf-policy show \
  --resource-group "$RG_NAME" \
  --name "$WAF_POLICY_NAME" \
  --query id -o tsv)
```

```powershell
az network application-gateway waf-policy policy-setting update `
  --resource-group $RG_NAME `
  --policy-name $WAF_POLICY_NAME `
  --mode Prevention

$WAF_POLICY_ID = az network application-gateway waf-policy show `
  --resource-group $RG_NAME `
  --name $WAF_POLICY_NAME `
  --query id -o tsv
```

### 5.3 Associate WAF policy to AGC listener/routing configuration
```bash
# Replace ALB_NAME with the value in the "Name" column from this output
az network alb list --resource-group "$RG_NAME" -o table
export ALB_NAME="<your-alb-name>"
az network alb waf update \
  --resource-group "$RG_NAME" \
  --name "$ALB_NAME" \
  --waf-policy "$WAF_POLICY_ID"
```

```powershell
# Replace ALB_NAME with the value in the "Name" column from this output
az network alb list --resource-group $RG_NAME -o table
$ALB_NAME = "<your-alb-name>"
az network alb waf update `
  --resource-group $RG_NAME `
  --name $ALB_NAME `
  --waf-policy $WAF_POLICY_ID
```

---

## Validation

```bash
kubectl get ingress -A
kubectl get gateway -A
kubectl get httproute -A
```

```powershell
kubectl get ingress -A
kubectl get gateway -A
kubectl get httproute -A
```

If HTTP traffic is successfully served through Gateway API/AGC and protected by the WAF policy, the migration lab is complete.
