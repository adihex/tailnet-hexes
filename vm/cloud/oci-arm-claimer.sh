#!/usr/bin/env bash
set -euo pipefail

TENANCY="ocid1.tenancy.oc1..aaaaaaaapwbb3zrkl5yrfxu3ajcy62p5icgd6qgrebg4a5tc4agfkz3mmqrq"
IMAGE_ID="ocid1.image.oc1.ap-mumbai-1.aaaaaaaa2jurqb3jm7hlpqw3au35loaqjkcozbyh7znn4jnfu5zbrgfulwia"
SUBNET_ID="ocid1.subnet.oc1.ap-mumbai-1.aaaaaaaae3irteetenw33wrxrqldztxyb4d5lgd7xzpgxi7nn4vficgrjwba"
AD_NAME="ZrFo:AP-MUMBAI-1-AD-1"
SSH_KEY_FILE="/home/adihex/.ssh/id_ed25519.pub"
LOG_FILE="/tmp/oci-arm-claimer.log"
STATUS_FILE="/tmp/oci-arm-claimer.status"

log() {
  local msg="[$(date '+%T')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

log "Starting Ampere A1 (ARM64) capacity claimer for Mumbai AD-1..."
log "Target: 4 OCPUs, 24 GB RAM, Ubuntu 24.04 aarch64 (Shape: VM.Standard.A1.Flex)"

attempt=0
while true; do
  attempt=$((attempt + 1))
  
  # Check if an A1 instance is already running
  EXISTING=$(/home/adihex/bin/oci compute instance list --compartment-id "$TENANCY" --shape "VM.Standard.A1.Flex" --lifecycle-state RUNNING --output json 2>/dev/null | python3 -c "import sys, json; data = json.load(sys.stdin).get('data', []); print(data[0]['id'] if data else '')" || true)
  if [ -n "$EXISTING" ]; then
    log "SUCCESS! Ampere A1 instance is RUNNING: $EXISTING"
    notify-send -u critical -a "OCI Claimer" "Ampere A1 Running!" "4 OCPU / 24 GB ARM instance is active in Mumbai!" || true
    pw-play /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || true
    echo "{\"status\":\"RUNNING\",\"id\":\"$EXISTING\"}" > "$STATUS_FILE"
    break
  fi

  set +e
  OUT=$(/home/adihex/lib/oracle-cli/bin/python3 - <<PY 2>&1
import oci, sys
config = oci.config.from_file("/home/adihex/.oci/config", "DEFAULT")
client = oci.core.ComputeClient(config)
details = oci.core.models.LaunchInstanceDetails(
    compartment_id=config["tenancy"],
    availability_domain="$AD_NAME",
    shape="VM.Standard.A1.Flex",
    shape_config=oci.core.models.LaunchInstanceShapeConfigDetails(ocpus=4.0, memory_in_gbs=24.0),
    image_id="$IMAGE_ID",
    create_vnic_details=oci.core.models.CreateVnicDetails(
        subnet_id="$SUBNET_ID",
        assign_public_ip=True
    ),
    display_name="hexes-cloud-arm",
    metadata={"ssh_authorized_keys": open("$SSH_KEY_FILE").read()}
)
try:
    res = client.launch_instance(details, retry_strategy=oci.retry.NoneRetryStrategy())
    print("SUCCESS " + res.data.id)
except oci.exceptions.ServiceError as e:
    print(f"FAILED {e.status} {e.code}: {e.message}")
PY
)
  set -e

  if echo "$OUT" | grep -q "^SUCCESS"; then
    INSTANCE_ID=$(echo "$OUT" | awk '{print $2}')
    log "INSTANCE PROVISIONED! ID: $INSTANCE_ID"
    notify-send -u critical -a "OCI Claimer" "Ampere A1 Claimed!" "Provisioning 4 OCPU / 24 GB ARM instance..." || true
    pw-play /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || true
    
    # Wait for RUNNING state and get Public IP
    log "Waiting for instance to reach RUNNING state..."
    PUBLIC_IP=""
    for i in $(seq 1 30); do
      sleep 10
      STATUS_JSON=$(/home/adihex/lib/oracle-cli/bin/python3 - <<PY 2>/dev/null || true
import oci, json
config = oci.config.from_file("/home/adihex/.oci/config", "DEFAULT")
compute = oci.core.ComputeClient(config)
net = oci.core.VirtualNetworkClient(config)
inst = compute.get_instance("$INSTANCE_ID").data
if inst.lifecycle_state == "RUNNING":
    vnics = compute.list_vnic_attachments(compartment_id=config["tenancy"], instance_id="$INSTANCE_ID").data
    if vnics:
        v = net.get_vnic(vnics[0].vnic_id).data
        print(json.dumps({"ip": v.public_ip, "state": "RUNNING"}))
PY
)
      if [ -n "$STATUS_JSON" ]; then
        PUBLIC_IP=$(echo "$STATUS_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('ip', ''))")
        if [ -n "$PUBLIC_IP" ]; then
          log "Instance is RUNNING at Public IP: $PUBLIC_IP"
          break
        fi
      fi
    done

    echo "{\"status\":\"PROVISIONED\",\"id\":\"$INSTANCE_ID\",\"ip\":\"$PUBLIC_IP\"}" > "$STATUS_FILE"
    
    if [ -n "$PUBLIC_IP" ]; then
      log "Waiting for SSH on $PUBLIC_IP..."
      for s in $(seq 1 20); do
        if ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 ubuntu@"$PUBLIC_IP" "true" 2>/dev/null; then
          log "SSH connection verified! Launching automated cloud hexes setup..."
          /home/adihex/bin/setup-cloud-hexes.sh "$PUBLIC_IP" >> "$LOG_FILE" 2>&1 || true
          log "Cloud hexes deployment complete on $PUBLIC_IP!"
          notify-send -u critical -a "OCI Claimer" "Hexes Cloud Live!" "Hexes server is deployed and running on your new ARM instance at $PUBLIC_IP!" || true
          break
        fi
        sleep 5
      done
    fi
    break
  else
    log "Attempt #$attempt: $OUT"
  fi

  sleep 75
done
