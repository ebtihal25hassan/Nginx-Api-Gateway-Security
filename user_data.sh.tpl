#!/bin/bash
dnf install -y nginx

# fetch the token from SSM (not hardcoded in the NGINX config)
TOKEN=$(aws ssm get-parameter --name /lab/internal-token --with-decryption \
  --query Parameter.Value --output text --region ${region})

umask 077
printf 'map $host $internal_token { default "%s"; }\n' "$TOKEN" > /etc/nginx/conf.d/00-token.conf
umask 022

cat > /etc/nginx/conf.d/api-proxy.conf <<'EOF'
server {
    listen 80;
    server_name _;
    resolver 169.254.169.253 valid=30s;

    location / {
        root /usr/share/nginx/html;
    }

    location /api/ {
        set $api_host "${api_host}";

        rewrite ^/api/(.*)$ /$1 break;
        proxy_pass https://$api_host;

        proxy_ssl_server_name on;
        proxy_set_header Host $api_host;

        proxy_set_header X-Environment    "dev";
        proxy_set_header X-Student-ID     "${student_id}";
        proxy_set_header X-Internal-Token $internal_token;
    }
}
EOF

systemctl enable --now nginx