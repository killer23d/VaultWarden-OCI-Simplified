# VaultWarden-OCI-NG (Simplified Edition)

**Production-Ready VaultWarden Deployment for Small Teams**

A streamlined, operationally excellent VaultWarden deployment optimized for teams of 10 or fewer users. This simplified edition reduces complexity by 85% while maintaining all essential functionality for reliable password management.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04%20LTS-orange.svg)](https://ubuntu.com/)

## 🎯 What Makes This Different

This is a **significantly simplified version** of VaultWarden-OCI-NG, designed specifically for small teams who want:
- **Set-and-forget reliability** without enterprise complexity
- **Essential functionality** without operational overhead  
- **Simple maintenance** with automated basics
- **Clear documentation** without enterprise jargon

### Key Simplifications
- **12 files** instead of 50+ (85% reduction)
- **~2,500 lines** instead of 15,000+ lines of code
- **5 core scripts** instead of 17+ operational tools
- **1 library** instead of 16 complex modules
- **Essential features only** - no enterprise abstractions

## ⚡ Quick Start (15 Minutes)

Deploy VaultWarden with essential reliability features:

```bash
# 1. Clone and setup
git clone https://github.com/your-repo/VaultWarden-OCI-NG-Simplified
cd VaultWarden-OCI-NG-Simplified
chmod +x *.sh

# 2. Run setup (installs dependencies, creates keys, configures system)
sudo ./setup.sh --domain vault.yourdomain.com --email admin@yourdomain.com --auto

# 3. Configure secrets (SMTP, admin password, etc.)
./edit-secrets.sh

# 4. Start services
./startup.sh

# 5. Setup automation (optional but recommended)
sudo ./cron-setup.sh

# 6. Verify everything works
./health.sh --comprehensive
```

**🎉 Your VaultWarden is now operational at `https://vault.yourdomain.com`**

## 🏗️ Architecture

### Simple, Effective Stack
```
┌─────────────────────────────────────────┐
│              Management                 │
│  ┌─────────────┐  ┌─────────────────┐   │
│  │ 5 Scripts   │  │  1 Library      │   │ 
│  │ (Essential) │  │  (Unified)      │   │
│  └─────────────┘  └─────────────────┘   │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│              Security                   │
│  ┌─────────────┐  ┌─────────────────┐   │
│  │   fail2ban  │  │  Age Encryption │   │
│  │  (Built-in) │  │  (SOPS Managed) │   │
│  └─────────────┘  └─────────────────┘   │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│             Application                 │
│  ┌─────────────┐  ┌─────────────────┐   │
│  │    Caddy    │  │  VaultWarden    │   │
│  │  (Proxy)    │  │  (Password Mgr) │   │
│  └─────────────┘  └─────────────────┘   │
└─────────────────────────────────────────┘
```

### Core Technologies
- **VaultWarden 1.30+** - Bitwarden-compatible server
- **Caddy 2.7+** - Automatic HTTPS reverse proxy
- **SQLite** - Simple, reliable database
- **Docker Compose** - Container orchestration
- **Age + SOPS** - Modern secrets encryption
- **fail2ban** - Basic intrusion protection

## 🛠️ Core Scripts

### Essential Operations
```bash
./setup.sh              # Complete system setup and configuration
./startup.sh             # Start/stop/restart services  
./health.sh              # Check system health and auto-repair
./backup.sh              # Create encrypted backups
./restore.sh             # Restore from backups
```

### Maintenance & Configuration
```bash
./edit-secrets.sh        # Manage encrypted secrets
./update.sh              # Update containers and system
./maintenance.sh         # System cleanup and maintenance
./cron-setup.sh         # Setup automated tasks
```

### Quick Examples
```bash
# Health check with auto-repair
./health.sh --auto-heal

# Create different backup types
./backup.sh --type db           # Quick database backup
./backup.sh --type full         # Complete system backup  
./backup.sh --type emergency    # Disaster recovery kit

# Update system components
./update.sh --type containers   # Update Docker containers
./update.sh --type system      # Update system packages
./update.sh --type all         # Update everything

# System maintenance
./maintenance.sh --type standard  # Standard cleanup
./maintenance.sh --type deep     # Deep system cleanup
```

## 🔒 Security Features

### Built-in Protection
- **Age encryption** for all secrets and backups
- **fail2ban** protection against brute force attacks
- **Non-root containers** for reduced attack surface
- **Automatic HTTPS** with Let's Encrypt certificates
- **Input validation** for all configuration parameters

### Security Configuration
```bash
# All secrets are encrypted with Age/SOPS
./edit-secrets.sh  # Safely edit encrypted secrets

# Backups are automatically encrypted
./backup.sh        # Creates encrypted backup files

# System hardening is automated
sudo ./setup.sh    # Configures firewall, users, permissions
```

## 📦 Backup & Recovery

### Simple Backup Strategy
```bash
# Automated (via cron-setup.sh)
- Daily database backups (2:00 AM)
- Weekly full backups (Sunday 1:00 AM)

# Manual backups
./backup.sh --type db        # Fast database backup
./backup.sh --type full      # Complete system state
./backup.sh --type emergency # Disaster recovery kit
```

### Easy Recovery
```bash
# Restore from any backup type
./restore.sh backup-file.tar.gz.age

# Auto-detects backup type and guides you through recovery
./restore.sh --type auto emergency-kit.tar.gz.age

# Preview what would be restored
./restore.sh --dry-run backup-file.age
```

## 📊 Monitoring & Maintenance

### Health Monitoring
```bash
# Quick health check
./health.sh

# Comprehensive system check  
./health.sh --comprehensive

# Auto-repair issues
./health.sh --auto-heal
```

### Automated Maintenance
```bash
# Setup automated tasks (recommended)
sudo ./cron-setup.sh

# Manual maintenance
./maintenance.sh --type standard  # Regular cleanup
./maintenance.sh --type deep     # Thorough cleanup
```

## 🚀 Resource Requirements

### Minimum (1-3 users)
- **CPU:** 1 vCPU (any architecture)
- **RAM:** 2GB
- **Storage:** 20GB
- **Network:** 10Mbps

### Recommended (4-10 users)
- **CPU:** 1 vCPU (consistent performance)  
- **RAM:** 6GB
- **Storage:** 50GB
- **Network:** 100Mbps

### Typical Usage
- **Normal load:** 10-30% CPU, 1-2GB RAM
- **Peak load:** 50-70% CPU during backups
- **Response time:** <2s web interface, <1s API

## 🌐 Hosting Options

### Oracle Cloud (Recommended)
- **Instance:** A1.Flex (ARM-based)
- **Config:** 1 OCPU, 6GB RAM, 50GB storage
- **Cost:** $0/month (Always Free Tier)

### Alternative Providers
- **AWS:** t4g.small or t3.small
- **Google Cloud:** e2-small or e2-standard-2
- **DigitalOcean:** Basic Droplet (2GB+)
- **Vultr:** Regular Performance instances

## 📚 Documentation Structure

### Getting Started
- **README.md** (this file) - Overview and quick start
- **setup.sh --help** - Setup options and configuration
- **Script help** - Each script has `--help` for usage

### Operations
- **health.sh --help** - Health monitoring and auto-repair
- **backup.sh --help** - Backup creation and management
- **restore.sh --help** - Recovery procedures
- **maintenance.sh --help** - System maintenance

### Configuration
- **edit-secrets.sh** - Interactive secrets management
- **.env.example** - Configuration template
- **docker-compose.override.yml.example** - Customization template

## 🔧 Customization

### Environment Configuration
```bash
# Copy and customize
cp .env .env.local
./edit-secrets.sh --init  # Initialize secrets
```

### Docker Compose Overrides
```bash
# Copy and customize for development/testing
cp docker-compose.override.yml.example docker-compose.override.yml
```

### Adding Custom Scripts
```bash
# Source the common library for consistency
source lib/common.sh
init_common_lib "$0"

# Use standard logging functions
log_info "Your custom operation"
log_success "Operation completed"
```

## 🤝 Contributing

### Code Standards
- **Shell scripts:** Follow existing patterns with proper error handling
- **Documentation:** Update help text and examples
- **Testing:** Verify with `./health.sh --comprehensive`
- **Security:** Consider security implications of changes

### Development Setup
```bash
# Use override for development customizations
cp docker-compose.override.yml.example docker-compose.override.yml

# Enable debug logging
export DEBUG=true
```

## 📋 What's Different from Full Edition

### Removed Enterprise Features
- ❌ Multi-region backup distribution
- ❌ Advanced compliance audit trails  
- ❌ Complex monitoring with metrics collection
- ❌ Enterprise notification systems
- ❌ Multi-tier disaster recovery
- ❌ Advanced security scanning
- ❌ Complex validation frameworks

### Kept Essential Features  
- ✅ Encrypted secrets management
- ✅ Automated backups with encryption
- ✅ Health monitoring with auto-repair
- ✅ Container updates and maintenance
- ✅ Basic intrusion protection
- ✅ Disaster recovery capabilities
- ✅ Simple maintenance automation

## 🎯 Perfect For

### Ideal Use Cases
- **Small teams** (1-10 users)
- **Startups** needing reliable password management
- **Home labs** requiring production-quality setup
- **Small businesses** wanting set-and-forget operation
- **Personal use** with family/friends

### Not Ideal For
- **Large enterprises** (use full edition)
- **Complex compliance requirements**
- **Multi-region deployments**
- **Advanced monitoring needs**

## 📄 License

MIT License - maximum flexibility for personal and commercial use.

---

## 🚀 Quick Commands Reference

```bash
# Initial Setup
sudo ./setup.sh --domain vault.example.com --email admin@example.com --auto

# Daily Operations  
./health.sh --auto-heal     # Check and fix issues
./backup.sh --type db       # Quick backup
./startup.sh --down         # Stop services

# Weekly Operations
./backup.sh --type full     # Complete backup
./update.sh --type all      # Update everything
./maintenance.sh            # System cleanup

# Emergency Recovery
./restore.sh emergency-kit.tar.gz.age
```

**Questions?** Each script has `--help` for detailed usage information.

**🎯 VaultWarden-OCI-NG Simplified**: Production reliability without enterprise complexity.
