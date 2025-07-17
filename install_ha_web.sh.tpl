#!/bin/bash
exec >> /var/log/user-data.log 2>&1
set -x

BUCKET="${bucket}"
NODE_STATE="${node_state}" 
NODE_PRIORITY="${node_priority}"
EIP_ALLOC_ID="${eip_allocation_id}"
HA_GROUP="${ha_group_name}"
AWS_REGION="${region}"


apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx keepalived jq curl unzip

cat >/var/www/html/index.nginx-debian.html <<EOFHTML
<html><body><h1>HA Demo: $HOSTNAME ($NODE_STATE)</h1><img src="https://${cdn_domain}/terraform-man-of-automation.png" width="300"><p>Served from $(hostname -i)</p></body></html>
EOFHTML

systemctl enable nginx || true
systemctl start nginx || true

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install


cat >/usr/local/bin/attach_eip.sh <<'EOFEIP'
#!/bin/bash
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token \   -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
LOCAL_INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \   http://169.254.169.254/latest/meta-data/instance-id)
ALOC_ID=$(aws ec2 describe-addresses --query "Addresses[0].AllocationId" --output text)
aws ec2 associate-address --instance-id "$LOCAL_INSTANCE_ID" --allocation-id "$ALOC_ID"
EOFEIP
chmod +x /usr/local/bin/attach_eip.sh

cat >/usr/local/bin/check_nginx <<'EOFEIP'
#!/bin/bash
curl -fsS http://localhost:80/ >/dev/null
EOFEIP
chmod +x /usr/local/bin/check_nginx

TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
LOCAL_INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
LOCAL_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
PEER_IP=$(aws ec2 describe-instances \
  --query "Reservations[*].Instances[*].[PrivateIpAddress]" \
  --output text | grep -v -e None -e "$LOCAL_IP")

cat >/etc/keepalived/keepalived.conf <<EOFKEEP
global_defs {
  enable_script_security
  script_user root
}

vrrp_script check_nginx {
   script "/usr/local/bin/check_nginx"
   interval 2
   timeout 1
   fall 2
   rise 1 }

vrrp_instance VI_1 {
  state MASTER
  interface ens5
  virtual_router_id 51
  priority 150
  advert_int 1
  nopreempt

  unicast_src_ip $LOCAL_IP
  unicast_peer {
    $PEER_IP
  }

  authentication {
    auth_type PASS
    auth_pass "ySecret"
  }

  track_script {
    check_nginx
  }

  notify_master "/usr/local/bin/attach_eip.sh"
}
EOFKEEP

systemctl enable keepalived || true
systemctl restart keepalived || true