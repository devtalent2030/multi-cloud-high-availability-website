#!/usr/bin/env bash
# Assignment 2 — GCP deployment (VPC, Security, Compute, Load Balancing, Autoscaling)
# Creates: custom VPC+subnet, strict firewalls, instance template (nginx),
# regional MIG across two zones, global HTTP LB, autoscaling 2–4, prints LB IP.
# Re-run safe: skips things that already exist.
set -euo pipefail

############################################
# STEP 0 — PROJECT + NAMING (EDIT THESE)  #
############################################
# REQUIRED: gcloud must already be auth'd to the right account.
# REQUIRED: PROJECT must exist and have billing enabled.
PROJECT_ID="${PROJECT_ID:-ogunrinu-assign2-2508111920}"     # <- EDIT if needed
REGION="${REGION:-us-central1}"
ZONE_A="${ZONE_A:-us-central1-a}"
ZONE_B="${ZONE_B:-us-central1-b}"

LAST_RAW="${LAST_RAW:-nyota}"                            # <- EDIT to your last name
LAST="$(echo "$LAST_RAW" | tr '[:upper:]' '[:lower:]')"     # gcp resource names must be lowercase
NAME="${NAME:-${LAST}-assign2}"

# Derived names (do not edit unless you want custom names)
VPC="${VPC:-${NAME}-vpc}"
SUBNET="${SUBNET:-${NAME}-subnet}"
RANGE="${RANGE:-10.10.0.0/16}"
TAG_WEB="${TAG_WEB:-web}"
IT="${IT:-${NAME}-it}"
RMIG="${RMIG:-${NAME}-rmig}"
HC="${HC:-${NAME}-hc}"
BACKEND="${BACKEND:-${NAME}-backend}"
URLMAP="${URLMAP:-${NAME}-url-map}"
PROXY="${PROXY:-${NAME}-http-proxy}"
FR="${FR:-${NAME}-fwd-rule}"
IP_NAME="${IP_NAME:-${NAME}-ip}"

echo "=> Using project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" >/dev/null
gcloud config set compute/region "$REGION" >/dev/null
gcloud config set compute/zone   "$ZONE_A" >/dev/null

# Ensure Compute API is on (requires billing)
gcloud services enable compute.googleapis.com >/dev/null 2>&1 || true

exists() { gcloud "$@" >/dev/null 2>&1; }

############################################
# STEP 1 — NETWORK: VPC + SUBNET          #
############################################
echo "=> STEP 1: VPC + Subnet"
exists compute networks describe "$VPC" || \
  gcloud compute networks create "$VPC" --subnet-mode=custom

exists compute networks subnets describe "$SUBNET" --region "$REGION" || \
  gcloud compute networks subnets create "$SUBNET" \
    --network="$VPC" --range="$RANGE" --region="$REGION"

#################################################
# STEP 2 — SECURITY: FIREWALLS (STRICT, NEEDED) #
#################################################
echo "=> STEP 2: Firewalls"
# Internal traffic within your VPC CIDR
exists compute firewall-rules describe "${NAME}-allow-internal" || \
  gcloud compute firewall-rules create "${NAME}-allow-internal" \
    --network "$VPC" --allow tcp,udp,icmp --source-ranges "$RANGE"

# Only Google LB/HealthCheck ranges can hit HTTP on instances with tag=web
exists compute firewall-rules describe "${NAME}-allow-lb-hc-http" || \
  gcloud compute firewall-rules create "${NAME}-allow-lb-hc-http" \
    --network "$VPC" --allow tcp:80 \
    --source-ranges 130.211.0.0/22,35.191.0.0/16 \
    --target-tags "$TAG_WEB"

##################################################
# STEP 3 — COMPUTE: INSTANCE TEMPLATE (nginx)    #
##################################################
echo "=> STEP 3: Instance Template + startup script"
STARTUP="/tmp/${NAME}-startup.sh"
cat > "$STARTUP" <<'EOS'
#!/bin/bash
set -euxo pipefail
apt-get update
apt-get install -y nginx
ZONE=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
cat >/var/www/html/index.html <<HTML
<!DOCTYPE html>
<html><head><title>$(hostname)</title></head>
<body style="font-family:sans-serif;">
  <h1 style="color:#4f46e5;">'"'"$NAME"'"' — GCP Regional MIG behind Global HTTP LB</h1>
  <p>Served by: $(hostname)</p>
  <p>Zone: ${ZONE}</p>
  <p>Time: $(date -Is)</p>
</body></html>
HTML
systemctl enable nginx
systemctl restart nginx
EOS

if ! exists compute instance-templates describe "$IT"; then
  # NOTE: Uses default external IP so startup can apt-get packages.
  gcloud compute instance-templates create "$IT" \
    --machine-type=e2-micro \
    --image-family=debian-12 --image-project=debian-cloud \
    --network="$VPC" --subnet="$SUBNET" \
    --tags="$TAG_WEB" \
    --metadata "NAME=$NAME" \
    --metadata-from-file startup-script="$STARTUP"
fi

############################################################
# STEP 4 — HA: REGIONAL MIG (2 ZONES) SIZE=2 + NAMED PORT #
############################################################
echo "=> STEP 4: Regional MIG (HA across $ZONE_A,$ZONE_B)"
if ! exists compute instance-groups managed describe "$RMIG" --region "$REGION"; then
  gcloud compute instance-groups managed create "$RMIG" \
    --region="$REGION" \
    --base-instance-name="${NAME}-vm" \
    --size=2 \
    --template="$IT" \
    --zones="$ZONE_A,$ZONE_B"
  gcloud compute instance-groups managed set-named-ports "$RMIG" \
    --region="$REGION" --named-ports=http:80
fi

##############################################################
# STEP 5 — GLOBAL HTTP LB: HC + BACKEND + MAP + PROXY + IP   #
##############################################################
echo "=> STEP 5: Global HTTP Load Balancer"
exists compute health-checks describe "$HC" || \
  gcloud compute health-checks create http "$HC" \
    --request-path="/" --port=80 --check-interval=5s --timeout=5s \
    --healthy-threshold=2 --unhealthy-threshold=2

exists compute backend-services describe "$BACKEND" --global || \
  gcloud compute backend-services create "$BACKEND" \
    --global --protocol=HTTP --port-name=http \
    --health-checks="$HC" --timeout=30s

# Attach the REGIONAL MIG to the global backend
gcloud compute backend-services add-backend "$BACKEND" --global \
  --instance-group="$RMIG" \
  --instance-group-region="$REGION" \
  --balancing-mode=UTILIZATION --max-utilization=0.8 >/dev/null 2>&1 || true

exists compute url-maps describe "$URLMAP" || \
  gcloud compute url-maps create "$URLMAP" --default-service="$BACKEND"

exists compute target-http-proxies describe "$PROXY" || \
  gcloud compute target-http-proxies create "$PROXY" --url-map="$URLMAP"

if ! exists compute addresses describe "$IP_NAME" --global; then
  gcloud compute addresses create "$IP_NAME" --global
fi
LB_IP="$(gcloud compute addresses describe "$IP_NAME" --global --format='value(address)')"

exists compute forwarding-rules describe "$FR" --global || \
  gcloud compute forwarding-rules create "$FR" \
    --global --target-http-proxy="$PROXY" --ports=80 --address="$LB_IP"

echo "=> LB_IP=$LB_IP"

###########################################
# STEP 6 — AUTOSCALING (min 2, max 4)     #
###########################################
echo "=> STEP 6: Autoscaling policy (2–4, target LB util 0.6)"
gcloud compute instance-groups managed set-autoscaling "$RMIG" \
  --region="$REGION" \
  --min-num-replicas=2 --max-num-replicas=4 \
  --target-load-balancing-utilization=0.6 >/dev/null

###########################################
# STEP 7 — QUICK HEALTH / EVIDENCE HINTS  #
###########################################
echo "=> STEP 7: Health check (may take ~1–3 minutes to show HEALTHY)"
gcloud compute backend-services get-health "$BACKEND" --global || true

cat <<INFO

===========================================================
DONE.

Evidence checklist (Console):
  7) ALB works: open  http://$LB_IP  (shows page with your name)
  8) >=2 instances:  Compute Engine -> Instance groups -> $RMIG -> Instances
  9) Custom VPC:     VPC network -> VPC networks -> $VPC (Details/Subnets)
                     VPC network -> Firewall (filter by network: $VPC)
 10) Autoscaling:    Instance groups -> $RMIG -> Autoscaling (ON, 2..4)
                     Optionally show Monitoring/Activity after brief load
 11) HA/Redundancy:  $RMIG Details -> zones: $ZONE_A, $ZONE_B
 12) Security:       Firewall rules:
                       - ${NAME}-allow-internal  (source: $RANGE)
                       - ${NAME}-allow-lb-hc-http (src: 130.211.0.0/22,35.191.0.0/16, tag: $TAG_WEB)

Useful CLI:
  curl http://$LB_IP
  gcloud compute instance-groups managed list-instances "$RMIG" --region "$REGION"

Cleanup (if you want to delete the *project* later):
  gcloud projects delete "$PROJECT_ID"
===========================================================
INFO
