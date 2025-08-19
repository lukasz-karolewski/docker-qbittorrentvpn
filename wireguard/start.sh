#!/bin/bash
set -e

# Function to lowercase and trim input
lowercase_trim() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's~^[ \t]*~~;s~[ \t]*$~~'
}

# Define timestamp format
timestamp_format='%Y-%m-%d %H:%M:%.S'

# check for presence of network interface docker0
check_network=$(ifconfig | grep docker0 || true)

# if network interface docker0 is present then we are running in host mode and thus must exit
if [[ -n "${check_network}" ]]; then
	echo "[ERROR] Network type detected as 'Host', this will cause major issues, please stop the container and switch back to 'Bridge' mode" | ts "$timestamp_format"
	# Sleep so it wont 'spam restart'
	sleep 10
	exit 1
fi

export VPN_ENABLED=$(lowercase_trim "$VPN_ENABLED")
if [[ -n "${VPN_ENABLED}" ]]; then
	echo "[INFO] VPN_ENABLED defined as '${VPN_ENABLED}'" | ts "$timestamp_format"
else
	echo "[WARNING] VPN_ENABLED not defined, (via -e VPN_ENABLED), defaulting to 'yes'" | ts "$timestamp_format"
	export VPN_ENABLED="yes"
fi

echo "[INFO] The container is currently running $(iptables -V)."  | ts "$timestamp_format"

if [[ $VPN_ENABLED == "1" || $VPN_ENABLED == "true" || $VPN_ENABLED == "yes" ]]; then
	# Create the directory to storeWireGuard config files
	mkdir -p /config/wireguard
	# Set permmissions and owner for files in /config/wireguard directory
	set +e
	chown -R "${PUID}":"${PGID}" "/config/wireguard" &> /dev/null
	exit_code_chown=$?
	chmod -R 700 "/config/wireguard" &> /dev/null
	exit_code_chmod=$?
	set -e
	if (( exit_code_chown != 0 || exit_code_chmod != 0 )); then
		echo "[WARNING] Unable to chown/chmod /config/wireguard/, assuming SMB mountpoint" | ts "$timestamp_format"
	fi

	# Wildcard search for wireguard config files (match on first result)
	export VPN_CONFIG=$(find /config/wireguard -maxdepth 1 -name "*.conf" -print -quit)

	# If config file not found in /config/wireguard then exit
	if [[ -z "${VPN_CONFIG}" ]]; then
		echo "[ERROR] No WireGuard config file found in /config/wireguard/. Please download one from your VPN provider and restart this container. Make sure the file extension is '.conf'" | ts "$timestamp_format"
		# Sleep so it wont 'spam restart'
		sleep 10
		exit 1
	fi

	echo "[INFO] WireGuard config file is found at ${VPN_CONFIG}" | ts "$timestamp_format"
	if [[ "${VPN_CONFIG}" != "/config/wireguard/wg0.conf" ]]; then
		echo "[ERROR] WireGuard config filename is not 'wg0.conf'" | ts "$timestamp_format"
		echo "[ERROR] Rename ${VPN_CONFIG} to 'wg0.conf'" | ts "$timestamp_format"
		sleep 10
		exit 1
	fi

	# parse values from the ovpn or conf file
	export vpn_remote_line=$(cat "${VPN_CONFIG}" | grep -P -o -m 1 '(?<=^Endpoint)(\s{0,})[^\n\r]+' | sed -e 's~^[=\ ]*~~')
	if [[ -n "${vpn_remote_line}" ]]; then
		echo "[INFO] VPN remote line defined as '${vpn_remote_line}'" | ts "$timestamp_format"
	else
		echo "[ERROR] VPN configuration file ${VPN_CONFIG} does not contain 'remote' line, showing contents of file before exit..." | ts "$timestamp_format"
		cat "${VPN_CONFIG}"
		# Sleep so it wont 'spam restart'
		sleep 10
		exit 1
	fi

	export VPN_REMOTE=$(echo "${vpn_remote_line}" | grep -P -o -m 1 '^[^:\r\n]+')
	if [[ -n "${VPN_REMOTE}" ]]; then
		echo "[INFO] VPN_REMOTE defined as '${VPN_REMOTE}'" | ts "$timestamp_format"
	else
		echo "[ERROR] VPN_REMOTE not found in ${VPN_CONFIG}, exiting..." | ts "$timestamp_format"
		# Sleep so it wont 'spam restart'
		sleep 10
		exit 1
	fi

	export VPN_PORT=$(echo "${vpn_remote_line}" | grep -P -o -m 1 '(?<=:)\d{2,5}(?=:)?+')
	if [[ -n "${VPN_PORT}" ]]; then
		echo "[INFO] VPN_PORT defined as '${VPN_PORT}'" | ts "$timestamp_format"
	else
		echo "[ERROR] VPN_PORT not found in ${VPN_CONFIG}, exiting..." | ts "$timestamp_format"
		# Sleep so it wont 'spam restart'
		sleep 10
		exit 1
	fi

	export VPN_PROTOCOL="udp"
	echo "[INFO] VPN_PROTOCOL set as '${VPN_PROTOCOL}', since WireGuard is always ${VPN_PROTOCOL}." | ts "$timestamp_format"

	export VPN_DEVICE_TYPE="wg0"
	echo "[INFO] VPN_DEVICE_TYPE set as '${VPN_DEVICE_TYPE}', since WireGuard will always be wg0." | ts "$timestamp_format"

	# get values from env vars as defined by user
	export LAN_NETWORK=$(echo "${LAN_NETWORK}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
	if [[ -n "${LAN_NETWORK}" ]]; then
		echo "[INFO] LAN_NETWORK defined as '${LAN_NETWORK}'" | ts "$timestamp_format"
	else
		echo "[ERROR] LAN_NETWORK not defined (via -e LAN_NETWORK), exiting..." | ts "$timestamp_format"
		# Sleep so it wont 'spam restart'
		sleep 10
		exit 1
	fi

	export NAME_SERVERS=$(echo "${NAME_SERVERS}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
	if [[ -n "${NAME_SERVERS}" ]]; then
		echo "[INFO] NAME_SERVERS defined as '${NAME_SERVERS}'" | ts "$timestamp_format"
	else
		echo "[WARNING] NAME_SERVERS not defined (via -e NAME_SERVERS), defaulting to CloudFlare and Google name servers" | ts "$timestamp_format"
		export NAME_SERVERS="1.1.1.1,8.8.8.8,1.0.0.1,8.8.4.4"
	fi

else
	echo "[WARNING] !!IMPORTANT!! You have set the VPN to disabled, your connection will NOT be secure!" | ts "$timestamp_format"
fi


# split comma seperated string into list from NAME_SERVERS env variable
IFS=',' read -ra name_server_list <<< "${NAME_SERVERS}"

# process name servers in the list
for name_server_item in "${name_server_list[@]}"; do
	# strip whitespace from start and end of lan_network_item
	name_server_item=$(echo "${name_server_item}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')

	echo "[INFO] Adding ${name_server_item} to resolv.conf" | ts "$timestamp_format"
	echo "nameserver ${name_server_item}" >> /etc/resolv.conf
done

if [[ -z "${PUID}" ]]; then
	echo "[INFO] PUID not defined. Defaulting to root user" | ts "$timestamp_format"
	export PUID="root"
fi

if [[ -z "${PGID}" ]]; then
	echo "[INFO] PGID not defined. Defaulting to root group" | ts "$timestamp_format"
	export PGID="root"
fi

if [[ $VPN_ENABLED == "1" || $VPN_ENABLED == "true" || $VPN_ENABLED == "yes" ]]; then
	echo "[INFO] Starting WireGuard..." | ts "$timestamp_format"
	cd /config/wireguard
	if ip link | grep -q "$(basename -s .conf "$VPN_CONFIG")"; then
		wg-quick down "$VPN_CONFIG" || echo "WireGuard is down already" | ts "$timestamp_format" # Run wg-quick down as an extra safeguard in case WireGuard is still up for some reason
		sleep 1 # Just to give WireGuard a bit to go down
	fi
	wg-quick up "$VPN_CONFIG"
	exec /bin/bash /etc/qbittorrent/iptables.sh
else
	echo "[WARNIG] @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@" | ts "$timestamp_format"
	echo "[WARNIG] THE CONTAINER IS RUNNING WITH VPN DISABLED" | ts "$timestamp_format"
	echo "[WARNIG] PLEASE MAKE SURE VPN_ENABLED IS SET TO 'yes'" | ts "$timestamp_format"
	echo "[WARNIG] IF THIS IS INTENTIONAL, YOU CAN IGNORE THIS" | ts "$timestamp_format"
	echo "[WARNIG] @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@" | ts "$timestamp_format"
	exec /bin/bash /etc/qbittorrent/start.sh
fi
