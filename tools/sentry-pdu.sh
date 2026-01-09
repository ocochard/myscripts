#!/bin/bash

# Manages outlets on a Sentry Switched CDU via SNMP

set -euo pipefail

# SNMP OID Base for Sentry 3 PDUs
SNMP_BASE="1.3.6.1.4.1.1718.3.2.3.1"

# Function to display usage
usage() {
    cat << EOF
Usage: $0 --host HOST [--snmp-read COMMUNITY] [--snmp-write COMMUNITY] [OPTIONS]
   or: $0 --config FILE [--host HOST] [OPTIONS]

CREDENTIALS (one of the following):
    Method 1: Specify credentials directly
        --host HOST                 PDU host/IP address (required)
        --snmp-read COMMUNITY       SNMP read community string (default: public)
        --snmp-write COMMUNITY      SNMP write community string (default: private, required for on/off/reboot)

    Method 2: Use credentials file
        --config FILE               Read credentials from file (one PDU per line: IP:read_community:write_community)
                                    File should be protected with: chmod 600 FILE
                                    Lines starting with # are ignored
        --host HOST                 Optional: specify which PDU from config file to use

OPTIONS:
    --list                      List all outlets with their status (default, uses SNMP)
    --action ACTION             Action to perform: on, off, reboot (uses SNMP)
    --outlet OUTLET             Outlet specification: single (17), range (17-20), or list (17,1,6)
    --help                      Display this help message

EXAMPLES:
    # Method 1: Direct credentials
    # List outlets (uses default read community "public"):
    $0 --host 10.36.104.32 --list

    # Control outlets with custom write community:
    $0 --host 10.36.104.32 --snmp-write "password" --action on --outlet 19
    $0 --host 10.36.104.32 --snmp-write "password" --action reboot --outlet 19-22

    # Control outlets with default write community "private":
    $0 --host 10.36.104.32 --action off --outlet 22

    # Method 2: Using config file
    # First, create and protect the config file:
    #   echo "10.36.104.32:public:password" > ~/.sentry-pdu.conf
    #   echo "10.36.104.33:public:private" >> ~/.sentry-pdu.conf
    #   chmod 600 ~/.sentry-pdu.conf

    # Then use it (uses first PDU in file):
    $0 --config ~/.sentry-pdu.conf --list

    # Or specify which PDU to use:
    $0 --config ~/.sentry-pdu.conf --host 10.36.104.33 --action reboot --outlet 19

NOTE:
    This script requires the net-snmp package for snmpget/snmpset commands.
    Install with: brew install net-snmp (macOS) or apt-get install snmp (Linux)

EOF
    exit 1
}

# Function to read credentials from config file
read_config() {
    local config_file="$1"
    local target_host="${2:-}"  # Optional: specific host to find

    # Check if file exists
    if [ ! -f "$config_file" ]; then
        echo "Error: Config file not found: $config_file" >&2
        exit 1
    fi

    # Check file permissions (should be 600 or more restrictive)
    local perms=$(stat -f "%Lp" "$config_file" 2>/dev/null || stat -c "%a" "$config_file" 2>/dev/null)
    if [ "$perms" != "600" ] && [ "$perms" != "400" ]; then
        echo "Warning: Config file has insecure permissions: $perms" >&2
        echo "Recommended: chmod 600 $config_file" >&2
    fi

    # Read config file and find matching entry
    local found=0
    while IFS=: read -r host read_comm write_comm || [ -n "$host" ]; do
        # Skip empty lines and comments
        [ -z "$host" ] && continue
        [[ "$host" =~ ^[[:space:]]*# ]] && continue

        # Trim whitespace
        host=$(echo "$host" | xargs)
        read_comm=$(echo "$read_comm" | xargs)
        write_comm=$(echo "$write_comm" | xargs)

        # If target host specified, find matching entry
        if [ -n "$target_host" ]; then
            if [ "$host" = "$target_host" ]; then
                echo "$host:$read_comm:$write_comm"
                found=1
                break
            fi
        else
            # No target host, use first valid entry
            if [ -n "$host" ] && [ -n "$read_comm" ]; then
                echo "$host:$read_comm:$write_comm"
                found=1
                break
            fi
        fi
    done < "$config_file"

    if [ $found -eq 0 ]; then
        if [ -n "$target_host" ]; then
            echo "Error: Host '$target_host' not found in config file" >&2
        else
            echo "Error: No valid credentials found in config file" >&2
        fi
        exit 1
    fi
}

# Function to list all outlets via SNMP
list_outlets() {
    echo "Fetching outlet information from ${PDU_HOST} via SNMP..."

    # Check if snmpwalk is available
    if ! command -v snmpwalk >/dev/null 2>&1; then
        echo "Error: snmpwalk command not found" >&2
        echo "Please install net-snmp package" >&2
        exit 1
    fi

    echo ""
    printf "%-10s %-25s %-10s %-10s %-10s\n" "Outlet ID" "Name" "Status" "Load (A)" "Power (W)"
    echo "--------------------------------------------------------------------------------"

    # Fetch all outlet data via SNMP
    # OID .3.1.1.X = outlet name
    # OID .5.1.1.X = outlet status (0=off, 1=on)
    # OID .7.1.1.X = outlet load in hundredths of amps
    # OID .14.1.1.X = outlet power in watts

    for outlet_num in {1..24}; do
        # Fetch all data for this outlet in one snmpget call
        local snmp_data
        snmp_data=$(snmpget -v2c -c "${SNMP_READ_COMM}" -Oqv "${PDU_HOST}" \
            "${SNMP_BASE}.3.1.1.${outlet_num}" \
            "${SNMP_BASE}.5.1.1.${outlet_num}" \
            "${SNMP_BASE}.7.1.1.${outlet_num}" \
            "${SNMP_BASE}.14.1.1.${outlet_num}" 2>&1)

        if [ $? -ne 0 ]; then
            # SNMP error - might have reached end of outlets
            continue
        fi

        # Parse the snmpget output (one value per line, remove quotes)
        local outlet_name=$(echo "$snmp_data" | sed -n '1p' | tr -d '"')
        local outlet_status=$(echo "$snmp_data" | sed -n '2p')
        local outlet_load_raw=$(echo "$snmp_data" | sed -n '3p')
        local outlet_power=$(echo "$snmp_data" | sed -n '4p')

        # Skip if no name (outlet doesn't exist)
        [ -z "$outlet_name" ] && continue

        # Convert status to On/Off
        case "$outlet_status" in
            0) local status="Off" ;;
            1) local status="On" ;;
            *) local status="Unknown" ;;
        esac

        # Convert load from hundredths to decimal (53 -> 0.53)
        local outlet_load=$(awk "BEGIN {printf \"%.2f\", ${outlet_load_raw:-0}/100}")

        # Format outlet ID as A1, A2, etc.
        local outlet_id="A${outlet_num}"

        printf "%-10s %-25s %-10s %-10s %-10s\n" "$outlet_id" "$outlet_name" "$status" "$outlet_load" "$outlet_power"
    done
}

# Function to parse outlet specification
parse_outlets() {
    local spec="$1"
    local outlets=()

    # Check if it's a range (e.g., 17-20)
    if [[ "$spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local start="${BASH_REMATCH[1]}"
        local end="${BASH_REMATCH[2]}"
        for ((i=start; i<=end; i++)); do
            outlets+=("$i")
        done
    # Check if it's a comma-separated list (e.g., 17,1,6)
    elif [[ "$spec" =~ , ]]; then
        IFS=',' read -ra outlets <<< "$spec"
    # Single outlet
    elif [[ "$spec" =~ ^[0-9]+$ ]]; then
        outlets=("$spec")
    else
        echo "Error: Invalid outlet specification: $spec" >&2
        exit 1
    fi

    echo "${outlets[@]}"
}

# Function to perform action on outlet
perform_action() {
    local action="$1"
    local outlet_spec="$2"

    # Validate action
    case "$action" in
        on|off|reboot)
            ;;
        *)
            echo "Error: Invalid action: $action" >&2
            echo "Valid actions are: on, off, reboot"
            exit 1
            ;;
    esac

    # Map action to form value
    local action_value
    case "$action" in
        on)
            action_value=1
            ;;
        off)
            action_value=2
            ;;
        reboot)
            action_value=3
            ;;
    esac

    # Parse outlet specification into array
    local outlets
    outlets=($(parse_outlets "$outlet_spec"))

    # Show what will be done
    echo "Action: ${action}"
    echo "Outlets: ${outlets[*]}"
    echo ""

    # Confirmation prompt for destructive actions
    if [ "$action" = "reboot" ] || [ "$action" = "off" ]; then
        echo -n "Are you sure you want to ${action} outlet(s) ${outlets[*]}? (yes/no): "
        read -r confirm
        if [ "$confirm" != "yes" ]; then
            echo "Action cancelled"
            exit 0
        fi
    fi

    # Check if snmpset is available
    if ! command -v snmpset >/dev/null 2>&1; then
        echo "Error: snmpset command not found" >&2
        echo "Please install net-snmp package" >&2
        exit 1
    fi

    # Check if write community is set
    if [ -z "$SNMP_WRITE_COMM" ]; then
        echo "Error: SNMP write community not specified" >&2
        echo "Use --snmp-write option or configure it in the config file" >&2
        exit 1
    fi

    echo "Sending command to PDU via SNMP..."

    # Execute action on each outlet via SNMP
    local success_count=0
    local fail_count=0

    for outlet_num in "${outlets[@]}"; do
        # Strip leading 'A' if present (e.g., A19 -> 19)
        outlet_num=$(echo "$outlet_num" | sed 's/^A//')

        # Validate outlet number
        if ! [[ "$outlet_num" =~ ^[0-9]+$ ]] || [ "$outlet_num" -lt 1 ] || [ "$outlet_num" -gt 24 ]; then
            echo "Error: Invalid outlet number: $outlet_num" >&2
            echo "Outlet numbers must be between 1 and 24" >&2
            exit 1
        fi

        # Send SNMP command to control the outlet
        # OID .11.1.1.X = outletControlAction
        local oid="${SNMP_BASE}.11.1.1.${outlet_num}"

        if snmpset -v2c -c "${SNMP_WRITE_COMM}" "${PDU_HOST}" "${oid}" i "${action_value}" >/dev/null 2>&1; then
            echo "  Outlet ${outlet_num}: ${action} command sent successfully"
            ((success_count++))
        else
            echo "  Outlet ${outlet_num}: ${action} command FAILED" >&2
            ((fail_count++))
        fi
    done

    echo ""
    if [ $fail_count -eq 0 ]; then
        echo "All commands sent successfully (${success_count}/${success_count})"
        echo ""
        echo "Waiting 2 seconds for PDU to process..."
        sleep 2
        echo ""
        echo "Current outlet status:"
        list_outlets
    else
        echo "Commands completed with errors: ${success_count} succeeded, ${fail_count} failed" >&2
        if [ $success_count -gt 0 ]; then
            echo ""
            echo "Current outlet status:"
            list_outlets
        fi
    fi
}

# Main script logic
main() {
    # Show usage if no parameters provided
    if [ $# -eq 0 ]; then
        usage
    fi

    local action="list"
    local outlet=""
    local perform_action_flag=0
    local config_file=""
    local host_from_cmdline=""

    # Initialize required parameters as empty
    PDU_HOST=""
    SNMP_READ_COMM=""
    SNMP_WRITE_COMM=""

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)
                if [ -z "${2:-}" ]; then
                    echo "Error: --config requires an argument" >&2
                    usage
                fi
                config_file="$2"
                shift 2
                ;;
            --host)
                if [ -z "${2:-}" ]; then
                    echo "Error: --host requires an argument" >&2
                    usage
                fi
                PDU_HOST="$2"
                host_from_cmdline="$2"
                shift 2
                ;;
            --snmp-read)
                if [ -z "${2:-}" ]; then
                    echo "Error: --snmp-read requires an argument" >&2
                    usage
                fi
                SNMP_READ_COMM="$2"
                shift 2
                ;;
            --snmp-write)
                if [ -z "${2:-}" ]; then
                    echo "Error: --snmp-write requires an argument" >&2
                    usage
                fi
                SNMP_WRITE_COMM="$2"
                shift 2
                ;;
            --list)
                action="list"
                shift
                ;;
            --action)
                if [ -z "${2:-}" ]; then
                    echo "Error: --action requires an argument" >&2
                    usage
                fi
                perform_action_flag=1
                action="$2"
                shift 2
                ;;
            --outlet)
                if [ -z "${2:-}" ]; then
                    echo "Error: --outlet requires an argument" >&2
                    usage
                fi
                outlet="$2"
                shift 2
                ;;
            --help|-h)
                usage
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                usage
                ;;
        esac
    done

    # Load credentials from config file if provided
    if [ -n "$config_file" ]; then
        local creds
        creds=$(read_config "$config_file" "$host_from_cmdline")

        # Parse credentials
        local conf_host conf_read_comm conf_write_comm
        IFS=: read -r conf_host conf_read_comm conf_write_comm <<< "$creds"

        # Use config file values if not overridden by command line
        [ -z "$PDU_HOST" ] && PDU_HOST="$conf_host"
        [ -z "$SNMP_READ_COMM" ] && SNMP_READ_COMM="$conf_read_comm"
        [ -z "$SNMP_WRITE_COMM" ] && SNMP_WRITE_COMM="$conf_write_comm"
    fi

    # Validate required parameters
    if [ -z "$PDU_HOST" ]; then
        echo "Error: --host is required (or use --config with credentials file)" >&2
        usage
    fi

    # Set default SNMP communities if not specified
    [ -z "$SNMP_READ_COMM" ] && SNMP_READ_COMM="public"
    [ -z "$SNMP_WRITE_COMM" ] && SNMP_WRITE_COMM="private"

    # Execute action
    if [ $perform_action_flag -eq 1 ]; then
        if [ -z "$outlet" ]; then
            echo "Error: --outlet is required when using --action" >&2
            usage
        fi
        perform_action "$action" "$outlet"
    else
        list_outlets
    fi
}

# Run main function
main "$@"
