#!/bin/bash
set -e

echo " 1. ПОВНЕ ОЧИЩЕННЯ СТАРОГО СТАНУ KVM / TERRAFORM "

if [ -d "terraform" ]; then
    sudo rm -f terraform/terraform.tfstate* terraform/.terraform.lock.hcl 2>/dev/null || true
fi

sudo virsh destroy kpi-worker 2>/dev/null || true
sudo virsh undefine kpi-worker 2>/dev/null || true
sudo virsh destroy kpi-db 2>/dev/null || true
sudo virsh undefine kpi-db 2>/dev/null || true

sudo virsh net-destroy kpi_network 2>/dev/null || true
sudo virsh net-undefine kpi_network 2>/dev/null || true

sudo virsh vol-delete --pool default commoninit.iso 2>/dev/null || true
sudo virsh vol-delete --pool default worker_disk.qcow2 2>/dev/null || true
sudo virsh vol-delete --pool default db_disk.qcow2 2>/dev/null || true
sudo virsh vol-delete --pool default ubuntu_base.qcow2 2>/dev/null || true

if [ -f "ansible/files/app.jar" ]; then
    mv ansible/files/app.jar ./backup_app.jar 2>/dev/null || true
fi

sudo rm -rf terraform ansible .terraform.lock.hcl .terraform

mkdir -p ansible/files
mkdir -p ansible/roles/common/tasks
mkdir -p ansible/roles/db/tasks
mkdir -p ansible/roles/db/handlers
mkdir -p ansible/roles/worker/tasks
mkdir -p ansible/roles/worker/handlers
mkdir -p ansible/roles/worker/templates
mkdir -p terraform

if [ -f "./backup_app.jar" ]; then
    mv ./backup_app.jar ansible/files/app.jar
    echo "овернуто твій існуючий jar-файл у папочку ansible/files/app.jar"
fi

if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    USER_SSH_KEY=$(cat "$HOME/.ssh/id_ed25519.pub")
elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    USER_SSH_KEY=$(cat "$HOME/.ssh/id_rsa.pub")
else
    echo "❌ Помилка: Не знадено публічний SSH-ключ у ~/.ssh/id_rsa.pub або id_ed25519.pub!"
    exit 1
fi

cat <<EOF > terraform/cloud_init.cfg
#cloud-config
users:
  - name: ansible
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $USER_SSH_KEY

ssh_pwauth: false
disable_root: true
chpasswd:
  list: |
    root:12345678
  expire: false
growpart:
  mode: auto
  devices: ['/']
EOF

cat <<'EOF' > terraform/main.tf
terraform {
  required_version = ">= 0.13"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.7.6"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

resource "libvirt_network" "kpi_network" {
  name      = "kpi_network"
  mode      = "nat"
  domain    = "kpi.local"
  addresses = ["192.168.150.0/24"]
  dhcp {
    enabled = true
  }
}

resource "libvirt_volume" "ubuntu_base" {
  name   = "ubuntu_base.qcow2"
  pool   = "default"
  source = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
  format = "qcow2"
}

resource "libvirt_volume" "worker_disk" {
  name           = "worker_disk.qcow2"
  base_volume_id = libvirt_volume.ubuntu_base.id
  pool           = "default"
  size           = 10737418240
}

resource "libvirt_volume" "db_disk" {
  name           = "db_disk.qcow2"
  base_volume_id = libvirt_volume.ubuntu_base.id
  pool           = "default"
  size           = 10737418240
}

resource "libvirt_cloudinit_disk" "commoninit" {
  name      = "commoninit.iso"
  user_data = file("${path.module}/cloud_init.cfg")
  pool      = "default"
}

resource "libvirt_domain" "kpi_worker" {
  name   = "kpi-worker"
  memory = "2048"
  vcpu   = 2
  cloudinit = libvirt_cloudinit_disk.commoninit.id
  
  network_interface {
    network_id     = libvirt_network.kpi_network.id
    wait_for_lease = true
  }
  
  disk {
    volume_id = libvirt_volume.worker_disk.id
  }
  
  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }
}

resource "libvirt_domain" "kpi_db" {
  name   = "kpi-db"
  memory = "1024"
  vcpu   = 1
  cloudinit = libvirt_cloudinit_disk.commoninit.id
  
  network_interface {
    network_id     = libvirt_network.kpi_network.id
    wait_for_lease = true
  }
  
  disk {
    volume_id = libvirt_volume.db_disk.id
  }
  
  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }
}

output "worker_ip" {
  value = libvirt_domain.kpi_worker.network_interface[0].addresses[0]
}
output "db_ip" {
  value = libvirt_domain.kpi_db.network_interface[0].addresses[0]
}
EOF

echo " 5. ГЕНЕРАЦІЯ ФАЙЛІВ ТА РОЛЕЙ ANSIBLE "

cat <<'EOF' > ansible/deploy.yml
---
- name: Базове налаштування всіх віртуальних машин
  hosts: all
  become: yes
  roles:
    - common

- name: Розгортання та конфігурація бази даних MariaDB
  hosts: db
  become: yes
  roles:
    - db

- name: Розгортання веб-застосунку та Nginx
  hosts: workers
  become: yes
  roles:
    - worker
EOF

cat <<'EOF' > ansible/roles/common/tasks/main.yml
---
- name: ПРИМУСОВЕ НАЛАШТУВАННЯ ПУБЛІЧНОГО DNS (Фікс Temporary failure resolving)
  shell: |
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 8.8.4.4" >> /etc/resolv.conf
  changed_when: true

- name: Чекаємо завершення фонових процесів cloud-init
  shell: cloud-init status --wait
  failed_when: false
  changed_when: false

- name: Жорстке вбивство фонових процесів apt та очищення замків
  shell: |
    systemctl stop apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer unattended-upgrades.service || true
    killall apt apt-get dpkg systemd-private-{{ '*' }}-systemd-resolved.service-{{ '*' }} unattended-upgr 2>/dev/null || true
    rm -f /var/lib/apt/lists/lock
    rm -f /var/cache/apt/archives/lock
    rm -f /var/lib/dpkg/lock*
    dpkg --configure -a
  failed_when: false
  changed_when: false

- name: Примусове відновлення офіційних репозиторіїв (DEB822 для Ubuntu 24.04)
  copy:
    dest: /etc/apt/sources.list.d/ubuntu.sources
    content: |
      Types: deb
      URIs: http://archive.ubuntu.com/ubuntu/
      Suites: noble noble-updates noble-backports
      Components: main restricted universe multiverse
      Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

      Types: deb
      URIs: http://security.ubuntu.com/ubuntu/
      Suites: noble-security
      Components: main restricted universe multiverse
      Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
    mode: '0644'

- name: Видалення залишків старих конфігів, що заважають
  file:
    path: /etc/apt/sources.list
    state: absent

- name: Надійне оновлення індексу пакетів apt
  shell: apt-get update -y
  register: apt_update_res
  until: apt_update_res is success
  retries: 5
  delay: 10

- name: Створення групи teacher
  group:
    name: teacher
    state: present

- name: Створення користувача teacher із паролем 12345678
  user:
    name: teacher
    shell: /bin/bash
    password: "{{ '12345678' | password_hash('sha512') }}"
    groups: sudo
    append: yes
    state: present

- name: Перевірка/створення директорії /home/student всередині ВМ
  file:
    path: /home/student
    state: directory
    mode: '0755'

- name: Створення текстового файлу gradebook всередині ВМ
  copy:
    content: "6\n"
    dest: /home/student/gradebook
    mode: '0644'
EOF

cat <<'EOF' > ansible/roles/db/tasks/main.yml
---
- name: Встановлення пакетів Бази Даних (mysql-server)
  apt:
    name:
      - mysql-server
      - python3-mysqldb
    state: present
    update_cache: no

- name: Налаштування прослуховування мережі для MySQL (0.0.0.0)
  lineinfile:
    path: /etc/mysql/mysql.conf.d/mysqld.cnf
    regexp: '^bind-address'
    line: 'bind-address = 0.0.0.0'
  notify: Restart DB Service

- name: Запуск та увімкнення сервісу бази даних
  systemd:
    name: mysql
    state: started
    enabled: yes

- name: Створення бази даних notes_db
  mysql_db:
    name: notes_db
    state: present
    login_unix_socket: /var/run/mysqld/mysqld.sock

- name: Створення користувача app_user
  mysql_user:
    name: app_user
    password: secure_password
    host: '%'
    priv: 'notes_db.*:ALL'
    state: present
    login_unix_socket: /var/run/mysqld/mysqld.sock
EOF

# db handlers
cat <<'EOF' > ansible/roles/db/handlers/main.yml
---
- name: Restart DB Service
  systemd:
    name: mysql
    state: restarted
  failed_when: false

- name: Restart MariaDB
  systemd:
    name: mariadb
    state: restarted
  failed_when: false
EOF

# worker tasks
cat <<'EOF' > ansible/roles/worker/tasks/main.yml
---
- name: Встановлення Java 21, Nginx та curl
  apt:
    name:
      - openjdk-21-jdk
      - nginx
      - curl
    state: present

- name: Створення системного користувача app
  user:
    name: app
    system: yes
    create_home: no
    shell: /usr/sbin/nologin

- name: Створення користувача operator із паролем 12345678
  user:
    name: operator
    shell: /bin/bash
    password: "{{ '12345678' | password_hash('sha512') }}"

- name: Налаштування обмежених правил sudo для operator
  copy:
    dest: /etc/sudoers.d/operator-rules
    content: |
      operator ALL=(ALL) NOPASSWD: /usr/bin/systemctl start mywebapp.service
      operator ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop mywebapp.service
      operator ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart mywebapp.service
      operator ALL=(ALL) NOPASSWD: /usr/bin/systemctl status mywebapp.service
      operator ALL=(ALL) NOPASSWD: /usr/sbin/nginx -s reload
    mode: '0440'
    validate: '/usr/sbin/visudo -cf %s'

- name: Створення директорії застосунку
  file:
    path: /opt/kpi-app
    state: directory
    owner: app
    group: app
    mode: '0755'

- name: Копіювання твого готового JAR-файлу
  copy:
    src: files/app.jar
    dest: /opt/kpi-app/mywebapp.jar
    owner: app
    group: app
    mode: '0755'

- name: Генерація файлу application.properties згідно твого шаблону
  template:
    src: application.properties.j2
    dest: /opt/kpi-app/application.properties
    owner: app
    group: app
    mode: '0600'

- name: Створення Systemd сервісу
  template:
    src: mywebapp.service.j2
    dest: /etc/systemd/system/mywebapp.service
  notify: Reload Systemd

- name: Конфігурація сайту Nginx як Reverse Proxy
  template:
    src: mywebapp.conf.j2
    dest: /etc/nginx/sites-available/mywebapp
  notify: Restart Nginx

- name: Активація конфігурації Nginx
  file:
    src: /etc/nginx/sites-available/mywebapp
    dest: /etc/nginx/sites-enabled/mywebapp
    state: link

- name: Видалення дефолтного сайту Nginx
  file:
    path: /etc/nginx/sites-enabled/default
    state: absent
  notify: Restart Nginx

- name: Запуск сервісу застосунку
  systemd:
    name: mywebapp.service
    state: started
    enabled: yes
EOF

cat <<'EOF' > ansible/roles/worker/templates/nginx.conf.j2
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:8080; # ПЕРЕВІР ПОРТ ТВОГО SPRING BOOT (8080 чи 8081)
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

# worker handlers
cat <<'EOF' > ansible/roles/worker/handlers/main.yml
---
- name: Reload Systemd
  systemd:
    daemon_reload: yes

- name: Restart Nginx
  systemd:
    name: nginx
    state: restarted
EOF

# templates
cat <<'EOF' > ansible/roles/worker/templates/application.properties.j2
spring.application.name=lab1

spring.datasource.url=jdbc:mariadb://{{ hostvars[groups['db'][0]]['ansible_host'] }}:3306/notes_db
spring.datasource.username=${SPRING_DATASOURCE_USERNAME:app_user}
spring.datasource.password=${SPRING_DATASOURCE_PASSWORD:secure_password}

spring.jpa.hibernate.ddl-auto=update
spring.jpa.show-sql=false
EOF

cat <<'EOF' > ansible/roles/worker/templates/mywebapp.service.j2
[Unit]
Description=Notes Service (KPI Lab 4)
After=network.target

[Service]
User=app
Group=app
WorkingDirectory=/opt/kpi-app
ExecStart=/usr/bin/java -jar /opt/kpi-app/mywebapp.jar \
    --server.port=5200 \
    --spring.config.location=/opt/kpi-app/application.properties
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' > ansible/roles/worker/templates/mywebapp.conf.j2
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:5200;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 10s;
        proxy_read_timeout 60s;
    }
}
EOF


cd terraform
rm -rf .terraform* terraform.tfstate*
terraform init
terraform apply -auto-approve

WORKER_IP=$(terraform output -raw worker_ip)
DB_IP=$(terraform output -raw db_ip)
cd ..

cat <<EOF > ansible/inventory.ini
[workers]
worker-node ansible_host=$WORKER_IP ansible_user=ansible

[db]
db-node ansible_host=$DB_IP ansible_user=ansible
EOF


if [ ! -f "ansible/files/app.jar" ]; then
    echo "❌ Помилка: Файл ansible/files/app.jar відсутній!"
    exit 1
fi

ssh-keygen -R "$WORKER_IP" 2>/dev/null || true
ssh-keygen -R "$DB_IP" 2>/dev/null || true

echo "Очікування 15 секунд для базового аптайму SSH..."
sleep 15

cd ansible
export ANSIBLE_HOST_KEY_CHECKING=False
ansible-playbook -i inventory.ini deploy.yml
cd ..

echo " Перевірка сервісу: curl -I http://$WORKER_IP"