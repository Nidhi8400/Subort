#!/bin/bash
# ss.sh - Enhanced Recon Script for Kali Linux
# Author: Your Name
# Usage: ./ss.sh targetdomain.com

set -e

# ---------------- Functions ----------------
print_status() { echo -e "[+] $1"; }
print_success() { echo -e "[✓] $1"; }
print_error() { echo -e "[!] $1"; }

start_html() {
    cat <<EOF >"$HTML_FILE"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Recon Report - $TARGET</title>
<style>
body { font-family: Arial, sans-serif; background-color: #f4f4f4; }
table { border-collapse: collapse; width: 80%; margin: 20px auto; }
th, td { border: 1px solid #999; padding: 8px 12px; text-align: left; }
th { background-color: #333; color: white; }
tr:nth-child(even) { background-color: #eee; }
.open { color: green; font-weight: bold; }
.none { color: red; font-weight: bold; }
</style>
</head>
<body>
<h1 style="text-align:center;">Recon Report - $TARGET</h1>
<p style="text-align:center;">Generated: $(date)</p>
<h2>Subdomains & IPs</h2>
<table>
<tr><th>#</th><th>Subdomain</th><th>IP</th><th>Open Ports</th></tr>
EOF
}

append_html_row() {
    local num="$1" sub="$2" ip="$3" ports="$4"
    if [[ "$ports" == "None" ]]; then
        port_class="none"
    else
        port_class="open"
    fi
    echo "<tr><td>$num</td><td>$sub</td><td>$ip</td><td class=\"$port_class\">$ports</td></tr>" >>"$HTML_FILE"
}

end_html() {
    echo "</table></body></html>" >>"$HTML_FILE"
}

# ---------------- Arguments ----------------
if [ -z "$1" ]; then
    echo "Usage: $0 targetdomain.com"
    exit 1
fi

TARGET="$1"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="recon_${TARGET}_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

SUBDOMAINS_FILE="$OUTPUT_DIR/subdomains.txt"
IPS_FILE="$OUTPUT_DIR/ips.txt"
PORTS_FILE="$OUTPUT_DIR/ports.csv"
HTML_FILE="$OUTPUT_DIR/recon_report.html"

print_status "Starting recon on $TARGET"
print_status "Results will be saved in $OUTPUT_DIR"

# ---------------- Subdomain Enumeration ----------------
print_status "Enumerating subdomains with assetfinder..."
assetfinder --subs-only "$TARGET" | sort -u | tee "$SUBDOMAINS_FILE"
SUB_COUNT=$(wc -l < "$SUBDOMAINS_FILE")
print_success "$SUB_COUNT subdomains found"
print_status "Saved to $SUBDOMAINS_FILE"

# ---------------- Resolve IPs ----------------
read -r -p "Do you want to resolve IPs for these subdomains? (y/n): " resolve_ans
if [[ "$resolve_ans" =~ ^[Yy]$ ]]; then
    print_status "Resolving IP addresses..."
    > "$IPS_FILE"
    num=1
    while read -r sub; do
        ip=$(dig +short "$sub" | head -n1)
        if [ -n "$ip" ]; then
            echo "$num,$sub,$ip" | tee -a "$IPS_FILE"
            echo "  [$num] $sub -> $ip"
        else
            echo "$num,$sub," | tee -a "$IPS_FILE"
            echo "  [$num] $sub -> [No IP found]"
        fi
        ((num++))
    done < "$SUBDOMAINS_FILE"
    RESOLVED_COUNT=$(grep -v ',,' "$IPS_FILE" | wc -l)
    print_success "$RESOLVED_COUNT subdomains resolved to IPs"
fi

# ---------------- Nmap Scan ----------------
if [ -s "$IPS_FILE" ]; then
    read -r -p "Do you want to run Nmap scan? (y/n): " nmap_ans
    if [[ "$nmap_ans" =~ ^[Yy]$ ]]; then

        echo
        echo "Scan options:"
        echo "1) Scan ALL resolved IPs"
        echo "2) Scan a SINGLE IP"
        echo "3) Scan SINGLE or MULTIPLE subdomains (by number)"
        read -r -p "Enter choice [1/2/3]: " choice

        echo "Port scan type:"
        echo "1) Common ports (fast)"
        echo "2) Full scan (all 65535 ports)"
        read -r -p "Enter choice [1/2]: " port_mode

        if [[ "$port_mode" == "1" ]]; then
            PORT_RANGE="21,22,25,53,80,110,143,443,3306,3389,8080"
            NMAP_OPTS="-p $PORT_RANGE -sV"
        else
            NMAP_OPTS="-p- -sV"
        fi

        start_html
        case "$choice" in
            1)
                print_status "Scanning all IPs..."
                while IFS=',' read -r num sub ip; do
                    [ -z "$ip" ] && continue
                    open_ports=$(nmap -Pn --open $NMAP_OPTS "$ip" \
                        | grep -oP '^[0-9]+/tcp\s+open' | awk '{print $1}' | paste -sd ";" -)
                    [ -z "$open_ports" ] && open_ports="None"
                    echo "$sub,$ip,$open_ports" >> "$PORTS_FILE"
                    append_html_row "$num" "$sub" "$ip" "$open_ports"
                done < "$IPS_FILE"
                ;;
            2)
                read -r -p "Enter IP to scan: " target_ip
                sub=$(grep "$target_ip" "$IPS_FILE" | cut -d',' -f2 || echo "Unknown")
                open_ports=$(nmap -Pn --open $NMAP_OPTS "$target_ip" \
                    | grep -oP '^[0-9]+/tcp\s+open' | awk '{print $1}' | paste -sd ";" -)
                [ -z "$open_ports" ] && open_ports="None"
                echo "$sub,$target_ip,$open_ports" >> "$PORTS_FILE"
                append_html_row "1" "$sub" "$target_ip" "$open_ports"
                ;;
            3)
                echo "Available subdomains:"
                cat "$IPS_FILE" | while IFS=',' read -r num sub ip; do
                    echo "[$num] $sub -> $ip"
                done
                read -r -p "Enter numbers (comma-separated) of subdomains to scan: " selections
                IFS=',' read -ra nums <<< "$selections"
                for n in "${nums[@]}"; do
                    target_line=$(grep "^$n," "$IPS_FILE")
                    target_sub=$(echo "$target_line" | cut -d',' -f2)
                    target_ip=$(echo "$target_line" | cut -d',' -f3)
                    if [ -z "$target_ip" ]; then
                        print_error "Skipping $target_sub - no IP found."
                        continue
                    fi
                    open_ports=$(nmap -Pn --open $NMAP_OPTS "$target_ip" \
                        | grep -oP '^[0-9]+/tcp\s+open' | awk '{print $1}' | paste -sd ";" -)
                    [ -z "$open_ports" ] && open_ports="None"
                    echo "$target_sub,$target_ip,$open_ports" >> "$PORTS_FILE"
                    append_html_row "$n" "$target_sub" "$target_ip" "$open_ports"
                done
                ;;
            *)
                print_error "Invalid choice. Skipping Nmap."
                ;;
        esac

        end_html
        print_status "HTML report saved to $HTML_FILE"
        print_status "CSV results saved to $PORTS_FILE"
    else
        print_status "Skipping Nmap scan."
    fi
fi

print_success "Recon finished!"

