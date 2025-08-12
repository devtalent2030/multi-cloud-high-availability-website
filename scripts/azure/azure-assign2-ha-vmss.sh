#!/usr/bin/env bash
# =======================================================================================
# Azure Assign2 – HA web on VMSS + Standard LB with Least-Privilege VNet
#
# Creates:
#   - VNet + private subnet (no public IPs on VMs)
#   - NAT Gateway for egress (apt-get) without exposing VMs
#   - NSG with two inbound rules:
#       * allow-lb-http:   Source=AzureLoadBalancer -> TCP/80 (health probes)
#       * allow-http-any:  Source=Internet         -> TCP/80 (real clients)  <-- REQUIRED
#   - Public Standard Load Balancer (frontend IP, HTTP probe "/", rule 80->80)
#   - VM Scale Set (2x Ubuntu) behind the LB, cloud-init installs nginx + your message
#   - Autoscale: min=2, max=4, out @ CPU>60% (1m), in @ CPU<30% (5m)
#
# Run this block-by-block. Each step verifies itself. Stop if a verify looks wrong.
# =======================================================================================

set -euo pipefail

# -------- Vars: change LAST / FULL_NAME if you want --------
: "${LAST:=Ogunrinu}"
: "${FULL_NAME:=Oyelekan Ogunrinu}"
: "${LOCATION:=canadacentral}"   # set your Azure region here if different

NAME="${LAST}-assign2"
RG="${NAME}-rg"

VNET="${NAME}-vnet"
SUBNET_APP="${NAME}-subnet"

NSG="${NAME}-nsg"

NAT_PIP="${NAME}-nat-pip"
NATGW="${NAME}-natgw"

LB="${NAME}-lb"
LB_PIP="${NAME}-lb-pip"
FE="${NAME}-fe"
POOL="${NAME}-bepool"
PROBE="${NAME}-probe"
LBRULE="${NAME}-lbrule"

VMSS="${NAME}-vmss"
VM_SIZE="Standard_B1s"
ADMIN="azureuser"
IMG_ALIAS="Ubuntu2204"

echo "=========== CONFIG ===========
LOCATION=$LOCATION
RG=$RG
VNET=$VNET
SUBNET=$SUBNET_APP
NSG=$NSG
LB=$LB
LB_PIP=$LB_PIP
FE=$FE
POOL=$POOL
PROBE=$PROBE
LBRULE=$LBRULE
VMSS=$VMSS
VM_SIZE=$VM_SIZE
IMG=$IMG_ALIAS
FULL_NAME=$FULL_NAME
==============================="

# ----- [1] Resource Group -----
az group create -l "$LOCATION" -n "$RG" -o table

# ----- [2] VNet + Subnet + NAT (egress only) -----
az network vnet create -g "$RG" -n "$VNET" \
  --address-prefix 10.20.0.0/16 \
  --subnet-name "$SUBNET_APP" --subnet-prefix 10.20.1.0/24 -o table

az network public-ip create -g "$RG" -n "$NAT_PIP" \
  --sku Standard --allocation-method Static -o table

az network nat gateway create -g "$RG" -n "$NATGW" \
  --public-ip-addresses "$NAT_PIP" -o table

az network vnet subnet update -g "$RG" --vnet-name "$VNET" -n "$SUBNET_APP" \
  --nat-gateway "$NATGW" -o table

# Verify NAT attached
az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$SUBNET_APP" \
  --query "{subnet:name,range:addressPrefix,nat:natGateway.id}" -o table

# ----- [3] NSG – probes + real users on port 80 -----
az network nsg create -g "$RG" -n "$NSG" -o table

# Health probes from the Azure LB fabric
az network nsg rule create -g "$RG" --nsg-name "$NSG" -n allow-lb-http \
  --priority 100 --access Allow --protocol Tcp --direction Inbound \
  --source-address-prefixes AzureLoadBalancer \
  --destination-port-ranges 80 -o table

# REAL CLIENT TRAFFIC (the missing piece that fixes timeouts)
az network nsg rule create -g "$RG" --nsg-name "$NSG" -n allow-http-any \
  --priority 110 --access Allow --protocol Tcp --direction Inbound \
  --source-address-prefixes Internet \
  --destination-port-ranges 80 -o table

# Attach NSG to the subnet
az network vnet subnet update -g "$RG" --vnet-name "$VNET" -n "$SUBNET_APP" \
  --network-security-group "$NSG" -o table

# Verify NSG rules
az network nsg rule list -g "$RG" --nsg-name "$NSG" -o table

# ----- [4] Standard Public LB (FE, pool, probe, rule) -----
az network public-ip create -g "$RG" -n "$LB_PIP" \
  --sku Standard --allocation-method Static -o table

az network lb create -g "$RG" -n "$LB" --sku Standard \
  --public-ip-address "$LB_PIP" \
  --frontend-ip-name "$FE" \
  --backend-pool-name "$POOL" -o table

az network lb probe create -g "$RG" --lb-name "$LB" -n "$PROBE" \
  --protocol Http --port 80 --path / -o table

az network lb rule create -g "$RG" --lb-name "$LB" -n "$LBRULE" \
  --protocol Tcp --frontend-ip-name "$FE" \
  --frontend-port 80 --backend-port 80 \
  --backend-pool-name "$POOL" --probe-name "$PROBE" -o table

# Sanity: FE bound to the LB public IP
az network lb frontend-ip show -g "$RG" --lb-name "$LB" -n "$FE" \
  --query "{publicIP:id}" -o table

# ----- [5] Cloud-init: install nginx + your message -----
cat > cloud-init.yml <<EOF
#cloud-config
package_update: true
packages:
  - nginx
write_files:
  - path: /var/www/html/index.html
    permissions: '0644'
    content: |
      <!doctype html>
      <html><head><meta charset="utf-8"><title>${NAME}</title></head>
      <body style="font-family: system-ui, Arial; margin:40px;">
      <h1>${NAME}</h1>
      <p>Healthy - ${FULL_NAME}</p>
      </body></html>
runcmd:
  - systemctl enable nginx
  - systemctl restart nginx
EOF

# ----- [6] VMSS (2x Ubuntu) behind the LB -----
# Try zones 1 & 2; if region/SKU rejects, it will fall back without zones.
set +e
az vmss create \
  -g "$RG" -n "$VMSS" \
  --image "$IMG_ALIAS" \
  --orchestration-mode Uniform \
  --instance-count 2 \
  --vm-sku "$VM_SIZE" \
  --vnet-name "$VNET" --subnet "$SUBNET_APP" \
  --lb "$LB" --backend-pool-name "$POOL" \
  --upgrade-policy-mode Automatic \
  --custom-data cloud-init.yml \
  --admin-username "$ADMIN" --generate-ssh-keys \
  --zones 1 2 -o table
rc=$?
if [ $rc -ne 0 ]; then
  echo "Zones not supported; retrying without --zones..."
  az vmss create \
    -g "$RG" -n "$VMSS" \
    --image "$IMG_ALIAS" \
    --orchestration-mode Uniform \
    --instance-count 2 \
    --vm-sku "$VM_SIZE" \
    --vnet-name "$VNET" --subnet "$SUBNET_APP" \
    --lb "$LB" --backend-pool-name "$POOL" \
    --upgrade-policy-mode Automatic \
    --custom-data cloud-init.yml \
    --admin-username "$ADMIN" --generate-ssh-keys \
    -o table
fi
set -e

# Verify each instance serves 200 on its NIC IP (what the probe hits)
for ID in $(az vmss list-instances -g "$RG" -n "$VMSS" --query "[].instanceId" -o tsv); do
  echo "----- Instance $ID -----"
  az vmss run-command invoke -g "$RG" -n "$VMSS" --instance-id "$ID" \
    --command-id RunShellScript \
    --scripts '
      set -e
      ip=$(hostname -I | awk "{print \$1}")
      echo "IP=$ip"
      systemctl is-active nginx || echo nginx-not-active
      code=$(curl -s -o /dev/null -w "%{http_code}" http://$ip/)
      echo "curl $ip -> $code"
    ' --query "value[0].message" -o tsv
done

# ----- [7] Test the LB (first probe can take ~30–90s) -----
LB_IP=$(az network public-ip show -g "$RG" -n "$LB_PIP" --query ipAddress -o tsv)
echo "Open:  http://$LB_IP"
for i in {1..12}; do
  echo "--- LB try $i ---"
  if curl -s -I --max-time 10 "http://$LB_IP" | head -1 | grep -q "200 OK"; then
    echo "LB is serving 200 OK"
    break
  fi
  sleep 10
done

# ----- [8] Autoscale (min=2, max=4, CPU rules) -----
VMSS_ID=$(az vmss show -g "$RG" -n "$VMSS" --query id -o tsv)

az monitor autoscale create \
  -g "$RG" \
  --resource "$VMSS_ID" \
  --name "${NAME}-autoscale" \
  --min-count 2 --max-count 4 --count 2 -o table

az monitor autoscale rule create \
  -g "$RG" \
  --autoscale-name "${NAME}-autoscale" \
  --condition "Percentage CPU > 60 avg 1m" \
  --scale out 1 -o table

az monitor autoscale rule create \
  -g "$RG" \
  --autoscale-name "${NAME}-autoscale" \
  --condition "Percentage CPU < 30 avg 5m" \
  --scale in 1 -o table

# Show concise autoscale rule summary
az monitor autoscale show -g "$RG" --name "${NAME}-autoscale" \
  --query "profiles[].rules[].{direction:scaleAction.direction,change:scaleAction.value,metric:metricTrigger.metricName,op:metricTrigger.operator,threshold:metricTrigger.threshold,window:metricTrigger.timeWindow}" \
  -o table

# ----- [9] Evidence quick-links -----
echo
echo "================ EVIDENCE ================"
echo "Website (LB): http://$LB_IP"
echo "NSG rules:"
az network nsg rule list -g "$RG" --nsg-name "$NSG" -o table
echo "Subnet has NSG + NAT:"
az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$SUBNET_APP" \
  --query "{subnet:name,range:addressPrefix,nsg:networkSecurityGroup.id,nat:natGateway.id}" -o table
echo "VMSS instances (expect no public IPs):"
az vmss list-instance-public-ips -g "$RG" -n "$VMSS" -o table
echo "=========================================="

# (Optional) Cleanup:
# az group delete -n "$RG" --yes --no-wait
