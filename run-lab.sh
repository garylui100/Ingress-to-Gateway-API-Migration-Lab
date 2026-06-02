#!/usr/bin/env bash
set -euo pipefail

# Ingress -> Gateway API migration lab automation (NGINX -> AGC with WAF)
# Usage:
#   1) Set SUBSCRIPTION_ID below or export it before running.
#   2) chmod +x run-lab.sh
#   3) ./run-lab.sh

export SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
export RESOURCE_GROUP="${RESOURCE_GROUP:-nginx-agc-migration}"
export AKS_NAME="${AKS_NAME:-aks-nginx-agc-lab}"
export LOCATION="${LOCATION:-northeurope}"
export VM_SIZE="${VM_SIZE:-Standard_DS3_v2}"
export IDENTITY_RESOURCE_NAME="${IDENTITY_RESOURCE_NAME:-azure-alb-identity}"
export FEDERATED_IDENTITY_NAME="${FEDERATED_IDENTITY_NAME:-azure-alb-identity}"
export CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-azure-alb-system}"
export HELM_NAMESPACE="${HELM_NAMESPACE:-azure-alb-system}"
export NAMESPACE="${NAMESPACE:-ingress-basic}"
export GATEWAY_NAME="${GATEWAY_NAME:-alb-gateway}"
export AGC_OUTPUT_DIR="${AGC_OUTPUT_DIR:-../agc-output}"

if [[ -z "${SUBSCRIPTION_ID}" ]]; then
  echo "ERROR: SUBSCRIPTION_ID is empty. Export it first: export SUBSCRIPTION_ID=<your-subscription-id>"
  exit 1
fi

run() {
  local desc="$1"
  local cmd="$2"
  echo
  echo "==> ${desc}"
  echo "CMD: ${cmd}"
  eval "${cmd}"
}

# Section 1: Setup
run "Authenticate to Azure" "az login"
run "Select subscription" "az account set --subscription \"$SUBSCRIPTION_ID\""
run "Register Microsoft.ContainerService" "az provider register --namespace Microsoft.ContainerService"
run "Register Microsoft.Network" "az provider register --namespace Microsoft.Network"
run "Register Microsoft.NetworkFunction" "az provider register --namespace Microsoft.NetworkFunction"
run "Register Microsoft.ServiceNetworking" "az provider register --namespace Microsoft.ServiceNetworking"
run "Install ALB extension" "az extension add --name alb"
run "Install AKS preview extension" "az extension add --name aks-preview"

# Section 2: AKS baseline with NGINX ingress
run "Create resource group" "az group create --name \"$RESOURCE_GROUP\" --location \"$LOCATION\""
run "Create AKS with OIDC + workload identity" "az aks create --resource-group \"$RESOURCE_GROUP\" --name \"$AKS_NAME\" --location \"$LOCATION\" --node-vm-size \"$VM_SIZE\" --network-plugin azure --enable-oidc-issuer --enable-workload-identity --generate-ssh-keys"
run "Get AKS credentials" "az aks get-credentials --resource-group \"$RESOURCE_GROUP\" --name \"$AKS_NAME\""
run "Verify AKS nodes" "kubectl get nodes"
run "Add ingress-nginx Helm repo" "helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx"
run "Update Helm repos" "helm repo update"
run "Install ingress-nginx" "helm install ingress-nginx ingress-nginx/ingress-nginx --create-namespace --namespace \"$NAMESPACE\" --set controller.service.annotations.\"service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path\"=/healthz --set controller.service.externalTrafficPolicy=Local"

echo
echo "==> Create app1 manifest and apply"
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

echo
echo "==> Create app2 manifest and apply"
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

echo
echo "==> Create ingress manifests and apply"
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

run "Resolve ingress public IP" "export INGRESS_IP=\"$(kubectl get svc -n \"$NAMESPACE\" -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')\"; echo \"$INGRESS_IP\""
run "Validate baseline route one" "curl \"http://$INGRESS_IP/hello-world-one\""
run "Validate baseline route two" "curl \"http://$INGRESS_IP/hello-world-two\""

# Section 3: Migration utility
run "Clone migration utility" "git clone https://github.com/Azure/Application-Gateway-for-Containers-Migration-Utility.git"
run "Build migration utility" "cd Application-Gateway-for-Containers-Migration-Utility; go build -o agc-migration ./cmd"
run "Resolve AKS node RG + VNet" "export NODE_RG=\"$(az aks show --name \"$AKS_NAME\" --resource-group \"$RESOURCE_GROUP\" --query nodeResourceGroup -o tsv)\"; export VNET_NAME=\"$(az network vnet list -g \"$NODE_RG\" --query '[0].name' -o tsv)\"; echo \"$NODE_RG\"; echo \"$VNET_NAME\""
run "Create delegated AGC subnet" "export AGC_SUBNET_NAME=agc-subnet; az network vnet subnet create --resource-group \"$NODE_RG\" --vnet-name \"$VNET_NAME\" --name \"$AGC_SUBNET_NAME\" --address-prefixes 10.226.0.0/24; az network vnet subnet update --resource-group \"$NODE_RG\" --vnet-name \"$VNET_NAME\" --name \"$AGC_SUBNET_NAME\" --delegations Microsoft.ServiceNetworking/trafficControllers"
run "Get AGC subnet resource ID" "export AGC_SUBNET_ID=\"$(az network vnet subnet show --resource-group \"$NODE_RG\" --vnet-name \"$VNET_NAME\" --name \"$AGC_SUBNET_NAME\" --query id -o tsv)\"; echo \"$AGC_SUBNET_ID\""
run "Generate Gateway API output" "cd Application-Gateway-for-Containers-Migration-Utility; ./agc-migration cluster --provider nginx --ingress-class nginx --managed-subnet-id \"$AGC_SUBNET_ID\" --output-dir \"$AGC_OUTPUT_DIR\""
run "Inspect generated gateway + routes" "grep -R 'gatewayClassName\\|alb.networking.azure.io' $AGC_OUTPUT_DIR/*.yaml"

# Section 4: AGC managed by ALB controller
run "Create managed identity" "az identity create --resource-group \"$RESOURCE_GROUP\" --name \"$IDENTITY_RESOURCE_NAME\""
run "Capture managed identity values" "export PRINCIPAL_ID=\"$(az identity show -g \"$RESOURCE_GROUP\" -n \"$IDENTITY_RESOURCE_NAME\" --query principalId -o tsv)\"; export CLIENT_ID=\"$(az identity show -g \"$RESOURCE_GROUP\" -n \"$IDENTITY_RESOURCE_NAME\" --query clientId -o tsv)\"; export NODE_RG_ID=\"$(az group show --name \"$NODE_RG\" --query id -o tsv)\"; echo \"$PRINCIPAL_ID\"; echo \"$CLIENT_ID\""
run "Get AKS OIDC issuer" "export AKS_OIDC_ISSUER=\"$(az aks show -n \"$AKS_NAME\" -g \"$RESOURCE_GROUP\" --query 'oidcIssuerProfile.issuerUrl' -o tsv)\"; echo \"$AKS_OIDC_ISSUER\""
run "Create federated credential" "az identity federated-credential create --name \"$FEDERATED_IDENTITY_NAME\" --identity-name \"$IDENTITY_RESOURCE_NAME\" --resource-group \"$RESOURCE_GROUP\" --issuer \"$AKS_OIDC_ISSUER\" --subject \"system:serviceaccount:$CONTROLLER_NAMESPACE:alb-controller-sa\""
run "Assign Contributor on node RG" "az role assignment create --assignee-object-id \"$PRINCIPAL_ID\" --assignee-principal-type ServicePrincipal --scope \"$NODE_RG_ID\" --role Contributor"
run "Assign AppGw for Containers Configuration Manager" "az role assignment create --assignee-object-id \"$PRINCIPAL_ID\" --assignee-principal-type ServicePrincipal --scope \"$AGC_SUBNET_ID\" --role 4d97b98b-1d4f-4787-a291-c67834d212e7"
run "Assign AppGw for Containers Configuration Reader" "az role assignment create --assignee-object-id \"$PRINCIPAL_ID\" --assignee-principal-type ServicePrincipal --scope \"$NODE_RG_ID\" --role fbc52c3f-28ad-4303-a892-8a056630b8f1"
run "Install ALB controller" "helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller --namespace \"$HELM_NAMESPACE\" --create-namespace --set albController.namespace=\"$CONTROLLER_NAMESPACE\" --set albController.podIdentity.clientID=\"$CLIENT_ID\""
run "Check ALB controller pods" "kubectl get pods -n \"$CONTROLLER_NAMESPACE\""
run "Check gatewayclass" "kubectl get gatewayclass"
run "Apply generated AGC manifests" "kubectl apply -f $AGC_OUTPUT_DIR/"
run "Verify AGC resources" "kubectl get applicationloadbalancer -n \"$NAMESPACE\"; kubectl get gateway -n \"$NAMESPACE\""
run "Get AGC FQDN" "export AGC_FQDN=\"$(kubectl get gateway \"$GATEWAY_NAME\" -n \"$NAMESPACE\" -o jsonpath='{.status.addresses[0].value}')\"; echo \"$AGC_FQDN\""
run "Validate AGC route one" "curl -v \"http://$AGC_FQDN/hello-world-one\""
run "Validate AGC route two" "curl -v \"http://$AGC_FQDN/hello-world-two\""

# Section 5: WAF
run "Create WAF policy and set Prevention mode" "export WAF_POLICY_NAME=agc-waf-policy; az network application-gateway waf-policy create --name \"$WAF_POLICY_NAME\" --resource-group \"$RESOURCE_GROUP\" --location \"$LOCATION\"; az network application-gateway waf-policy policy-setting update --policy-name \"$WAF_POLICY_NAME\" --resource-group \"$RESOURCE_GROUP\" --mode Prevention --state Enabled"
run "Resolve WAF policy ID" "export WAF_ID=\"$(az network application-gateway waf-policy show --name \"$WAF_POLICY_NAME\" --resource-group \"$RESOURCE_GROUP\" --query id -o tsv)\"; echo \"$WAF_ID\""
echo
echo "==> Attach WAF policy to gateway"
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
run "Send blocked test request (SQLi pattern)" "curl -v \"http://$AGC_FQDN/hello-world-one/?id=1' OR '1'='1\""
run "Send blocked test request (SQLi pattern)" "curl -v \"http://$AGC_FQDN/hello-world-two/?id=1' OR '1'='1\""
run "Send clean request" "curl -v \"http://$AGC_FQDN/hello-world-one\""
run "Send clean request" "curl -v \"http://$AGC_FQDN/hello-world-two\""

echo
echo "Lab complete. If needed, clean up with: az group delete --name \"$RESOURCE_GROUP\" --yes --no-wait"
