# OpenVAS / Greenbone Community Edition  
**Quick Start Guide**

---

### Overview
This repository contains a quick-start reference for the OpenVAS / Greenbone Community Edition stack deployed with Docker Compose. It covers how to access the web UI, default credentials, important post-deploy steps, management commands, scheduled maintenance, backups, and known deploy behaviors for technicians.

---

### Accessing the Web Interface
- **Local (on this machine):** `https://127.0.0.1/login`  
- **Network (from other PCs):** `https://<OpenVas.IP.Address.Here>/login`

You will see a certificate warning — this is expected. The certificate is self-signed. Click **Advanced → Accept the Risk and Continue** to proceed.

---

### Login Credentials
- **Username:** `admin`  
- **Password:** *See credential vault — do not store here.*

The admin password is set at deploy time via the `ADMIN_PASSWORD` environment variable. To change it in the web UI: **Administration → Users → admin → Edit**.

---

### Important — After a Fresh Deploy
1. **NVT feed and scan tasks**  
   - Scan tasks are created automatically once the NVT vulnerability feed finishes loading (typically **30–90 minutes**). A background cron retries every 5 minutes for up to 8 hours.
   - **Monitor progress:**  
     ```bash
     sudo tail -f /var/log/openvas-task-import.log
     ```
   - **Check feed status:** Scans → Feed Status (in the web UI)

2. **Scan credentials placeholder**  
   - If `SMB_CREDENTIAL_PASSWORD` was not set before deploy, scan credentials are created with a **PLACEHOLDER** password. Update them in the web UI: **Configuration → Credentials**.

3. **Deploy log**  
   - Deploy log location: `/var/log/openvas-deploy.log`  
   - If the deploy took longer than expected, check this file for warnings.

---

### Managing the Stack
Use the Docker Compose file at `~/greenbone-community-container/docker-compose.yml`.

- **Start**
```bash
sudo docker compose -f ~/greenbone-community-container/docker-compose.yml up -d
```
- **Stop**
```bash
sudo docker compose -f ~/greenbone-community-container/docker-compose.yml down
```
- **Status**
```bash
sudo docker compose -f ~/greenbone-community-container/docker-compose.yml ps
```
- **Follow logs**
```bash
sudo docker compose -f ~/greenbone-community-container/docker-compose.yml logs -f
```

---

### Automatic Maintenance (Cron)
**Scheduled jobs**
- **01:00 AM** — OpenVAS backup (database + volumes + scan reports → `/var/backups/openvas/`)  
- **02:00 AM** — OpenVAS update (pulls latest container images)  
- **03:00 AM** — System update (apt upgrade, no reboot)  
- **Every 5 minutes** — Health check (auto-restarts unhealthy containers)

**Manual runs**
```bash
sudo /usr/local/bin/openvas-backup.sh
sudo /usr/local/bin/openvas-maintain.sh health
sudo /usr/local/bin/openvas-maintain.sh update
sudo /usr/local/bin/auto-update.sh
```

**Maintenance logs**
- `/var/log/openvas-backup.log`  
- `/var/log/openvas-maintain.log`  
- `/var/log/openvas-task-import.log`  
- `/var/log/auto-update.log`

---

### Firewall
- **UFW** is active with default-deny inbound.  
- **Allowed inbound:** SSH (22), HTTPS (443)  
- **Check status**
```bash
sudo ufw status verbose
```

---

### Backups
- **Location:** `/var/backups/openvas/`  
- **Schedule:** Daily at 01:00 AM  
- **Retention:** 14 days  
- **Contents:** PostgreSQL dump (gvmd), configuration volumes, SSL cert, scan reports as portable XML (in `reports/`)

Report XML files can be viewed in any text editor or re-imported into a fresh GVM instance via GMP `<create_report/>`.

**Restore database example**
```bash
sudo docker compose -f ~/greenbone-community-container/docker-compose.yml \
  exec -T -u postgres pg-gvm psql -c "DROP DATABASE gvmd;"

sudo docker compose -f ~/greenbone-community-container/docker-compose.yml \
  exec -T -u postgres pg-gvm pg_restore -Fc -d gvmd < /path/to/gvmd.pgdump
```

---

### Deploy Script — Known Behaviors (for technicians)
- **Duration:** The deploy script (`deploy-openvas.sh`) typically takes **90–120 minutes** on a fresh system. Most time is spent pulling images and loading vulnerability feeds.

#### GVMD password race condition
- `gvmd` must load all vulnerability tests before accepting password changes. The deploy script waits up to 15 minutes for this. If it times out you may see:
  ```
  ! Could not set admin password automatically
  ```
- **Manual fix**
```bash
sudo docker compose -f ~/greenbone-community-container/docker-compose.yml \
  exec -u gvmd gvmd gvmd --user=admin --new-password='YOUR_PASSWORD'
```
- **Re-import after fix**
```bash
sudo GVM_COMPOSE_FILE=~/greenbone-community-container/docker-compose.yml \
     GVM_ADMIN_PASS='YOUR_PASSWORD' \
     GVM_CONFIG_INPUT=/var/backups/openvas/scan-config-backup.json \
     python3 /usr/local/bin/gvm-reimport.py
```

#### Scan tasks deferred
- If the NVT feed is not loaded when deploy finishes, scan tasks are deferred. A cron job retries every 5 minutes for up to 8 hours and will create them automatically.
- **Monitor**
```bash
sudo tail -f /var/log/openvas-task-import.log
```

#### Image pull failures
- The deploy script retries each image up to 5 times with a short delay to handle transient network issues.

#### SCAP-data unhealthy
- On first stack start, `scap-data` can briefly appear unhealthy. The script runs a second `docker compose up` automatically to recover.

---

### Useful Logs and Paths
- **Deploy log:** `/var/log/openvas-deploy.log`  
- **Task import log:** `/var/log/openvas-task-import.log`  
- **Backup log:** `/var/log/openvas-backup.log`  
- **Maintain log:** `/var/log/openvas-maintain.log`  
- **Auto-update log:** `/var/log/auto-update.log`  
- **Backups:** `/var/backups/openvas/`  
- **Compose file:** `~/greenbone-community-container/docker-compose.yml`

---

### Troubleshooting Tips
- If the web UI is unreachable, confirm Docker Compose stack is running and check container logs.  
- If feeds are not loading, check `/var/log/openvas-task-import.log` and the web UI **Scans → Feed Status**.  
- If admin password cannot be set automatically, follow the GVMD password race condition manual fix above.

---

### Contributing and Support
If you maintain or modify the deployment scripts, please:
- Keep the `ADMIN_PASSWORD` and other secrets out of the repository. Use a secure credential vault.  
- Document any environment variables you add to the deploy process.  
- Report reproducible issues with logs and steps to reproduce.

---

### License
Include your project license here.

--- 

**End of Quick Start Guide**
