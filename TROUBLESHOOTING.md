# Troubleshooting Guide

This guide lists the most common issues for this lab and quick actions to unblock delivery.

## 1) AKS Creation Fails

Symptoms:
- `az aks create` fails with quota, SKU, or capacity errors.

Checks:
- Verify subscription quota in selected region.
- Try a different VM size or region.

Actions:
- Change `VM_SIZE` to a commonly available SKU such as `Standard_D4s_v5`.
- Re-run resource provider registration and retry.

## 2) Ingress External IP Does Not Appear

Symptoms:
- NGINX service has `<pending>` EXTERNAL-IP.

Checks:
- `kubectl get svc -n ingress-basic`
- `kubectl describe svc ingress-nginx-controller -n ingress-basic`

Actions:
- Wait a few minutes for Azure LB provisioning.
- Confirm AKS cluster is healthy and nodes are Ready.
- Reinstall ingress controller if service annotations were malformed.

## 3) Migration Utility Build Errors

Symptoms:
- `go build -o agc-migration ./cmd` fails.

Checks:
- `go version`
- Internet access from shell environment.

Actions:
- Use Cloud Shell Bash with current Go tooling.
- Retry `git clone` and `go build` from a clean folder.

## 4) AGC Subnet Delegation Errors

Symptoms:
- Subnet update or AGC provisioning fails.

Checks:
- Subnet delegation value.
- Address range overlap with existing subnets.

Actions:
- Use a non-overlapping CIDR for `agc-subnet`.
- Ensure delegation is exactly `Microsoft.ServiceNetworking/trafficControllers`.

## 5) ALB Controller Pods Not Running

Symptoms:
- Pods in `azure-alb-system` are CrashLoopBackOff or Pending.

Checks:
- `kubectl get pods -n azure-alb-system`
- `kubectl logs deployment/alb-controller -n azure-alb-system`

Actions:
- Validate managed identity client ID passed to Helm values.
- Validate federated credential subject matches service account namespace and name.
- Restart controller after RBAC or identity fixes.

## 6) Gateway Stuck Without Address

Symptoms:
- `kubectl get gateway -n ingress-basic` shows no address.

Checks:
- `kubectl describe gateway alb-gateway -n ingress-basic`
- `kubectl describe applicationloadbalancer alb -n ingress-basic`

Actions:
- Confirm required role assignments exist for node RG and AGC subnet.
- Confirm AGC subnet ID used in migration command matches deployed subnet.
- Wait for provisioning and re-check events.

## 7) Routes Return 404 or Wrong Backend

Symptoms:
- AGC FQDN resolves, but paths fail or route incorrectly.

Checks:
- Inspect generated HTTPRoute manifests.
- Verify backendRefs point to correct service names and ports.

Actions:
- Re-run migration utility and review generated YAML.
- Ensure all services are in the expected namespace.
- Confirm rewrite intent from original ingress annotations.

## 8) WAF Policy Not Blocking Test Request

Symptoms:
- SQL injection test request is not blocked.

Checks:
- WAF policy mode and state.
- WAF binding object exists and targets correct Gateway.

Actions:
- Confirm policy is in Prevention mode, not Detection.
- Confirm binding points to the same gateway namespace and name.
- Wait for policy propagation and retry request.

## 9) Role Assignment Errors

Symptoms:
- `az role assignment create` fails with authorization errors.

Checks:
- Current signed-in principal permissions.
- Correct scope values for node resource group and subnet.

Actions:
- Use an owner or user access administrator principal for setup.
- Recompute `NODE_RG_ID` and `AGC_SUBNET_ID`, then retry.

## 10) Cleanup Does Not Remove Everything

Symptoms:
- Resources remain after deleting resource group.

Checks:
- Confirm all lab resources are in the same resource group.

Actions:
- List resources by group and remove leftovers manually.
- If identities were created in a different group by mistake, remove separately.

## Fast Diagnostics Bundle

Run these commands for a quick status snapshot:

```bash
kubectl get nodes
kubectl get pods -A
kubectl get ingress -n ingress-basic
kubectl get gateway -n ingress-basic
kubectl get applicationloadbalancer -n ingress-basic
kubectl get httproute -n ingress-basic
kubectl get webapplicationfirewallpolicy -n ingress-basic
```
