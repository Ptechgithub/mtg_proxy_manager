#!/bin/bash

# =========================
# MTG v1 & v2 Manager Script
# =========================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
REST='\033[0m'
LINE="==============================="

SERVICE_NAME_V1="mtg-v1"
INSTALL_PATH_V1="/usr/local/bin/${SERVICE_NAME_V1}"
SYSTEMD_UNIT_V1="/etc/systemd/system/${SERVICE_NAME_V1}.service"
PROXY_INFO_FILE="/etc/mtg-v1.proxy"

SERVICE_NAME_V2="mtg-v2"
INSTALL_PATH_V2="/usr/local/bin/${SERVICE_NAME_V2}"
SYSTEMD_UNIT_V2="/etc/systemd/system/${SERVICE_NAME_V2}.service"
CONFIG_FILE="/etc/mtg.toml"

# =======================
# Root check
# =======================
if [ "$EUID" -ne 0 ]; then
	echo -e "${RED}Please run as root${REST}"
	exit 1
fi

# ======================
# Detect OS and package manager
# ======================
detect_os_pm() {
	UNAME=$(uname | tr '[:upper:]' '[:lower:]')
	case "$UNAME" in
	linux)
		OS="linux"
		if [ -f /etc/debian_version ]; then
			PM="apt"
			UPDATE_CMD="apt update -y"
			INSTALL_CMD="apt install -y"
		elif [ -f /etc/redhat-release ] || [ -f /etc/centos-release ] || [ -f /etc/almalinux-release ] || [ -f /etc/rocky-release ]; then
			PM="yum"
			UPDATE_CMD="yum makecache -y"
			INSTALL_CMD="yum install -y"
		elif [ -f /etc/arch-release ]; then
			PM="pacman"
			UPDATE_CMD="pacman -Sy"
			INSTALL_CMD="pacman -S --noconfirm"
		else
			echo -e "${GREEN}${LINE}"
			echo -e "${RED}Unsupported Linux distribution${REST}"
			exit 1
		fi
		;;
	darwin)
		OS="darwin"
		PM="brew"
		UPDATE_CMD="brew update"
		INSTALL_CMD="brew install"
		;;
	freebsd)
		OS="freebsd"
		PM="pkg"
		UPDATE_CMD="pkg update"
		INSTALL_CMD="pkg install -y"
		;;
	*)
		echo -e "${GREEN}${LINE}"
		echo -e "${RED}Unsupported OS: $UNAME${REST}"
		exit 1
		;;
	esac
	echo -e "${GREEN}${LINE}"
	echo -e "${CYAN}OS: $OS"
}

# =======================
# Detect architecture
# =======================
detect_arch() {
	detect_os_pm
	ARCH=$(uname -m)
	case "$ARCH" in
	x86_64) ARCH="amd64" ;;
	aarch64 | arm64) ARCH="arm64" ;;
	armv7l) ARCH="armv7" ;;
	armv6l) ARCH="armv6" ;;
	i386 | i686) ARCH="386" ;;
	*)
		echo -e "${RED}Unsupported architecture: $ARCH${REST}"
		exit 1
		;;
	esac
	echo -e "${CYAN}Architecture: $ARCH${REST}"
}

# ======================
# Check Dependencies
# ======================
install_dependencies() {
	detect_arch
	local deps=("openssl" "curl" "wget" "tar")
	local missing=()

	for dep in "${deps[@]}"; do
		if ! command -v "$dep" >/dev/null 2>&1; then
			missing+=("$dep")
		fi
	done

	if [ ${#missing[@]} -eq 0 ]; then
		echo -e "${CYAN}Dependencies are installed.${REST}"
		return
	fi
	echo -e "${YELLOW}Installing missing tools: ${missing[*]}...${REST}"
	$UPDATE_CMD >/dev/null 2>&1

	for dep in "${missing[@]}"; do
		$INSTALL_CMD "$dep"
		if [ $? -eq 0 ]; then
			echo -e "${GREEN}$dep installed successfully.${REST}"
		else
			echo -e "${RED}Failed to install $dep. Please install manually.${REST}"
		fi
	done

	echo -e "${GREEN}Dependencies check complete!${REST}"
}

# =======================
# Check if MTG is installed
# =======================
is_installed_v1() {
	[ -f "$INSTALL_PATH_V1" ] && [ -f "$SYSTEMD_UNIT_V1" ]
}

is_installed_v2() {
	[ -f "$INSTALL_PATH_V2" ] && [ -f "$SYSTEMD_UNIT_V2" ]
}

# =======================
# Download MTG Bin
# =======================
download_mtg() {
	local version_type=$1
	install_dependencies
	local VERSION URL

	if [ "$version_type" = "v1" ]; then
		VERSION="1.0.11"
	elif [ "$version_type" = "v2" ]; then
		local LATEST
		LATEST=$(curl -s "https://api.github.com/repos/9seconds/mtg/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')
		if [ -z "$LATEST" ]; then
			echo -e "${RED}Could not fetch latest version${REST}"
			exit 1
		fi
		VERSION=${LATEST#v}
	else
		echo -e "${RED}Unknown version type: $version_type${REST}"
		return 1
	fi

	URL="https://github.com/9seconds/mtg/releases/download/v${VERSION}/mtg-${VERSION}-${OS}-${ARCH}.tar.gz"
	[ "$version_type" = "v2" ] && URL="https://github.com/9seconds/mtg/releases/download/v${VERSION}/mtg-${VERSION}-${OS}-${ARCH}.tar.gz"
	TMPDIR=$(mktemp -d)

	echo -e "${GREEN}${LINE}"
	echo -e "Downloading MTG $version_type v${VERSION}..."

	wget -q -O "$TMPDIR/mtg.tar.gz" "$URL" || {
		echo -e "${RED}Download failed${REST}"
		rm -rf "$TMPDIR"
		exit 1
	}

	if [ ! -s "$TMPDIR/mtg.tar.gz" ]; then
		echo -e "${RED}Downloaded file is empty or corrupted${REST}"
		rm -rf "$TMPDIR"
		exit 1
	fi

	tar -xzf "$TMPDIR/mtg.tar.gz" -C "$TMPDIR"
	local MTG_BIN
	MTG_BIN=$(find "$TMPDIR" -type f -name mtg | head -n1)

	if [ -z "$MTG_BIN" ]; then
		echo -e "${RED}Binary extraction failed${REST}"
		rm -rf "$TMPDIR"
		exit 1
	fi

	if [ "$version_type" = "v1" ]; then
		mv "$MTG_BIN" "$INSTALL_PATH_V1"
		chmod +x "$INSTALL_PATH_V1"
		INSTALL_PATH="$INSTALL_PATH_V1"
	else
		mv "$MTG_BIN" "$INSTALL_PATH_V2"
		chmod +x "$INSTALL_PATH_V2"
		INSTALL_PATH="$INSTALL_PATH_V2"
	fi

	rm -rf "$TMPDIR"

	echo -e "${GREEN}Installed at $INSTALL_PATH${REST}"
	echo -e "${GREEN}${LINE}${REST}"
}

# =======================
# Start systemd service and check status
# =======================
start_and_check_service() {
	local service_name=$1
	local sleep_time=${2:-2}

	systemctl daemon-reload >/dev/null 2>&1
	systemctl enable "$service_name" >/dev/null 2>&1
	systemctl restart "$service_name" >/dev/null 2>&1
	sleep "$sleep_time"

	# Check if the service is active
	STATUS=$(systemctl is-active "$service_name")
	if [ "$STATUS" != "active" ]; then
		echo -e "${RED}Failed to start $service_name service! Status: $STATUS${REST}"
		echo -e "${RED}Check logs: journalctl -u $service_name${REST}"
		exit 1
	fi

	echo -e "${GREEN}${LINE}"
	echo -e "${GREEN}$service_name service restarted.${REST}"
}

# =======================
# Start systemd service and check status
# =======================
setup_and_run_v1() {
	echo -en "${CYAN}Enter Port [default 443]: ${REST}"
	read -r PORT
	PORT=${PORT:-443}

	if ! echo "$PORT" | grep -Eq '^[0-9]+$'; then
		echo -e "${RED}Invalid port! Must be a number.${REST}"
		exit 1
	fi

	if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
		echo -e "${RED}Invalid port! Must be 1-65535.${REST}"
		exit 1
	fi

	DEFAULT_IP=$(curl -s https://api.ipify.org)
	echo -en "${CYAN}Enter IPv4 [default $DEFAULT_IP]: ${REST}"
	read -r PUBLIC_IP
	PUBLIC_IP=${PUBLIC_IP:-$DEFAULT_IP}

	if ! echo "$PUBLIC_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
		echo -e "${RED}Invalid IPv4 address!${REST}"
		exit 1
	fi

	echo -e "${CYAN}Choose secret mode:${REST}"
	echo -e "${CYAN}1) simple  - Supports sponsorship tag [default]${REST}"
	echo -e "${CYAN}2) secured - random padding${REST}"
	echo -e "${CYAN}3) fake TLS - more obfuscated${REST}"
	echo -en "${GREEN}Enter choice [1-3]: ${REST}"
	read -r mode_choice

	case "$mode_choice" in
	2) SECRET_MODE="secured" ;;
	3) SECRET_MODE="tls" ;;
	*) SECRET_MODE="simple" ;;
	esac

	CLOAK_HOST=""
	if [ "$SECRET_MODE" = "tls" ]; then
		echo -en "${CYAN}Enter TLS cloak-host [default google.com]: ${REST}"
		read -r CLOAK_HOST
		CLOAK_HOST=${CLOAK_HOST:-google.com}
	fi

	echo -en "${CYAN}Enter Secret (optional – press Enter to auto-generate): ${REST}"
	read -r USER_SECRET

	if [ -n "$USER_SECRET" ]; then
		SECRET="$USER_SECRET"
		echo -e "${GREEN}Using user-provided secret: ${YELLOW}$SECRET${REST}"
	else
		if [ "$SECRET_MODE" = "tls" ]; then
			SECRET=$($INSTALL_PATH_V1 generate-secret tls --cloak-host="$CLOAK_HOST")
			echo -e "${GREEN}Generated secret (tls, cloak-host=$CLOAK_HOST): ${YELLOW}$SECRET${REST}"
		else
			SECRET=$($INSTALL_PATH_V1 generate-secret "$SECRET_MODE")
			echo -e "${GREEN}Generated secret ($SECRET_MODE): ${YELLOW}$SECRET${REST}"
		fi
	fi

	TAG=""
	echo -e "${YELLOW}${LINE}${REST}"
	echo -e "${YELLOW}[⚠ Notice:]${REST}"
	echo -e "${YELLOW}[Sponsored channel is NOT visible to admins.]${REST}"
	echo -e "${YELLOW}[It is NOT visible to users already in the channel.]${REST}"
	echo -e "${YELLOW}[Get your sponsorship tag from @MTProxybot]${REST}"
	echo -e "${YELLOW}${LINE}${REST}"
	echo -en "${CYAN}Enter Tag (optional, press Enter to skip): ${REST}"
	read -r TAG

	cat <<EOL >"$PROXY_INFO_FILE"
PORT=${PORT}
PUBLIC_IP=${PUBLIC_IP}
SECRET=${SECRET}
TAG=${TAG}
SECRET_MODE=${SECRET_MODE}
CLOAK_HOST=${CLOAK_HOST}
EOL
	chmod 600 "$PROXY_INFO_FILE"

	CMD="$INSTALL_PATH_V1 run -b 0.0.0.0:${PORT} --public-ipv4 ${PUBLIC_IP}:${PORT} $SECRET"
	[ -n "$TAG" ] && CMD="$CMD $TAG"

	cat <<EOL >"$SYSTEMD_UNIT_V1"
[Unit]
Description=MTG v1 MTProto Proxy
After=network.target

[Service]
ExecStart=$CMD
Restart=always
RestartSec=3
User=root
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOL

	start_and_check_service "$SERVICE_NAME_V1"

	TME_URL="https://t.me/proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${SECRET}"
	echo -e "${GREEN}${LINE}"
	echo -e "Your MTProto Proxy URL: ${PURPLE}$TME_URL${REST}"
	echo -e "${GREEN}${LINE}${REST}"
}

# =======================
# Generate config v2
# =======================
generate_config_v2() {
	echo -en "${CYAN}Enter Port [default 8443]: ${REST}"
	read -r PORT
	PORT=${PORT:-8443}
	BIND="0.0.0.0:${PORT}"

	echo -en "${CYAN}Domain fronting host [default google.com]: ${REST}"
	read -r DF_HOST
	DF_HOST=${DF_HOST:-google.com}

	if [ ! -x "$INSTALL_PATH_V2" ]; then
		echo -e "${RED}MTG v2 binary not found or not executable.${REST}"
		exit 1
	fi

	SECRET=$($INSTALL_PATH_V2 generate-secret "$DF_HOST" -x)

	cat <<EOL >"$CONFIG_FILE"
debug = true
secret = "$SECRET"
bind-to = "$BIND"
concurrency = 8192
prefer-ip = "prefer-ipv6"
domain-fronting-port = $PORT
# By default we use Quad9.
doh-ip = "9.9.9.9"

[defense.anti-replay]
enabled = true
max-size = "1mib"
error-rate = 0.001

[defense.blocklist]
enabled = true
download-concurrency = 2
urls = ["https://iplists.firehol.org/files/firehol_level1.netset"]
update-each = "24h"
EOL
}

# =======================
# Setup systemd v2
# =======================
setup_service_v2() {
	cat <<EOL >"$SYSTEMD_UNIT_V2"
[Unit]
Description=MTG v2
After=network.target

[Service]
ExecStart=$INSTALL_PATH_V2 run $CONFIG_FILE
Restart=always
RestartSec=3
User=root
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOL

	start_and_check_service "$SERVICE_NAME_V2"
}

# =======================
# Change Tag v1
# =======================
change_tag_v1() {
	if [ ! -f "$PROXY_INFO_FILE" ]; then
		echo -e "${RED}MTG v1 is not installed.${REST}"
		return
	fi

	source "$PROXY_INFO_FILE"

	echo -en "${CYAN}Current Tag: ${PURPLE}${TAG:-N/A}${REST}\n"
	echo -en "${CYAN}Enter new Tag (leave empty to remove): ${REST}"
	read -r NEW_TAG

	TAG="$NEW_TAG"
	cat <<EOL >"$PROXY_INFO_FILE"
PORT=${PORT}
PUBLIC_IP=${PUBLIC_IP}
SECRET=${SECRET}
TAG=${TAG}
EOL
	chmod 600 "$PROXY_INFO_FILE"

	CMD="$INSTALL_PATH_V1 run -b 0.0.0.0:${PORT} --public-ipv4 ${PUBLIC_IP}:${PORT} $SECRET"
	[ -n "$TAG" ] && CMD="$CMD $TAG"

	cat <<EOL >"$SYSTEMD_UNIT_V1"
[Unit]
Description=MTG v1
After=network.target

[Service]
ExecStart=$CMD
Restart=always
RestartSec=3
User=root
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOL

	start_and_check_service "$SERVICE_NAME_V1"
	echo -e "${GREEN}Tag updated successfully.${REST}"
	[ -n "$TAG" ] && echo -e "${GREEN}New Tag: ${PURPLE}$TAG${REST}"
}

# =======================
# Check Status
# =======================
check_status() {
	local version_type=$1
	local config_file service_name BIND PORT SECRET TAG

	if [ "$version_type" = "v1" ]; then
		if ! is_installed_v1; then
			echo -e "${RED}MTG v1 is not installed.${REST}"
			return
		fi
		config_file="/etc/mtg-v1.proxy"
		service_name="$SERVICE_NAME_V1"
	elif [ "$version_type" = "v2" ]; then
		if ! is_installed_v2; then
			echo -e "${RED}MTG v2 is not installed.${REST}"
			return
		fi
		config_file="/etc/mtg.toml"
		service_name="$SERVICE_NAME_V2"
	else
		echo -e "${RED}Unknown version type: $version_type${REST}"
		return
	fi

	if ! [ -f "$config_file" ]; then
		echo -e "${RED}Config file not found: $config_file${REST}"
		return
	fi

	# Read config values
	if [ "$version_type" = "v1" ]; then
		source "$config_file"
	else
		BIND=$(grep -m1 '^bind-to =' "$config_file" | cut -d'"' -f2)
		PORT=${BIND##*:}
		SECRET=$(grep -m1 '^secret =' "$config_file" | cut -d'"' -f2)
	fi

	STATUS=$(systemctl is-active "$service_name" 2>/dev/null)
	case "$STATUS" in
	active) ;;
	activating) ;;
	inactive) ;;
	failed) ;;
	*) STATUS="unknown" ;;
	esac

	echo -e "${CYAN}${LINE}"
	echo -e "${CYAN}Service Status: ${PURPLE}$STATUS${REST}"
	if [ "$version_type" = "v1" ]; then
		echo -e "${CYAN}Public IP: ${PURPLE}${PUBLIC_IP:-N/A}${REST}"
		echo -e "${CYAN}Port: ${PURPLE}${PORT}${REST}"
		echo -e "${CYAN}Secret: ${PURPLE}${SECRET:-N/A}${REST}"
		[ -n "$TAG" ] && echo -e "${CYAN}Tag: ${PURPLE}$TAG${REST}"
	else
		echo -e "${CYAN}Bind Address: ${PURPLE}$BIND${REST}"
		echo -e "${CYAN}Port: ${PURPLE}$PORT${REST}"
		echo -e "${CYAN}Secret: ${PURPLE}${SECRET:-N/A}${REST}"
	fi
	echo -e "${CYAN}${LINE}${REST}"
}

# =======================
# Show Proxy v1
# =======================
show_proxy_v1() {
	if [ ! -f "$PROXY_INFO_FILE" ]; then
		echo -e "${RED}MTG is not installed.${REST}"
		return
	fi

	source "$PROXY_INFO_FILE"

	echo -e "${GREEN}${LINE}"
	echo -e "Your MTProto Proxy URL:"

	# Telegram format
	TME_URL="https://t.me/proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${SECRET}"
	echo -e "${GREEN}Proxy Link: ${PURPLE}${TME_URL}${REST}"
	echo -e "${GREEN}${LINE}${REST}"
	# Optional Tag
	[ -n "$TAG" ] && echo -e "${GREEN}Tag: ${PURPLE}${TAG}${REST}"

	echo -e "${GREEN}${LINE}${REST}"
}
# =======================
# Show Proxy v2
# =======================
show_proxy_v2() {
	if ! is_installed_v2; then
		echo -e "${RED}MTG is not installed.${REST}"
		return
	fi

	LOCAL_IP=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d'/' -f1 | head -n1)
	TME_URL=$($INSTALL_PATH_V2 access "$CONFIG_FILE" -i "$LOCAL_IP" 2>/dev/null | grep '"tme_url"' | cut -d'"' -f4)

	if [ -z "$TME_URL" ]; then
		echo -e "${RED}Could not retrieve proxy URL. Make sure MTG is running.${REST}"
		return
	fi

	echo -e "${GREEN}${LINE}"
	echo -e "Your MTProto Proxy:"
	echo -e "${PURPLE}$TME_URL${REST}"
	echo -e "${GREEN}${LINE}${REST}"
}

# =====================
# Generate Secret
# =====================
generate_secret_menu() {
	if ! is_installed_v1; then
		echo -e "${RED}MTG is not installed.${REST}"
		return
	fi

	echo -e "${CYAN}Choose secret mode:${REST}"
	echo -e "${CYAN}1) simple${REST}"
	echo -e "${CYAN}2) secured${REST}"
	echo -e "${CYAN}3) tls${REST}"
	echo -en "${GREEN}Enter choice [1-3]: ${REST}"
	read -r mode_choice

	case "$mode_choice" in
	2) SECRET_MODE="secured" ;;
	3) SECRET_MODE="tls" ;;
	*) SECRET_MODE="simple" ;;
	esac

	SECRET=$($INSTALL_PATH_V1 generate-secret "$SECRET_MODE")

	echo -e "${GREEN}Secret ($SECRET_MODE): ${YELLOW}$SECRET${REST}"
}

# =====================
# Uninstall v1 || v2
# =====================
uninstall_mtg() {
	local version=$1

	if [ "$version" = "v1" ]; then
		local service_name="$SERVICE_NAME_V1"
		local systemd_unit="$SYSTEMD_UNIT_V1"
		local binary="$INSTALL_PATH_V1"
		local config="$PROXY_INFO_FILE"
	elif [ "$version" = "v2" ]; then
		local service_name="$SERVICE_NAME_V2"
		local systemd_unit="$SYSTEMD_UNIT_V2"
		local binary="$INSTALL_PATH_V2"
		local config="$CONFIG_FILE"
	else
		echo -e "${RED}Unknown version: $version${REST}"
		return
	fi

	if ! [ -f "$binary" ] && ! [ -f "$systemd_unit" ]; then
		echo -e "${RED}MTG $version is not installed.${REST}"
		return
	fi

	systemctl stop "$service_name" >/dev/null 2>&1
	systemctl disable "$service_name" >/dev/null 2>&1
	rm -f "$systemd_unit" "$binary" "$config"
	systemctl daemon-reload >/dev/null 2>&1

	echo -e "${CYAN}${LINE}${REST}"
	echo -e "${GREEN}MTG $version uninstalled successfully.${REST}"
	echo -e "${CYAN}${LINE}${REST}"
}

# =====================
# Menu v1
# =====================
menu_v1() {
	while true; do
		clear
		printf "${CYAN}╔════════════════════════╗\n"
		printf "║ %-22s ║\n" "    MTG v1 Manager"
		printf "╠═════╦══════════════════╣\n"
		printf "║ %-3s ║ %-16s ║\n" "1" "Install MTG v1"
		printf "║ %-3s ║ %-16s ║\n" "2" "Check Status"
		printf "║ %-3s ║ %-16s ║\n" "3" "Show Proxy"
		printf "║ %-3s ║ %-16s ║\n" "4" "Change Tag"
		printf "║ %-3s ║ %-16s ║\n" "5" "Generate Secret"
		printf "║ %-3s ║ %-16s ║\n" "6" "Uninstall"
		printf "║ %-3s ║ %-16s ║\n" "0" "Back"
		printf "╚═════╩══════════════════╝${REST}\n"

		echo -en "${GREEN}Choice: ${REST}"
		read -r choice

		case $choice in
		1)
			if is_installed_v1; then
				echo -e "${GREEN}${LINE}"
				echo -e "${RED}MTG v1 is already installed.${REST}"
			else
				download_mtg "v1"
				setup_and_run_v1
			fi
			read -rp "Press Enter..."
			;;
		2)
			check_status "v1"
			read -rp "Press Enter..."
			;;
		3)
			show_proxy_v1
			read -rp "Press Enter..."
			;;
		4)
			change_tag_v1
			read -rp "Press Enter..."
			;;
		5)
			generate_secret_menu
			read -rp "Press Enter..."
			;;
		6)
			uninstall_mtg "v1"
			read -rp "Press Enter..."
			;;
		0) break ;;
		*)
			echo -e "${RED}Invalid Choice!${REST}"
			sleep 1
			;;
		esac
	done
}

# =====================
# Menu v2
# =====================
menu_v2() {
	while true; do
		clear
		printf "${CYAN}╔════════════════════════╗\n"
		printf "║ %-22s ║\n" "    MTG v2 Manager"
		printf "╠═════╦══════════════════╣\n"
		printf "║ %-3s ║ %-16s ║\n" "1" "Install MTG v2"
		printf "║ %-3s ║ %-16s ║\n" "2" "Check Status"
		printf "║ %-3s ║ %-16s ║\n" "3" "Show Proxy"
		printf "║ %-3s ║ %-16s ║\n" "4" "Uninstall"
		printf "║ %-3s ║ %-16s ║\n" "0" "Back"
		printf "╚═════╩══════════════════╝${REST}\n"

		echo -en "${GREEN}Choice: ${REST}"
		read -r choice

		case $choice in
		1)
			if is_installed_v2; then
				echo -e "${GREEN}${LINE}"
				echo -e "${RED}MTG v2 is already installed.${REST}"
			else
				download_mtg "v2"
				generate_config_v2
				setup_service_v2
				show_proxy_v2
			fi
			read -rp "Press Enter..."
			;;
		2)
			check_status "v2"
			read -rp "Press Enter..."
			;;
		3)
			show_proxy_v2
			read -rp "Press Enter..."
			;;
		4)
			uninstall_mtg "v2"
			read -rp "Press Enter..."
			;;
		0) break ;;
		*)
			echo -e "${RED}Invalid Choice!${REST}"
			sleep 1
			;;
		esac
	done
}

# =====================
# Main menu
# =====================
while true; do
	clear
	printf "%bBy --> Peyman • github.com/Ptechgithub%b\n\n" "$CYAN" "$REST"
	printf "${CYAN}╔════════════════════════╗\n"
	printf "║ %-22s ║\n" "     MTG Manager"
	printf "╠═════╦══════════════════╩════════╗\n"
	printf "║ %-3s ║ %-25s ║\n" "1" "Version 1 (AdTag Support)"
	printf "║ %-3s ║ %-25s ║\n" "2" "Version 2 (Latest)"
	printf "║ %-3s ║ %-25s ║\n" "0" "Exit"
	printf "╚═════╩═══════════════════════════╝${REST}\n"

	echo -en "${GREEN}Choice: ${REST}"
	read -r main_choice

	case $main_choice in
	1) menu_v1 ;;
	2) menu_v2 ;;
	0) exit 0 ;;
	*)
		echo -e "${RED}Invalid Choice!${REST}"
		sleep 1
		;;
	esac
done
