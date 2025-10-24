# **VaultWarden-OCI-NG (Simplified Edition)**

**Production-Ready VaultWarden Deployment for Small Teams**

A streamlined, secure, and operationally excellent VaultWarden deployment optimized for teams of 10 or fewer users, especially on cloud platforms like Oracle Cloud Infrastructure (OCI) with dynamic IPs. This simplified edition focuses on essential functionality, ease of maintenance, and robust security for reliable password management.

## **🎯 What Makes This Different**

This is a **significantly simplified and hardened version** designed specifically for small teams who want:

* **Set-and-forget reliability** without enterprise complexity.  
* **Essential functionality** including dynamic DNS updates.  
* **Robust Security** with Cloudflare integration, encrypted secrets, and firewall hardening.  
* **Simple maintenance** with automated backups and updates.  
* **Clear documentation** focused on practical operation.

### **Key Features & Simplifications**

* **Minimalist Footprint:** \~15 files and \~2,500 lines of code.  
* **Core Scripts:** 5 essential scripts for setup, operations, and maintenance.  
* **Unified Libraries:** 3 focused libraries for common tasks, Docker, and crypto.  
* **ddclient Integration:** Automatically updates your Cloudflare DNS record if your server's IP changes.  
* **Cloudflare Security:** Uses Cloudflare for proxying and Fail2ban integration for effective IP blocking at the edge.  
* **Firewall Hardening:** Automatically configures ufw to only allow web traffic from Cloudflare IPs, preventing direct attacks.  
* **Encrypted Secrets:** Uses age and sops for industry-standard secrets management.

## **⚡ Quick Start (Approx. 15 Minutes)**

Deploy a secure VaultWarden instance:

\# 1\. Clone the repository  
git clone \[https://github.com/your-repo/VaultWarden-OCI-NG-Simplified\](https://github.com/your-repo/VaultWarden-OCI-NG-Simplified) \# Replace with your repo URL  
cd VaultWarden-OCI-NG-Simplified  
chmod \+x \*.sh lib/\*.sh \# Ensure scripts are executable

\# 2\. Run the automated setup  
\#    Installs dependencies (Docker, etc.), generates keys, configures firewall & services.  
\#    Replace with your actual domain and email.  
sudo ./setup.sh \--domain vault.yourdomain.com \--email admin@yourdomain.com \--auto

\# 3\. Configure essential secrets  
\#    This will open an editor. You MUST set:  
\#    \- admin\_basic\_auth\_hash (Generate one: \[https://bcrypt-generator.com/\](https://bcrypt-generator.com/))  
\#    \- cloudflare\_api\_token (Scoped Token: Zone:Zone:Read, Zone:Firewall Services:Edit, Zone:DNS:Edit)  
\#    Optionally configure: smtp\_password, push\_installation\_key  
./edit-secrets.sh

\# 4\. Configure environment variables  
\#    Edit the .env file created by setup.sh. You MUST set:  
\#    \- CLOUDFLARE\_ZONE\_ID (Find on your Cloudflare dashboard)  
\#    \- DDCLIENT\_HOSTNAME (e.g., vault.yourdomain.com)  
nano .env

\# 5\. Start all services  
\#    Use \--force-restart after editing secrets or .env  
./startup.sh \--force-restart

\# 6\. Setup automation (Optional but Recommended)  
\#    Configures cron jobs for backups, updates, and health checks.  
sudo ./cron-setup.sh

\# 7\. Verify everything is working  
./health.sh \--comprehensive

**🎉 Your VaultWarden instance is now operational and secure at https://vault.yourdomain.com**

## **🏗️ Architecture**

### **Simple, Secure Stack**

 Cloudflare Edge (Proxy, WAF, DNS)  
       ↑ ↓  
 Host Firewall (UFW \- Allows only Cloudflare IPs \+ SSH)  
       ↑ ↓  
┌─────────────────────────────────────────┐  
│              Management                 │  
│  ┌───────────┐  ┌───────────┐           │  
│  │ 5 Scripts │  │ 3 Libraries ├─────────┤ Encrypted Secrets (Age \+ SOPS)  
│  │ (Ops)     │  │ (Common)  │           │  
│  └───────────┘  └───────────┘           │  
└─────────────────────────────────────────┘  
┌─────────────────────────────────────────┐  
│           Docker Application            │  
│  ┌───────┐  ┌───────────┐  ┌────────┐   │  
│  │ Caddy │→ │VaultWarden│  │ddclient│───┤ Cloudflare API (DNS Update)  
│  │(Proxy)│  │(App)      │  │(DNS)   │   │  
│  └───────┘  └───────────┘  └────────┘   │  
│      ↑                                  │  
│  ┌────────┐                             │  
│  │Fail2ban│─────────────────────────────┤ Cloudflare API (IP Ban)  
│  │(Sec.)  │                             │  
│  └────────┘                             │  
└─────────────────────────────────────────┘

### **Core Technologies**

* **VaultWarden:** Latest Bitwarden-compatible server.  
* **Caddy:** Automatic HTTPS reverse proxy.  
* **ddclient:** Dynamic DNS updates via Cloudflare API.  
* **Fail2ban:** Intrusion prevention, integrated with Cloudflare API.  
* **SQLite:** Simple, reliable database backend.  
* **Docker Compose:** Container orchestration.  
* **Age \+ SOPS:** Modern, secure secrets encryption.  
* **UFW:** Host firewall configured for Cloudflare IPs.  
* **Ubuntu 24.04 LTS:** Recommended base OS.

## **🛠️ Core Scripts**

### **Essential Operations**

./setup.sh              \# One-time system setup, dependency installation, and configuration.  
./startup.sh            \# Start/stop/restart Docker services. Use \--force-restart after config changes.  
./health.sh             \# Check system and service health, with optional auto-repair.  
./backup.sh             \# Create encrypted backups (database, full system, or emergency kit).  
./restore.sh            \# Restore system state from encrypted backups.

### **Maintenance & Configuration**

./edit-secrets.sh       \# Securely edit encrypted secrets (API keys, passwords).  
./update.sh             \# Update Docker container images or system packages.  
./maintenance.sh        \# Perform system cleanup (logs, old backups, Docker artifacts).  
./cron-setup.sh         \# Set up automated cron jobs for backups, updates, and health checks.

### **Quick Examples**

\# Check health and attempt automatic fixes  
./health.sh \--auto-heal

\# Create specific backup types  
./backup.sh \--type db           \# Quick database backup  
./backup.sh \--type full         \# Complete system backup (config \+ data)  
./backup.sh \--type emergency    \# Self-contained disaster recovery kit

\# Update Docker containers (pulls latest defined in .env)  
./update.sh \--type containers

\# Update underlying system packages  
sudo ./update.sh \--type system

\# Perform standard system cleanup  
sudo ./maintenance.sh \--type standard

## **🔒 Security Features**

* **Encrypted Secrets:** All sensitive data (API keys, tokens, passwords) stored encrypted using age and sops.  
* **Cloudflare Integration:**  
  * Traffic proxied through Cloudflare.  
  * Fail2ban bans malicious IPs directly via the Cloudflare API at the edge.  
* **Firewall Hardening:** ufw configured by setup.sh to allow web traffic *only* from Cloudflare IPs, preventing direct IP attacks.  
* **HTTPS Enforcement:** Automatic HTTPS via Caddy with Let's Encrypt.  
* **Security Headers:** Robust security headers configured in Caddy (Strict-Transport-Security, Content-Security-Policy, etc.).  
* **Rate Limiting:** Basic rate limiting configured in Caddy for API and admin endpoints.  
* **Non-root Containers:** Services run as non-root users within Docker where possible.  
* **Encrypted Backups:** All backups created by backup.sh are automatically encrypted.

## **📦 Backup & Recovery**

### **Reliable Backup Strategy**

* **Automated (via cron-setup.sh):**  
  * Daily encrypted database backups (default: 2:00 AM).  
  * Weekly encrypted full backups (default: Sunday 1:00 AM).  
* **Manual Backups (./backup.sh):**  
  * \--type db: Fast database snapshot.  
  * \--type full: Includes configuration, secrets (encrypted), and data snapshot. Recommended weekly.  
  * \--type emergency: Creates a self-contained kit for disaster recovery. Store this offsite\!  
* **Automatic Cleanup:** Old backups are automatically pruned based on retention settings (default: 14 days DB, 28 days full, 90 days emergency).

### **Straightforward Recovery**

\# Stop current services if running  
./startup.sh \--down

\# Restore from any backup type (auto-detects)  
./restore.sh /path/to/your/backup-file.tar.gz.age

\# Follow prompts (confirm destructive action)

\# Start services after restore  
./startup.sh

## **📊 Monitoring & Maintenance**

### **Health Monitoring (./health.sh)**

* Checks Docker status, container health (Vaultwarden, Caddy, Fail2ban, ddclient), system resources, network connectivity, recent backups, and secrets accessibility.  
* \--comprehensive flag runs all checks.  
* \--auto-heal attempts to restart or recreate unhealthy containers.

### **Automated Maintenance (sudo ./cron-setup.sh)**

* Configures cron jobs for:  
  * Daily DB backups.  
  * Weekly full backups.  
  * Regular health checks (./health.sh \--auto-heal).  
  * Weekly container updates (./update.sh \--type containers).  
  * Monthly system package updates (sudo ./update.sh \--type system).  
* Sets up log rotation for container and system logs.

### **Manual Maintenance (sudo ./maintenance.sh)**

* Cleans up old logs, rotates logs, prunes old backups according to retention policy.  
* Prunes unused Docker images, containers, volumes, and networks.  
* \--type deep also cleans system package cache and temporary files.

## **🚀 Resource Requirements**

Optimized for low-resource environments like OCI Free Tier.

* **Minimum (1-3 users):** 1 vCPU (ARM or x86), 2GB RAM, 20GB Storage.  
* **Recommended (4-10 users):** 1 OCPU (OCI A1.Flex ARM Recommended), 6GB RAM, 50GB Storage.  
* **Typical Usage:** 10-30% CPU, \~1-2GB RAM under normal load.

## **🌐 Hosting & Dynamic DNS**

* **Ideal for:** Cloud VMs (OCI, AWS, GCP, Azure, etc.), VPS (DigitalOcean, Vultr, Linode), Home Servers.  
* **OCI Always Free:** Runs well on an A1.Flex instance (1 OCPU, 6GB RAM, 50GB storage).  
* **Dynamic IP Support:** ddclient service automatically updates the Cloudflare DNS record specified by DDCLIENT\_HOSTNAME in .env if the server's public IP changes. Requires CLOUDFLARE\_ZONE\_ID and a cloudflare\_api\_token with Zone:DNS:Edit permissions.

## **🔧 Customization**

* **Secrets:** Edit secrets/secrets.yaml using ./edit-secrets.sh. **Never edit the encrypted file directly.**  
* **Environment:** Modify non-sensitive configuration in .env. Remember to run ./startup.sh \--force-restart after changes.  
* **Container Versions:** Update version tags (e.g., VAULTWARDEN\_VERSION) in .env, then run ./update.sh \--type containers.  
* **Docker Compose:** For advanced changes or development, create a docker-compose.override.yml (see example file).

## **📄 License**

MIT License.

**🎯 VaultWarden-OCI-NG Simplified**: Secure, reliable, self-hosted password management made easy, especially for dynamic IP environments.
