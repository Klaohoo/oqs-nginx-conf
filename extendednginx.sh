cat >/opt/nginx-oqs/conf/nginx.conf <<'EOF'
worker_processes auto;
pid logs/nginx.pid;

events {
    worker_connections 1024;
}

http {
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;

    server {
        listen 8443 ssl;
        server_name localhost;
        root /opt/nginx-oqs/html/8443;
        index index.html;

        ssl_protocols TLSv1.3;
        ssl_certificate /opt/nginx-oqs/certs/rsa.crt;
        ssl_certificate_key /opt/nginx-oqs/certs/rsa.key;
        ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
        ssl_conf_command Groups X25519:P-256;
    }

    server {
        listen 8444 ssl;
        server_name localhost;
        root /opt/nginx-oqs/html/8444;
        index index.html;

        ssl_protocols TLSv1.3;
        ssl_certificate /opt/nginx-oqs/certs/ecdsa.crt;
        ssl_certificate_key /opt/nginx-oqs/certs/ecdsa.key;
        ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
        ssl_conf_command Groups P-384:X25519;
    }

    server {
        listen 8445 ssl;
        server_name localhost;
        root /opt/nginx-oqs/html/8445;
        index index.html;

        ssl_protocols TLSv1.3;
        ssl_certificate /opt/nginx-oqs/certs/mldsa65.crt;
        ssl_certificate_key /opt/nginx-oqs/certs/mldsa65.key;
        ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
        ssl_conf_command Groups MLKEM768;
    }

    server {
        listen 8446 ssl;
        server_name localhost;
        root /opt/nginx-oqs/html/8446;
        index index.html;

        ssl_protocols TLSv1.3;
        ssl_certificate /opt/nginx-oqs/certs/rsa.crt;
        ssl_certificate_key /opt/nginx-oqs/certs/rsa.key;
        ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
        ssl_conf_command Groups MLKEM768;
    }

    server {
        listen 8447 ssl;
        server_name localhost;
        root /opt/nginx-oqs/html/8447;
        index index.html;

        ssl_protocols TLSv1.3;
        ssl_certificate /opt/nginx-oqs/certs/mldsa65.crt;
        ssl_certificate_key /opt/nginx-oqs/certs/mldsa65.key;
        ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
        ssl_conf_command Groups X25519:P-256;
    }

    server {
        listen 8448 ssl;
        server_name localhost;
        root /opt/nginx-oqs/html/8448;
        index index.html;

        ssl_protocols TLSv1.3;
        ssl_certificate /opt/nginx-oqs/certs/mldsa44.crt;
        ssl_certificate_key /opt/nginx-oqs/certs/mldsa44.key;
        ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
        ssl_conf_command Groups MLKEM512;
    }

    server {
        listen 8449 ssl;
        server_name localhost;
        root /opt/nginx-oqs/html/8449;
        index index.html;

        ssl_protocols TLSv1.3;
        ssl_certificate /opt/nginx-oqs/certs/mldsa87.crt;
        ssl_certificate_key /opt/nginx-oqs/certs/mldsa87.key;
        ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
        ssl_conf_command Groups MLKEM1024;
    }
}
EOF
