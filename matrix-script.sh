#!/usr/bin/env bash
echo "Welcome to matrix-synapse install";
echo "We will install the following components on your server:
- matrix-synapse as a Matrix server
- postgres as a database
- nginx as a webserver and reverse proxy server";
echo "";
echo "IMPORTANT! When prompted for your domain, enter the domain you plan to run Matrix on.";
echo "If you want to run Matrix on example.com, DO NOT enter matrix.example.com.";
echo "A delegation like chat.example.com with Matrix residing at matrix.chat.example.com is entirely possible.";
echo "In that case, just enter chat.example.com";
echo "";
read -p "Do you want to continue? [Y/n] " -n 1 -r
echo;
if [[ $REPLY =~ ^[Nn]$ ]]
then
    exit 1
fi
if [[ $EUID -ne 0 ]]
then
	echo "ERR - you need to run this script as root";
	exit 1;
fi
echo "INFO - Installing prerequisites";
echo "INFO - Updating mirrors";
apt update
apt install -y nginx curl wget lsb-release apt-transport-https certbot postgresql docker.io docker-compose fail2ban
echo "INFO - Adding Matrix mirrors";
wget -O /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/matrix-org.list
echo "INFO - Updating mirrors";
apt update
echo "INFO - Installing Matrix core";
apt install -y matrix-synapse-py3
if [ -f "/etc/matrix-synapse/homeserver.yaml" ]
then
	echo "OK - Matrix core installed"
else
	echo "ERR - Matrix installation seems to have failed. Please reinstall your operation system and run this script again."
	exit 2
fi

echo "configure Postgre database";
PSWD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
echo "synapse user database password = $PSWD"
sudo -su postgres <<EOF
psql -c "CREATE USER synapse WITH PASSWORD '$PSWD';"
createdb --encoding=UTF8 --locale=C --template=template0 --owner=synapse synapse
exit
EOF

echo "INFO - performing initial configuration";
echo "database:
  name: psycopg2
  args:
    user: synapse
    password: '$PSWD'
    database: synapse
    host: localhost
    cp_min: 5
    cp_max: 10" > /etc/matrix-synapse/conf.d/database.yaml
echo "registration_shared_secret: $(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)" > /etc/matrix-synapse/conf.d/register.yaml
echo "enable_registration: true" >> /etc/matrix-synapse/conf.d/register.yaml
echo "enable_registration_without_verification: true" >> /etc/matrix-synapse/conf.d/register.yaml
echo "";
read -p "Do you want certbot to automatically obtain an SSL Certificate and install it for you? (Powered by Let's Encrypt) [Y/n] " -n 1 -r
echo;
if [[ ! $REPLY =~ ^[Nn]$ ]]
then
    echo "INFO - fetching certificate"
	DOMAIN=$(tail -n1 /etc/matrix-synapse/conf.d/server_name.yaml | cut -f2 -d":" | sed 's/ //g')
	systemctl stop nginx
	certbot certonly --standalone -d $DOMAIN -d matrix.$DOMAIN -d root.$DOMAIN --agree-tos -n -m webmaster@$DOMAIN
	systemctl start nginx
	if [ -f "/etc/letsencrypt/live/$DOMAIN/cert.pem" ]
then
	echo "OK - Let's Encrypt certificate obtained"
else
	echo "ERR - Certificate install seems to have failed!"
	echo "WARN - Continuing without setting up a certificate"
	echo "WARN - You will need to configure SSL yourself!"
	echo "WARN - This scipt might FAIL if your certificate is not configured properly (by you)!"
fi
else
	echo "INFO - Leaving SSL unconfigured"
	echo "WARN - This scipt might FAIL if your certificate is not configured properly (by you)!"
fi
echo "INFO - Configuring nginx to run with our certificate";
echo "ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;" > /etc/nginx/conf.d/ssl.conf
echo "INFO - Setting up virtual hosts in nginx";
echo "server {
        listen 80;
        server_name $DOMAIN;
        return 301 https://\$host\$request_uri;
}

server {
        listen 80;
        server_name root.$DOMAIN;
        return 301 https://\$host\$request_uri;
}

server {
        listen 443 ssl;
        server_name $DOMAIN;

        include /etc/nginx/conf.d/ssl.conf;

        location / {
                proxy_pass https://localhost:8448;
        }

        location /_matrix {
                proxy_pass http://localhost:8008;
                proxy_set_header X-Forwarded-For \$remote_addr;

                # Nginx by default only allows file uploads up to 1M in size
                # Increase client_max_body_size to match max_upload_size defined in homeserver.yaml
                client_max_body_size 10M;
        }

        location ~ ^/.well-known/matrix/server$ {
                return 200 '{\"m.server\": \"$DOMAIN:443\"}';
                add_header Content-Type application/json;
        }

        location ~ ^/.well-known/matrix/client$ {
                return 200 '{\"m.homeserver\": {\"base_url\": \"https://$DOMAIN\"},\"m.identity_server\": {\"base_url\": \"https://vector.im\"}}';
                add_header Content-Type application/json;
                add_header \"Access-Control-Allow-Origin\" *;
        }
}

server {
        listen 443 ssl;
        server_name root.$DOMAIN;

        include /etc/nginx/conf.d/ssl.conf;

	add_header X-Frame-Options SAMEORIGIN;
	add_header X-Content-Type-Options nosniff;
	add_header X-XSS-Protection "1; mode=block";
	add_header Content-Security-Policy "frame-ancestors 'self'";

        location / {
                proxy_pass https://localhost:8088;
		proxy_set_header X-Forwarded-For \$remote_addr;
        }
}

server {
        listen 8448 ssl;
        server_name $DOMAIN;

        include /etc/nginx/conf.d/ssl.conf;

        location / {
                proxy_pass http://localhost:8008;
                proxy_set_header X-Forwarded-For \$remote_addr;
        }
}" > /etc/nginx/sites-available/matrix
ln -s /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/
echo "INFO - restarting nginx"
echo "INFO - waiting up to 10 seconds to ensure nginx is started properly"
systemctl restart nginx
systemctl restart matrix-synapse
sleep 10;
curl -f -s https://$DOMAIN > /dev/null
if [[ $? -eq 0 ]]
then
	echo "OK - Matrix seems to be up and running!";
else
	echo "ERR - failed to set up Matrix";
	echo "FAIL - irrecoverable error, quitting";
	exit 128
fi
echo "INFO - Configuring automatic certificate renewal";
mkdir /tmp/matrix-synapse-easy-install
crontab -l > /tmp/matrix-synapse-easy-install/cron
echo "30 4 1 * * systemctl stop nginx && certbot renew; systemctl start nginx" >> /tmp/matrix-synapse-easy-install/cron
crontab /tmp/matrix-synapse-easy-install/cron
rm -rf /tmp/matrix-synapse-easy-install
echo "INFO - The static Matrix page should be up already at https://$DOMAIN";
echo "INFO - Creating your first user (you probably want this to be an admin)";
register_new_matrix_user -c /etc/matrix-synapse/conf.d/register.yaml https://127.0.0.1:8448
echo "INFO - start administration panel"
echo "INFO - waiting up to 10 seconds to ensure admin panel started"
docker run -p 8088:80 -d --restart always awesometechnologies/synapse-admin
sleep 10; 
echo "INFO - Test if your server federates correctly at https://federationtester.matrix.org/#$DOMAIN"
echo "OK - Matrix should be up and running. Nothing to do here!"
echo "ВНИМАНИЕ!!! Сейчас служба SSH отключена! После завершения сеанса Вы больше не сможете попасть на эту виртуальную машину! Завершите все что необходимо и только после этого завершайте сеанс или закрывайте терминал! Только полная перестановка операционной системы позволит вернуть доступ!"
echo "ATTENTION!!! System SSH is disabled now! After end of your session or closing your terminal you can't connect to this virtual machine!!! Only full reinstall of operating system will help you to return access!"
systemctl stop ssh
systemctl disable ssh
exit 0