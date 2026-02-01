#!/usr/bin/env nu

# Hardens the OpenClaw VM with security best practices
#
# Examples:
# > main harden openclaw 173.255.229.103
# > main harden openclaw $env.OPENCLAW_IP
def "main harden openclaw" [
    ip: string  # IP address of the VM
    --user: string = "root"  # SSH user
] {

    print $"(ansi yellow_bold)Hardening OpenClaw VM(ansi reset) at ($ip)..."

    # Step 1: System updates
    print $"\n(ansi cyan_bold)Step 1:(ansi reset) Applying system updates..."
    main run-ssh $ip "apt update && DEBIAN_FRONTEND=noninteractive apt upgrade -y" --user $user

    # Step 2: Install security packages
    print $"\n(ansi cyan_bold)Step 2:(ansi reset) Installing security packages..."
    main run-ssh $ip "DEBIAN_FRONTEND=noninteractive apt install -y ufw fail2ban" --user $user

    # Step 3: Configure SSH hardening
    print $"\n(ansi cyan_bold)Step 3:(ansi reset) Configuring SSH hardening..."
    main run-ssh $ip "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config" --user $user
    main run-ssh $ip "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config" --user $user
    main run-ssh $ip "sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config" --user $user
    main run-ssh $ip "systemctl restart ssh" --user $user

    # Step 4: Configure UFW firewall
    print $"\n(ansi cyan_bold)Step 4:(ansi reset) Configuring UFW firewall..."
    main run-ssh $ip "ufw default deny incoming" --user $user
    main run-ssh $ip "ufw default allow outgoing" --user $user
    main run-ssh $ip "ufw allow ssh" --user $user
    main run-ssh $ip "echo 'y' | ufw enable" --user $user

    # Step 5: Configure fail2ban
    print $"\n(ansi cyan_bold)Step 5:(ansi reset) Configuring fail2ban..."
    let fail2ban_config = "[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600"
    main run-ssh $ip $"echo '($fail2ban_config)' > /etc/fail2ban/jail.local" --user $user
    main run-ssh $ip "systemctl enable fail2ban && systemctl restart fail2ban" --user $user

    # Step 6: Verify configuration
    print $"\n(ansi cyan_bold)Step 6:(ansi reset) Verifying configuration..."
    print "  UFW status:"
    main run-ssh $ip "ufw status" --user $user
    print "  fail2ban status:"
    main run-ssh $ip "fail2ban-client status" --user $user

    print $"\n(ansi green_bold)Hardening complete!(ansi reset)"
    print $"
Security measures applied:
  - System packages updated
  - SSH: Password authentication disabled
  - SSH: Only key-based authentication allowed
  - UFW: Firewall enabled, only SSH allowed
  - fail2ban: Brute-force protection active

Next step: Install Tailscale VPN
"
}

# Installs Tailscale VPN on the OpenClaw VM
#
# Examples:
# > main install tailscale 173.255.229.103 --auth-key tskey-auth-xxx
def "main install tailscale" [
    ip: string  # IP address of the VM
    --auth-key: string  # Tailscale auth key
    --user: string = "root"  # SSH user
] {

    if ($auth_key | is-empty) {
        print $"(ansi red_bold)Error:(ansi reset) --auth-key is required"
        print "Get an auth key from https://login.tailscale.com/admin/settings/keys"
        exit 1
    }

    print $"(ansi yellow_bold)Installing Tailscale(ansi reset) on ($ip)..."

    # Install Tailscale
    print $"\n(ansi cyan_bold)Step 1:(ansi reset) Installing Tailscale..."
    main run-ssh $ip "curl -fsSL https://tailscale.com/install.sh | sh" --user $user

    # Authenticate and connect
    print $"\n(ansi cyan_bold)Step 2:(ansi reset) Authenticating with Tailscale..."
    main run-ssh $ip $"tailscale up --authkey ($auth_key)" --user $user

    # Get Tailscale IP
    print $"\n(ansi cyan_bold)Step 3:(ansi reset) Getting Tailscale IP..."
    let ts_ip = (main run-ssh $ip "tailscale ip -4" --user $user | str trim)
    print $"  Tailscale IP: (ansi yellow_bold)($ts_ip)(ansi reset)"

    # Update UFW to restrict SSH to Tailscale only
    print $"\n(ansi cyan_bold)Step 4:(ansi reset) Updating firewall for Tailscale..."
    main run-ssh $ip "ufw allow in on tailscale0" --user $user
    main run-ssh $ip "ufw delete allow ssh" --user $user
    main run-ssh $ip "ufw allow in on tailscale0 to any port 22" --user $user

    print $"\n(ansi green_bold)Tailscale installed!(ansi reset)"
    print $"
Tailscale configuration:
  - Tailscale IP: ($ts_ip)
  - SSH now only accessible via Tailscale
  - Public SSH access disabled

To connect: ssh root@($ts_ip)

Next step: Install Docker and OpenClaw
"

    # Save Tailscale IP to .env
    $"export OPENCLAW_TAILSCALE_IP=($ts_ip)\n" | save --append .env
}

# Installs Docker on the OpenClaw VM
#
# Examples:
# > main install docker 173.255.229.103
def "main install docker" [
    ip: string  # IP address of the VM
    --user: string = "root"  # SSH user
] {

    print $"(ansi yellow_bold)Installing Docker(ansi reset) on ($ip)..."

    # Install Docker using official script
    print $"\n(ansi cyan_bold)Step 1:(ansi reset) Installing Docker..."
    main run-ssh $ip "curl -fsSL https://get.docker.com | sh" --user $user

    # Configure Docker daemon with security settings
    print $"\n(ansi cyan_bold)Step 2:(ansi reset) Configuring Docker security..."
    let docker_config = '{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "no-new-privileges": true
}'
    main run-ssh $ip $"echo '($docker_config)' > /etc/docker/daemon.json" --user $user
    main run-ssh $ip "systemctl restart docker" --user $user

    # Verify installation
    print $"\n(ansi cyan_bold)Step 3:(ansi reset) Verifying Docker..."
    main run-ssh $ip "docker --version" --user $user
    main run-ssh $ip "docker run --rm hello-world" --user $user

    print $"\n(ansi green_bold)Docker installed!(ansi reset)"
    print "
Docker configuration:
  - Log rotation enabled
  - no-new-privileges security flag set

Next step: Install OpenClaw
"
}

# Installs OpenClaw on the VM
#
# Examples:
# > main install openclaw 173.255.229.103 --anthropic-key sk-ant-xxx
def "main install openclaw" [
    ip: string  # IP address of the VM
    --anthropic-key: string  # Anthropic API key
    --user: string = "root"  # SSH user
] {

    if ($anthropic_key | is-empty) {
        print $"(ansi red_bold)Error:(ansi reset) --anthropic-key is required"
        exit 1
    }

    print $"(ansi yellow_bold)Installing OpenClaw(ansi reset) on ($ip)..."

    # Install OpenClaw
    print $"\n(ansi cyan_bold)Step 1:(ansi reset) Installing OpenClaw..."
    main run-ssh $ip "curl -fsSL https://raw.githubusercontent.com/openclaw/openclaw/main/install.sh | sh" --user $user

    # Configure OpenClaw
    print $"\n(ansi cyan_bold)Step 2:(ansi reset) Configuring OpenClaw..."
    main run-ssh $ip $"openclaw config set anthropic_api_key ($anthropic_key)" --user $user

    # Start OpenClaw gateway
    print $"\n(ansi cyan_bold)Step 3:(ansi reset) Starting OpenClaw gateway..."
    main run-ssh $ip "openclaw gateway start --port 18789" --user $user

    # Update firewall for gateway
    print $"\n(ansi cyan_bold)Step 4:(ansi reset) Updating firewall for gateway..."
    main run-ssh $ip "ufw allow in on tailscale0 to any port 18789" --user $user

    print $"\n(ansi green_bold)OpenClaw installed!(ansi reset)"
    print "
OpenClaw is now running:
  - Gateway port: 18789
  - Accessible only via Tailscale

To access: http://<tailscale-ip>:18789
"
}
