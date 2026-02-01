#!/usr/bin/env nu

# Creates a virtual machine with the specified provider
#
# Examples:
# > main create vm my-server --provider linode --size g6-standard-1
# > main create vm my-server --provider linode --size g6-nanode-1 --region us-east
def "main create vm" [
    label: string  # Label/name for the VM
    --provider: string = "linode"  # Cloud provider (linode)
    --size: string = "g6-standard-1"  # VM size/plan
    --region: string = "us-east"  # Region to deploy in
    --image: string = "linode/ubuntu24.04"  # OS image
    --ssh-key: string  # Path to SSH public key (default: ~/.ssh/id_rsa.pub)
] {

    let key_path = if ($ssh_key | is-empty) {
        $"($env.HOME)/.ssh/id_rsa.pub"
    } else {
        $ssh_key
    }

    match $provider {
        "linode" => (create-linode $label $size $region $image $key_path)
        _ => {
            print $"(ansi red_bold)($provider)(ansi reset) is not a supported provider."
            exit 1
        }
    }
}

# Destroys a virtual machine with the specified provider
#
# Examples:
# > main destroy vm my-server --provider linode
# > main destroy vm my-server --provider linode --force
def "main destroy vm" [
    label: string  # Label/name of the VM to destroy
    --provider: string = "linode"  # Cloud provider (linode)
    --force  # Skip confirmation prompt
] {

    match $provider {
        "linode" => (destroy-linode $label $force)
        _ => {
            print $"(ansi red_bold)($provider)(ansi reset) is not a supported provider."
            exit 1
        }
    }
}

# Lists virtual machines for the specified provider
#
# Examples:
# > main list vm --provider linode
# > main list vm --provider linode --label my-server
def "main list vm" [
    --provider: string = "linode"  # Cloud provider (linode)
    --label: string  # Filter by label (optional)
] {

    match $provider {
        "linode" => (list-linode $label)
        _ => {
            print $"(ansi red_bold)($provider)(ansi reset) is not a supported provider."
            exit 1
        }
    }
}

# Waits for a VM to be accessible via SSH
#
# Examples:
# > main wait-ssh 45.33.1.100
# > main wait-ssh 45.33.1.100 --timeout 10min --user root
def "main wait-ssh" [
    ip: string  # IP address of the VM
    --timeout: duration = 5min  # Maximum time to wait
    --user: string = "root"  # SSH user
] {

    print $"Waiting for (ansi yellow_bold)SSH(ansi reset) to be available on ($ip)..."

    let start = date now
    let end = $start + $timeout

    loop {
        if (date now) > $end {
            print $"(ansi red_bold)Timeout(ansi reset) waiting for SSH on ($ip)"
            return false
        }

        let result = do --ignore-errors {
            ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes $"($user)@($ip)" "echo ready" | complete
        }

        if ($result | is-not-empty) and ($result.exit_code? == 0) {
            print $"(ansi green_bold)SSH ready(ansi reset) on ($ip)"
            return true
        }

        print $"  Waiting... \(retrying in 10s\)"
        sleep 10sec
    }
}

# Runs a command on a remote VM via SSH
#
# Examples:
# > main run-ssh 45.33.1.100 "apt update"
# > main run-ssh 45.33.1.100 "hostname" --user root
def "main run-ssh" [
    ip: string  # IP address of the VM
    command: string  # Command to execute
    --user: string = "root"  # SSH user
] {

    ssh -o StrictHostKeyChecking=no $"($user)@($ip)" $command
}

# Internal: Creates a Linode VM
def create-linode [
    label: string
    size: string
    region: string
    image: string
    ssh_key_path: string
] {

    # Validate prerequisites
    if not (LINODE_TOKEN in $env) {
        print $"(ansi red_bold)LINODE_TOKEN(ansi reset) environment variable is not set."
        print "Get your API token from https://cloud.linode.com/profile/tokens"
        exit 1
    }

    if not ($ssh_key_path | path exists) {
        print $"(ansi red_bold)SSH public key not found(ansi reset) at ($ssh_key_path)"
        print "Generate one with: ssh-keygen -t rsa -b 4096"
        exit 1
    }

    # Check if linode-cli is installed
    let cli_check = do --ignore-errors { which linode-cli | complete }
    if ($cli_check | is-empty) or ($cli_check.exit_code? != 0) {
        print $"(ansi red_bold)linode-cli(ansi reset) is not installed."
        print "Install with: pip install linode-cli"
        exit 1
    }

    print $"Creating (ansi yellow_bold)Linode VM(ansi reset) '($label)'..."

    # Generate a random root password (required by API, but we'll disable password auth)
    let root_pass = (random chars --length 32)

    # Read SSH public key
    let ssh_key = (open $ssh_key_path | str trim)

    # Create the VM
    let result = (
        linode-cli linodes create
            --type $size
            --region $region
            --image $image
            --label $label
            --root_pass $root_pass
            --authorized_keys $ssh_key
            --json
    ) | from json | first

    let vm_id = $result.id
    let vm_status = $result.status

    print $"  VM created with ID: (ansi yellow_bold)($vm_id)(ansi reset)"
    print $"  Waiting for VM to boot..."

    # Wait for running status
    loop {
        let status = (
            linode-cli linodes view $vm_id --json
        ) | from json | first

        if $status.status == "running" {
            let ip = $status.ipv4 | first

            print $"  VM is (ansi green_bold)running(ansi reset)"
            print $"  IP address: (ansi yellow_bold)($ip)(ansi reset)"

            # Save to .env
            $"export ($label | str upcase | str replace '-' '_')_IP=($ip)\n" | save --append .env
            $"export ($label | str upcase | str replace '-' '_')_ID=($vm_id)\n" | save --append .env

            return {
                id: $vm_id
                label: $label
                ip: $ip
                status: "running"
            }
        }

        sleep 5sec
    }
}

# Internal: Destroys a Linode VM
def destroy-linode [
    label: string
    force: bool
] {

    # Validate prerequisites
    if not (LINODE_TOKEN in $env) {
        print $"(ansi red_bold)LINODE_TOKEN(ansi reset) environment variable is not set."
        exit 1
    }

    # Find VM by label
    let vms = (linode-cli linodes list --json) | from json | where label == $label

    if ($vms | is-empty) {
        print $"(ansi red_bold)No VM found(ansi reset) with label '($label)'"
        exit 1
    }

    let vm = $vms | first
    let vm_id = $vm.id

    if not $force {
        let confirm = input $"(ansi red_bold)Delete VM '($label)' \(ID: ($vm_id)\)?(ansi reset) [y/N] "
        if ($confirm | str downcase) != "y" {
            print "Cancelled."
            return
        }
    }

    print $"Deleting (ansi yellow_bold)Linode VM(ansi reset) '($label)'..."

    linode-cli linodes delete $vm_id

    print $"  VM (ansi green_bold)deleted(ansi reset)"
}

# Internal: Lists Linode VMs
def list-linode [
    label: string
] {

    # Validate prerequisites
    if not (LINODE_TOKEN in $env) {
        print $"(ansi red_bold)LINODE_TOKEN(ansi reset) environment variable is not set."
        exit 1
    }

    let vms = (linode-cli linodes list --json) | from json

    let filtered = if ($label | is-empty) {
        $vms
    } else {
        $vms | where label =~ $label
    }

    $filtered | select id label status region ipv4
}
