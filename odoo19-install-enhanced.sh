#!/bin/bash

OE_USER="odoo"
OE_HOME="/$OE_USER"
OE_HOME_EXT="/$OE_USER/${OE_USER}-server"
INSTALL_WKHTMLTOPDF="True"
OE_PORT="8069"
OE_VERSION="19.0"
IS_ENTERPRISE="False"
INSTALL_POSTGRESQL_SIXTEEN="True"
INSTALL_NGINX="False"
OE_SUPERADMIN="admin"
GENERATE_RANDOM_PASSWORD="True"
# Set PostgreSQL password (change this!)
POSTGRES_PASSWORD="Odoo2025SecurePass!"
OE_CONFIG="${OE_USER}-server"
WEBSITE_NAME="_"
LONGPOLLING_PORT="8072"
ENABLE_SSL="False"
ADMIN_EMAIL="odoo@example.com"

# Helper: pip install with optional --break-system-packages (Ubuntu 24.04 / PEP 668)
pip_install() {
  if pip3 help install 2>/dev/null | grep -q -- '--break-system-packages'; then
    sudo -H pip3 install --break-system-packages "$@"
  else
    sudo -H pip3 install "$@"
  fi
}

# WKHTMLTOPDF download links
if [[ $(lsb_release -r -s) == "24.04" ]]; then
    WKHTMLTOX_X64="https://packages.ubuntu.com/jammy/wkhtmltopdf"
    WKHTMLTOX_X32="https://packages.ubuntu.com/jammy/wkhtmltopdf"
else
    WKHTMLTOX_X64="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.$(lsb_release -c -s)_amd64.deb"
    WKHTMLTOX_X32="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.$(lsb_release -c -s)_i386.deb"
fi

#--------------------------------------------------
# Update Server
#--------------------------------------------------
echo -e "\n---- Update Server ----"
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y libpq-dev

#--------------------------------------------------
# Install PostgreSQL Server
#--------------------------------------------------
echo -e "\n---- Install PostgreSQL Server ----"
if [ "$INSTALL_POSTGRESQL_SIXTEEN" = "True" ]; then
    echo -e "\n---- Installing postgreSQL V16 ----"
    sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc|sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
    sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    sudo apt-get update -y
    sudo apt-get install -y postgresql-16
    if [ "$IS_ENTERPRISE" = "True" ]; then
      sudo systemctl start postgresql || true
      sudo apt-get install -y postgresql-16-pgvector
      until sudo -u postgres pg_isready >/dev/null 2>&1; do sleep 1; done
      sudo -u postgres psql -v ON_ERROR_STOP=1 -d template1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SQL
    fi
else
    echo -e "\n---- Installing the default postgreSQL version ----"
    sudo apt-get install postgresql postgresql-server-dev-all -y
fi

echo -e "\n---- Creating the ODOO PostgreSQL User ----"
sudo su - postgres -c "createuser -s $OE_USER" 2> /dev/null || true

echo -e "\n---- Setting PostgreSQL password for Odoo user ----"
sudo -u postgres psql -c "ALTER USER $OE_USER WITH PASSWORD '$POSTGRES_PASSWORD';"

echo -e "\n---- Configuring PostgreSQL authentication (peer -> md5) ----"
PG_VERSION=$(ls /etc/postgresql/ | head -n 1)
PG_HBA_CONF="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
sudo sed -i 's/local\s*all\s*all\s*peer/local   all             all                                     md5/' $PG_HBA_CONF
sudo systemctl restart postgresql

#--------------------------------------------------
# Install Dependencies
#--------------------------------------------------
echo -e "\n--- Installing Python 3 + pip3 --"
sudo apt-get install -y python3 python3-pip
sudo apt-get install git python3-cffi build-essential wget python3-dev python3-venv python3-wheel libxslt-dev libzip-dev libldap2-dev libsasl2-dev python3-setuptools node-less libpng-dev libjpeg-dev gdebi -y

echo -e "\n---- Install python packages/requirements ----"
pip_install -r https://github.com/odoo/odoo/raw/${OE_VERSION}/requirements.txt

# CRITICAL: Install missing dependencies that are NOT in requirements.txt
echo -e "\n---- Installing additional required packages ----"
pip_install phonenumbers beautifulsoup4 lxml

echo -e "\n---- Installing nodeJS NPM and rtlcss for LTR support ----"
sudo apt-get install nodejs npm -y
sudo npm install -g rtlcss

#--------------------------------------------------
# Install Wkhtmltopdf if needed
#--------------------------------------------------
if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
  echo -e "\n---- Install wkhtml ----"
  if [ "`getconf LONG_BIT`" == "64" ];then
      _url=$WKHTMLTOX_X64
  else
      _url=$WKHTMLTOX_X32
  fi

  if [[ $(lsb_release -r -s) == "24.04" ]]; then
    sudo apt install wkhtmltopdf -y
  else
    sudo wget $_url
    sudo gdebi --n `basename $_url`
  fi

  sudo ln -s /usr/local/bin/wkhtmltopdf /usr/bin 2>/dev/null || true
  sudo ln -s /usr/local/bin/wkhtmltoimage /usr/bin 2>/dev/null || true
else
  echo "Wkhtmltopdf isn't installed due to the choice of the user!"
fi

echo -e "\n---- Create ODOO system user ----"
sudo adduser --system --quiet --shell=/bin/bash --home=$OE_HOME --gecos 'ODOO' --group $OE_USER
sudo adduser $OE_USER sudo

echo -e "\n---- Create Log directory ----"
sudo mkdir -p /var/log/$OE_USER
sudo chown $OE_USER:$OE_USER /var/log/$OE_USER

echo -e "\n---- Create data directory ----"
sudo mkdir -p /var/lib/$OE_USER
sudo chown $OE_USER:$OE_USER /var/lib/$OE_USER

#--------------------------------------------------
# Install ODOO
#--------------------------------------------------
echo -e "\n==== Installing ODOO Server ===="
sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/odoo $OE_HOME_EXT/

if [ $IS_ENTERPRISE = "True" ]; then
    pip_install psycopg2-binary pdfminer.six
    sudo su $OE_USER -c "mkdir -p $OE_HOME/enterprise/addons"

    GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
    while [[ $GITHUB_RESPONSE == *"Authentication"* ]]; do
        echo "------------------------WARNING------------------------------"
        echo "Your authentication with Github has failed! Please try again."
        echo "-------------------------------------------------------------"
        GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
    done

    echo -e "\n---- Installing Enterprise specific libraries ----"
    pip_install num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL
    sudo npm install -g less less-plugin-clean-css
fi

echo -e "\n---- Create custom module directory ----"
sudo su $OE_USER -c "mkdir -p $OE_HOME/custom/addons"

echo -e "\n---- Setting permissions on home folder ----"
sudo chown -R $OE_USER:$OE_USER $OE_HOME/*

#--------------------------------------------------
# Create Enhanced Config File
#--------------------------------------------------
echo -e "\n---- Creating enhanced server config file ----"

sudo touch /etc/${OE_CONFIG}.conf

if [ $GENERATE_RANDOM_PASSWORD = "True" ]; then
    echo -e "* Generating random admin password"
    OE_SUPERADMIN=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
fi

# Calculate workers based on CPU cores
CPU_CORES=$(nproc)
WORKERS=$((CPU_CORES * 2 + 1))

cat <<EOF | sudo tee /etc/${OE_CONFIG}.conf
[options]
# ==================== ADMIN & SECURITY ====================
admin_passwd = ${OE_SUPERADMIN}

# ==================== DATABASE CONNECTION ====================
db_host = localhost
db_port = 5432
db_user = ${OE_USER}
db_password = ${POSTGRES_PASSWORD}
db_maxconn = 64
db_template = template0

# ==================== NETWORK & PORTS ====================
http_port = ${OE_PORT}
xmlrpc_port = ${OE_PORT}
longpolling_port = ${LONGPOLLING_PORT}
proxy_mode = False

# ==================== FILE PATHS ====================
addons_path = ${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons
data_dir = /var/lib/${OE_USER}

# ==================== LOGGING ====================
logfile = /var/log/${OE_USER}/${OE_CONFIG}.log
log_level = info
log_handler = :INFO
logrotate = True

# ==================== PERFORMANCE & WORKERS ====================
workers = ${WORKERS}
max_cron_threads = 2
limit_memory_soft = 671088640
limit_memory_hard = 805306368
limit_time_cpu = 600
limit_time_real = 1200
limit_time_real_cron = 300
limit_request = 8192

# ==================== SESSION & SECURITY ====================
list_db = True

# ==================== DEMO DATA ====================
without_demo = all

# ==================== SERVER WIDE MODULES ====================
server_wide_modules = base,web
EOF

if [ $IS_ENTERPRISE = "True" ]; then
    sudo sed -i "s|addons_path = ${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons|addons_path = ${OE_HOME}/enterprise/addons,${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons|" /etc/${OE_CONFIG}.conf
fi

sudo chown $OE_USER:$OE_USER /etc/${OE_CONFIG}.conf
sudo chmod 640 /etc/${OE_CONFIG}.conf

echo -e "\n---- Create startup file ----"
cat <<EOF | sudo tee $OE_HOME_EXT/start.sh
#!/bin/sh
sudo -u $OE_USER $OE_HOME_EXT/odoo-bin --config=/etc/${OE_CONFIG}.conf
EOF
sudo chmod 755 $OE_HOME_EXT/start.sh

#--------------------------------------------------
# Adding ODOO as a deamon (systemd service)
#--------------------------------------------------
echo -e "\n---- Create systemd service file ----"
cat <<EOF | sudo tee /etc/systemd/system/${OE_CONFIG}.service
[Unit]
Description=Odoo 19
Documentation=https://www.odoo.com
After=network.target postgresql.service

[Service]
Type=simple
User=${OE_USER}
ExecStart=${OE_HOME_EXT}/odoo-bin -c /etc/${OE_CONFIG}.conf
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ${OE_CONFIG}.service

#--------------------------------------------------
# Install Nginx if needed
#--------------------------------------------------
if [ $INSTALL_NGINX = "True" ]; then
  echo -e "\n---- Installing and setting up Nginx ----"
  sudo apt-get install -y nginx
  cat <<EOF | sudo tee /etc/nginx/sites-available/${WEBSITE_NAME}
server {
  listen 80;
  server_name ${WEBSITE_NAME};

  proxy_set_header X-Forwarded-Host \$host;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_set_header X-Real-IP \$remote_addr;
  add_header X-Frame-Options "SAMEORIGIN";
  add_header X-XSS-Protection "1; mode=block";

  access_log  /var/log/nginx/${OE_USER}-access.log;
  error_log   /var/log/nginx/${OE_USER}-error.log;

  proxy_buffers   16  64k;
  proxy_buffer_size   128k;
  proxy_read_timeout 900s;
  proxy_connect_timeout 900s;
  proxy_send_timeout 900s;
  proxy_next_upstream error timeout invalid_header http_500 http_502 http_503;

  gzip on;
  gzip_min_length 1100;
  gzip_buffers 4 32k;
  gzip_types text/css text/less text/plain text/xml application/xml application/json application/javascript application/pdf image/jpeg image/png;
  gzip_vary on;

  client_header_buffer_size 4k;
  large_client_header_buffers 4 64k;
  client_max_body_size 0;

  location / {
    proxy_pass http://127.0.0.1:${OE_PORT};
    proxy_redirect off;
  }

  location /longpolling {
    proxy_pass http://127.0.0.1:${LONGPOLLING_PORT};
  }

  location ~* \.(js|css|png|jpg|jpeg|gif|ico)$ {
    expires 2d;
    proxy_pass http://127.0.0.1:${OE_PORT};
    add_header Cache-Control "public, no-transform";
  }

  location ~ /[a-zA-Z0-9_-]*/static/ {
    proxy_cache_valid 200 302 60m;
    proxy_cache_valid 404 1m;
    proxy_buffering on;
    expires 864000;
    proxy_pass http://127.0.0.1:${OE_PORT};
  }
}
EOF

  sudo ln -s /etc/nginx/sites-available/${WEBSITE_NAME} /etc/nginx/sites-enabled/${WEBSITE_NAME}
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo systemctl reload nginx
  sudo sed -i "s/proxy_mode = False/proxy_mode = True/" /etc/${OE_CONFIG}.conf
  echo "Nginx is up and running!"
else
  echo "Nginx isn't installed due to choice of the user!"
fi

#--------------------------------------------------
# Enable SSL with certbot
#--------------------------------------------------
if [ $INSTALL_NGINX = "True" ] && [ $ENABLE_SSL = "True" ] && [ $ADMIN_EMAIL != "odoo@example.com" ] && [ $WEBSITE_NAME != "_" ]; then
  sudo apt-get update -y
  sudo apt-get install -y snapd
  sudo snap install core; sudo snap refresh core
  sudo snap install --classic certbot
  sudo apt-get install python3-certbot-nginx -y
  sudo certbot --nginx -d $WEBSITE_NAME --noninteractive --agree-tos --email $ADMIN_EMAIL --redirect
  sudo systemctl reload nginx
  echo "SSL/HTTPS is enabled!"
else
  echo "SSL/HTTPS isn't enabled"
fi

#--------------------------------------------------
# Start Odoo
#--------------------------------------------------
echo -e "\n---- Starting Odoo Service ----"
sudo systemctl start ${OE_CONFIG}.service

echo "-----------------------------------------------------------"
echo "Done! The Odoo server is up and running. Specifications:"
echo "Port: $OE_PORT"
echo "User service: $OE_USER"
echo "Configuration file: /etc/${OE_CONFIG}.conf"
echo "Logfile: /var/log/$OE_USER/${OE_CONFIG}.log"
echo "PostgreSQL User: $OE_USER"
echo "PostgreSQL Password: $POSTGRES_PASSWORD"
echo "Code location: $OE_HOME_EXT"
echo "Addons folder: $OE_HOME_EXT/addons & $OE_HOME/custom/addons"
echo "Master Password: $OE_SUPERADMIN"
echo ""
echo "Start Odoo: sudo systemctl start $OE_CONFIG"
echo "Stop Odoo: sudo systemctl stop $OE_CONFIG"
echo "Restart Odoo: sudo systemctl restart $OE_CONFIG"
echo "Status: sudo systemctl status $OE_CONFIG"
echo ""
echo "To upgrade modules from command line:"
echo "sudo su - $OE_USER"
echo "cd $OE_HOME_EXT"
echo "./odoo-bin -c /etc/${OE_CONFIG}.conf -d YOUR_DB -u MODULE_NAME --stop-after-init"
echo "-----------------------------------------------------------"
