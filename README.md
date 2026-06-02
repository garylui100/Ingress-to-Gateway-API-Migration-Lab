# Ingress to Gateway API Migration Lab (NGINX -> AGC with WAF)

This hands-on lab walks you through a pragmatic migration path from Kubernetes Ingress (NGINX Ingress Controller) to Kubernetes Gateway API on Azure Application Gateway for Containers (AGC), then adds Azure Web Application Firewall (WAF) protection. The lab is designed for platform and application teams who want to modernize traffic management without a risky big-bang cutover.

The flow is inspired by the Microsoft Tech Community article, [from ingress to gateway api](https://techcommunity.microsoft.com/blog/azurearchitectureblog/from-ingress-to-gateway-api-a-pragmatic-path-forward-and-why-it-matters-now/4489779). That article highlights why this migration matters now: the ecosystem is converging on Gateway API, role separation is clearer (platform-managed Gateway, app-owned Routes), and a safe incremental rollout is preferred over rip-and-replace.

## What You Will Learn

- Build an AKS test environment with NGINX Ingress and sample apps.
- Convert existing Ingress resources to Gateway API using the AGC Migration Utility.
- Deploy Application Gateway for Containers using the managed ALB Controller approach.
- Validate traffic parity between old and new paths.
- Attach Azure WAF policy and verify malicious traffic blocking.

## Why This Lab Matters

- Gateway API is the forward-looking Kubernetes traffic model and avoids annotation-heavy Ingress sprawl.
- Ingress migration should be incremental and testable, not disruptive.
- AGC provides an Azure-native gateway path with managed operations, integrated security options, and native Gateway API support.

## Lab Topology

1. Deploy AKS + NGINX Ingress + two sample services.
2. Validate Ingress-based traffic.
3. Generate Gateway API resources from existing Ingress.
4. Deploy AGC managed by ALB Controller in parallel.
5. Apply migrated resources and validate routing.
6. Add WAF policy and validate blocked attack traffic.

## Prerequisites

- Azure subscription with permissions to create resource groups, AKS, managed identity, RBAC assignments, and networking resources.
- Azure Cloud Shell (Bash) or a Bash environment with:
	- `az`
	- `kubectl`
	- `helm`
	- `git`
	- `go`
- Basic AKS and Kubernetes familiarity.

## Important Notes

- Non-YAML commands are single-line and copy/paste ready.
- YAML creation steps are intentionally shown in multiline format for readability.
- This lab uses the **managed ALB Controller** deployment model.
- Migration tool output is a starting point: always review generated YAML before production cutover.
- Keep NGINX path active until AGC parity is fully validated.

## Companion Files

- [run-lab.sh](run-lab.sh): End-to-end lab automation script with step-by-step console output.
- [LAB-WORKBOOK.md](LAB-WORKBOOK.md): Instructor and student checklist with validation checkpoints.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): Common failure patterns and targeted fixes.

To run the automated script:

```bash
chmod +x run-lab.sh
SUBSCRIPTION_ID="<your-subscription-id>" ./run-lab.sh
```

## Section 1 - Environment Setup

### 1. Define lab variables
Set all environment variables used throughout the lab.

```bash
export SUBSCRIPTION_ID=""
export RESOURCE_GROUP="nginx-agc-migration"
export AKS_NAME="aks-nginx-agc-lab"
export LOCATION="northeurope"
export VM_SIZE="Standard_DS3_v2"
export IDENTITY_RESOURCE_NAME="azure-alb-identity"
export FEDERATED_IDENTITY_NAME="azure-alb-identity"
export CONTROLLER_NAMESPACE="azure-alb-system"
export HELM_NAMESPACE="azure-alb-system"
export NAMESPACE="ingress-basic"
export GATEWAY_NAME="alb-gateway"
export AGC_OUTPUT_DIR="../agc-output"
```

### 2. Sign in and target the subscription
Authenticate and select the target Azure subscription.

```bash
az login
az account set --subscription "$SUBSCRIPTION_ID"
```

### 3. Register required resource providers
Enable all Azure resource namespaces needed by AKS and AGC.

```bash
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.NetworkFunction
az provider register --namespace Microsoft.ServiceNetworking
```

### 4. Install required Azure CLI extensions
Install AGC/ALB and AKS preview command support.

```bash
az extension add --name alb
az extension add --name aks-preview
```

## Section 2 - Build AKS + NGINX Baseline

### 1. Create resource group
Create a resource group for all lab assets.

```bash
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
```

### 2. Create AKS with OIDC + Workload Identity
Provision AKS with features required by ALB Controller identity federation.

```bash
az aks create --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --location "$LOCATION" --node-vm-size "$VM_SIZE" --network-plugin azure --enable-oidc-issuer --enable-workload-identity --generate-ssh-keys
```

### 3. Connect kubectl to AKS
Download kubeconfig and verify nodes.

```bash
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME"
kubectl get nodes
```

### 4. Add and refresh Helm repo for NGINX ingress
Prepare Helm source for controller installation.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

### 5. Install NGINX Ingress Controller
Deploy ingress-nginx into the lab namespace and set Azure LB health probe.

```bash
helm install ingress-nginx ingress-nginx/ingress-nginx --create-namespace --namespace "$NAMESPACE" --set controller.service.annotations."service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path"=/healthz --set controller.service.externalTrafficPolicy=Local
```

### 6. Deploy sample app 1 (deployment + service)
Create and apply YAML for the first sample service.

```bash
cat <<EOF > aks-helloworld-one.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aks-helloworld-one
spec:
  replicas: 1
  selector:
    matchLabels:
      app: aks-helloworld-one
  template:
    metadata:
      labels:
        app: aks-helloworld-one
    spec:
      containers:
      - name: aks-helloworld-one
        image: mcr.microsoft.com/azuredocs/aks-helloworld:v1
        ports:
        - containerPort: 80
        env:
        - name: TITLE
          value: "Welcome to Azure Kubernetes Service (AKS App1)"
---
apiVersion: v1
kind: Service
metadata:
  name: aks-helloworld-one
spec:
  type: ClusterIP
  ports:
  - port: 80
  selector:
    app: aks-helloworld-one
EOF

kubectl apply -f aks-helloworld-one.yaml -n "$NAMESPACE"
```

### 7. Deploy sample app 2 (deployment + service)
Create and apply YAML for the second sample service.

```bash
cat <<EOF > aks-helloworld-two.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aks-helloworld-two
spec:
  replicas: 1
  selector:
    matchLabels:
      app: aks-helloworld-two
  template:
    metadata:
      labels:
        app: aks-helloworld-two
    spec:
      containers:
      - name: aks-helloworld-two
        image: mcr.microsoft.com/azuredocs/aks-helloworld:v1
        ports:
        - containerPort: 80
        env:
        - name: TITLE
          value: "AKS Ingress Demo (AKS App2)"
---
apiVersion: v1
kind: Service
metadata:
  name: aks-helloworld-two
spec:
  type: ClusterIP
  ports:
  - port: 80
  selector:
    app: aks-helloworld-two
EOF

kubectl apply -f aks-helloworld-two.yaml -n "$NAMESPACE"
```

### 8. Create NGINX Ingress resources
Create both path-based ingress objects including rewrite behavior.

```bash
cat <<EOF > hello-world-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-world-ingress
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /hello-world-one
        pathType: Prefix
        backend:
          service:
            name: aks-helloworld-one
            port:
              number: 80
      - path: /hello-world-two
        pathType: Prefix
        backend:
          service:
            name: aks-helloworld-two
            port:
              number: 80
      - path: /
        pathType: Prefix
        backend:
          service:
            name: aks-helloworld-one
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-world-ingress-static
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/rewrite-target: /static
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /static
        pathType: Prefix
        backend:
          service:
            name: aks-helloworld-one
            port:
              number: 80
EOF

kubectl apply -f hello-world-ingress.yaml -n "$NAMESPACE"
kubectl get ingress -n "$NAMESPACE"
```

### 9. Validate baseline NGINX traffic
Get ingress IP and confirm both paths return expected content.

```bash
export INGRESS_IP="$(kubectl get svc -n "$NAMESPACE" -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')"
echo "$INGRESS_IP"
curl "http://$INGRESS_IP/hello-world-one"
curl "http://$INGRESS_IP/hello-world-two"
```

## Section 3 - Generate Gateway API Resources with Migration Utility

### 1. Clone and build migration utility
Get the open-source migration tool and compile it.

```bash
git clone https://github.com/Azure/Application-Gateway-for-Containers-Migration-Utility.git
cd Application-Gateway-for-Containers-Migration-Utility
go build -o agc-migration ./cmd
```

### 2. Prepare AGC subnet values
Find node resource group and create delegated subnet for AGC.

```bash
export NODE_RG="$(az aks show --name "$AKS_NAME" --resource-group "$RESOURCE_GROUP" --query nodeResourceGroup -o tsv)"
export VNET_NAME="$(az network vnet list -g "$NODE_RG" --query '[0].name' -o tsv)"
export AGC_SUBNET_NAME="agc-subnet"
az network vnet subnet create --resource-group "$NODE_RG" --vnet-name "$VNET_NAME" --name "$AGC_SUBNET_NAME" --address-prefixes 10.226.0.0/24
az network vnet subnet update --resource-group "$NODE_RG" --vnet-name "$VNET_NAME" --name "$AGC_SUBNET_NAME" --delegations Microsoft.ServiceNetworking/trafficControllers
export AGC_SUBNET_ID="$(az network vnet subnet show --resource-group "$NODE_RG" --vnet-name "$VNET_NAME" --name "$AGC_SUBNET_NAME" --query id -o tsv)"
echo "$AGC_SUBNET_ID"
```

### 3. Run conversion from Ingress to Gateway API
Generate AGC-compatible Gateway API resources from live cluster Ingress objects.

```bash
./agc-migration cluster --provider nginx --ingress-class nginx --managed-subnet-id "$AGC_SUBNET_ID" --output-dir "$AGC_OUTPUT_DIR"
```

### 4. Review generated output
Confirm generated manifests contain expected gateway class, ALB metadata, and backend references.

```bash
grep -R "gatewayClassName\|alb.networking.azure.io" "$AGC_OUTPUT_DIR"/*.yaml
cat "$AGC_OUTPUT_DIR"/gateway-ingress-basic-alb-gateway.yaml
cat "$AGC_OUTPUT_DIR"/httproute-ingress-basic-hello-world-ingress-*
```

## Section 4 - Deploy AGC (Managed by ALB Controller)

### 1. Create managed identity for ALB Controller
Create and capture identity values used by workload identity.

```bash
az identity create --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_RESOURCE_NAME"
export PRINCIPAL_ID="$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY_RESOURCE_NAME" --query principalId -o tsv)"
export CLIENT_ID="$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY_RESOURCE_NAME" --query clientId -o tsv)"
export NODE_RG_ID="$(az group show --name "$NODE_RG" --query id -o tsv)"
echo "$PRINCIPAL_ID"
echo "$CLIENT_ID"
```

### 2. Create federated identity credential
Bind AKS service account identity to Azure managed identity.

```bash
export AKS_OIDC_ISSUER="$(az aks show -n "$AKS_NAME" -g "$RESOURCE_GROUP" --query 'oidcIssuerProfile.issuerUrl' -o tsv)"
az identity federated-credential create --name "$FEDERATED_IDENTITY_NAME" --identity-name "$IDENTITY_RESOURCE_NAME" --resource-group "$RESOURCE_GROUP" --issuer "$AKS_OIDC_ISSUER" --subject "system:serviceaccount:$CONTROLLER_NAMESPACE:alb-controller-sa"
```

### 3. Assign required roles to ALB managed identity
Grant permissions for AGC resource creation and networking operations.

```bash
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal --scope "$NODE_RG_ID" --role "Contributor"
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal --scope "$AGC_SUBNET_ID" --role "4d97b98b-1d4f-4787-a291-c67834d212e7"
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal --scope "$NODE_RG_ID" --role "fbc52c3f-28ad-4303-a892-8a056630b8f1"
```

### 4. Install ALB Controller
Deploy ALB Controller Helm chart into the controller namespace.

```bash
helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller --namespace "$HELM_NAMESPACE" --create-namespace --set albController.namespace="$CONTROLLER_NAMESPACE" --set albController.podIdentity.clientID="$CLIENT_ID"
```

### 5. Validate controller and gateway class
Confirm ALB controller pods and gateway class are available.

```bash
kubectl get pods -n "$CONTROLLER_NAMESPACE"
kubectl get gatewayclass
```

### 6. Apply generated Gateway API resources
Deploy converted manifests to Kubernetes.

```bash
kubectl apply -f "$AGC_OUTPUT_DIR"/
```

### 7. Validate AGC provisioning
Check AGC resources and watch gateway readiness.

```bash
kubectl get applicationloadbalancer -n "$NAMESPACE"
kubectl get gateway -n "$NAMESPACE"
```

### 8. Optional troubleshooting commands
Inspect gateway resources and restart controller after RBAC/config changes.

```bash
kubectl describe applicationloadbalancer alb -n "$NAMESPACE"
kubectl describe gateway "$GATEWAY_NAME" -n "$NAMESPACE"
kubectl rollout restart deployment alb-controller -n "$CONTROLLER_NAMESPACE"
```

### 9. Validate AGC traffic
Get AGC gateway FQDN and verify application routes.

```bash
export AGC_FQDN="$(kubectl get gateway "$GATEWAY_NAME" -n "$NAMESPACE" -o jsonpath='{.status.addresses[0].value}')"
echo "$AGC_FQDN"
curl -v "http://$AGC_FQDN/hello-world-one"
curl -v "http://$AGC_FQDN/hello-world-two"
```

## Section 5 - Enable and Test WAF

### 1. Create WAF policy in Prevention mode
Provision Azure WAF policy and enable blocking behavior.

```bash
export WAF_POLICY_NAME="agc-waf-policy"
az network application-gateway waf-policy create --name "$WAF_POLICY_NAME" --resource-group "$RESOURCE_GROUP" --location "$LOCATION"
az network application-gateway waf-policy policy-setting update --policy-name "$WAF_POLICY_NAME" --resource-group "$RESOURCE_GROUP" --mode Prevention --state Enabled
```

### 2. Attach WAF policy to Gateway
Create Kubernetes WAF binding resource that points to the Azure WAF policy ID.

```bash
WAF_ID="$(az network application-gateway waf-policy show --name "$WAF_POLICY_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)"

cat <<EOF | kubectl apply -f -
apiVersion: alb.networking.azure.io/v1
kind: WebApplicationFirewallPolicy
metadata:
  name: waf-binding
  namespace: $NAMESPACE
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: $GATEWAY_NAME
    namespace: $NAMESPACE
  webApplicationFirewall:
    id: $WAF_ID
EOF
```

### 3. Validate WAF blocking and clean traffic
Test SQL injection-style request (expected block) and normal request (expected success).

```bash
curl -v "http://$AGC_FQDN/hello-world-one/?id=1' OR '1'='1"
curl -v "http://$AGC_FQDN/hello-world-two/?id=1' OR '1'='1"
curl -v "http://$AGC_FQDN/hello-world-one"
curl -v "http://$AGC_FQDN/hello-world-two"
```

## Migration Guidance (Recommended Practice)

Use this rollout pattern for production migrations:

1. Inventory existing Ingress patterns (hosts, paths, rewrites, TLS, annotations).
2. Stand up AGC in parallel with existing ingress controller.
3. Convert a low-risk service first and validate route/security parity.
4. Migrate iteratively service-by-service with observability in place.
5. Cut over only after SLO and security checks pass; keep rollback path until stable.

## Validation Checklist

- Routing parity validated for all critical hosts and paths.
- Rewrite behavior validated for app frameworks and static content routes.
- TLS and certificate ownership model documented (platform vs app responsibilities).
- WAF policy baseline applied and tested in non-production first.
- Monitoring and alerting configured for gateway health, latency, and 4xx/5xx trends.

## Cleanup (Optional)

Delete all resources created by this lab.

```bash
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
```

## References

- [From Ingress to Gateway API: A pragmatic path forward (and why it matters now)](https://techcommunity.microsoft.com/blog/azurearchitectureblog/from-ingress-to-gateway-api-a-pragmatic-path-forward-and-why-it-matters-now/4489779)
- [Application Gateway for Containers Migration Utility](https://aka.ms/agc/migrationutility)
- [Application Gateway for Containers documentation](https://aka.ms/agc)
