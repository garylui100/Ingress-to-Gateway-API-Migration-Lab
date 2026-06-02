# Lab Workbook: NGINX Ingress to Gateway API on AGC

Use this workbook during delivery or self-study to track progress and verify outcomes.

## Instructions

- Follow the full lab in README.md.
- Mark each task complete only after the validation item passes.
- Capture evidence (CLI output or screenshots) for gates and tests.

## Step Checklist

### Phase 1: Environment and Baseline

- [ ] Set all required environment variables.
Validation: `echo $SUBSCRIPTION_ID` and `echo $AKS_NAME` return expected values.

- [ ] Sign in and set subscription.
Validation: `az account show --query id -o tsv` equals your subscription ID.

- [ ] Register all required providers.
Validation: `az provider show --namespace Microsoft.ServiceNetworking --query registrationState -o tsv` is `Registered`.

- [ ] Create AKS cluster with OIDC and Workload Identity.
Validation: `kubectl get nodes` returns Ready nodes.

- [ ] Install NGINX ingress controller.
Validation: `kubectl get svc -n ingress-basic` shows ingress-nginx service with external IP.

- [ ] Deploy sample apps and ingress resources.
Validation: `kubectl get ingress -n ingress-basic` shows both ingress objects.

- [ ] Validate NGINX traffic.
Validation: curl to `/hello-world-one` and `/hello-world-two` returns app content.

### Phase 2: Conversion and AGC Bring-Up

- [ ] Build AGC migration utility.
Validation: `./agc-migration --help` runs successfully.

- [ ] Create and delegate AGC subnet.
Validation: subnet delegation includes `Microsoft.ServiceNetworking/trafficControllers`.

- [ ] Generate Gateway API manifests.
Validation: output folder contains Gateway and HTTPRoute YAML files.

- [ ] Create managed identity and federated credential.
Validation: identity and federated credential show in Azure CLI queries.

- [ ] Assign required RBAC roles.
Validation: role assignments exist at node resource group and AGC subnet scopes.

- [ ] Install ALB Controller and validate GatewayClass.
Validation: `kubectl get pods -n azure-alb-system` shows Running and `kubectl get gatewayclass` lists Azure ALB class.

- [ ] Apply converted resources.
Validation: `kubectl get applicationloadbalancer -n ingress-basic` returns an object.

- [ ] Validate AGC traffic.
Validation: curl to AGC FQDN for both routes returns expected app content.

### Phase 3: WAF and Security Validation

- [ ] Create WAF policy in Prevention mode.
Validation: policy mode is `Prevention` and state is `Enabled`.

- [ ] Bind WAF policy to Gateway.
Validation: `kubectl get webapplicationfirewallpolicy -n ingress-basic` shows `waf-binding`.

- [ ] Test blocked and clean traffic.
Validation: SQL injection test is blocked and normal route returns success.

## Evidence Capture

- Baseline ingress endpoint:
- AGC gateway FQDN:
- Gateway API resources generated:
- WAF policy resource ID:
- Blocked request response status:
- Clean request response status:

## Exit Criteria

- Baseline NGINX path validated.
- AGC path validated with matching routes.
- WAF policy attached and verified.
- Migration artifacts reviewed for parity and readiness.
