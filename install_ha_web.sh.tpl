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
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>HA Demo</title>
  <style>
    body {
      margin: 0;
      font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
      background-color: #f4f4f4;
      color: #333;
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 40px;
    }

    h1 {
      font-size: 2.5rem;
      margin-bottom: 20px;
      color: #1a1a1a;
    }

    .card {
      background-color: white;
      padding: 30px;
      border-radius: 12px;
      box-shadow: 0 4px 20px rgba(0, 0, 0, 0.1);
      text-align: center;
    }

    img {
      width: 300px;
      border-radius: 10px;
      margin-bottom: 20px;
      cursor: pointer;
      &:hover {
        animation: pop 0.3s ease-in-out forwards;
       transform: scale(1.05);
      }
    }

    p {
      font-size: 1.2rem;
      color: #666;
    }

    .hostname {
      font-weight: bold;
      color: #007acc;
    }

    @keyframes pop {
      0% {
        transform: scale(1);
      }
      50% {
        transform: scale(1.08);
      }
      100% {
        transform: scale(1.05);
      }
    }
  </style>
</head>
<body>
<div class="card">
  <h1>HA Demo: <span class="hostname">$HOSTNAME</span> (<span class="hostname">$NODE_STATE</span>)</h1>
  <img src="https://${cdn_domain}/terraform-man-of-automation.png" alt="DevOps Hero">
  <p>Served from <span class="hostname">$HOSTNAME</span></p>
</div>
</body>
</html>
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