#!/bin/bash

# Configuration
IFACE=${2:-"eth0"}      # Default to eth0 if not specified
IFB="ifb1"             # Intermediate Functional Block for ingress
BURST="100kb"
LATENCY="100ms"

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

show_usage() {
    echo "Usage: $0 {limit|restore} [interface] [rate]"
    echo "Example: $0 limit eth0 50mbit"
    echo "Example: $0 restore eth0"
}

limit() {
    RATE=$1
    if [ -z "$RATE" ]; then
        echo "Error: Limit rate required (e.g., 50mbit)"
        show_usage
        exit 1
    fi

    echo "Applying $RATE limit to $IFACE..."

    # 1. Clean up existing rules first to avoid "File exists" errors
    restore > /dev/null 2>&1

    # 2. Egress Shaping (Upload)
    tc qdisc add dev "$IFACE" root tbf rate "$RATE" burst "$BURST" latency "$LATENCY"

    # 3. Ingress Shaping (Download) via IFB
    # Load ifb module if not loaded
    modprobe ifb numifbs=1 2>/dev/null
    ip link add "$IFB" type ifb 2>/dev/null
    ip link set "$IFB" up

    # Redirect ingress traffic from physical interface to IFB
    tc qdisc add dev "$IFACE" handle ffff: ingress
    tc filter add dev "$IFACE" parent ffff: protocol all u32 match u32 0 0 \
        action mirred egress redirect dev "$IFB"

    # Apply the rate limit to the IFB interface
    tc qdisc add dev "$IFB" root tbf rate "$RATE" burst "$BURST" latency "$LATENCY"

    echo "Done. $IFACE is now limited to $RATE (both directions)."
}

restore() {
    echo "Restoring default settings for $IFACE..."

    # Remove root qdisc (Egress)
    tc qdisc del dev "$IFACE" root 2>/dev/null

    # Remove Ingress qdisc and filters
    tc qdisc del dev "$IFACE" ingress 2>/dev/null

    # Clean up IFB
    tc qdisc del dev "$IFB" root 2>/dev/null
    ip link del "$IFB" 2>/dev/null

    echo "Restoration complete."
}

case "$1" in
    limit)
        # Shift arguments so $1 becomes the rate if interface was provided
        # Syntax: ./script limit [interface] [rate]
        if [ "$#" -eq 3 ]; then
            IFACE=$2
            limit "$3"
        else
            limit "$2"
        fi
        ;;
    restore)
        IFACE=${2:-"eth0"}
        restore
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
