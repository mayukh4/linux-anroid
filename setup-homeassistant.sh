#!/data/data/com.termux/files/usr/bin/bash
#######################################################
#  Home Assistant Core — Smart Home Server Setup
#
#  Installs Home Assistant Core inside a proot-distro
#  Ubuntu container on Termux. No root required.
#
#  What you get:
#  - Home Assistant Core running on your phone
#  - Web dashboard accessible from any device on your network
#  - Control WiFi smart lights/plugs (TP-Link Kasa, Tuya, etc.)
#  - Start/stop scripts for easy management
#
#  Requires: Termux on arm64 Android, ~3 GB free storage
#######################################################

set -o pipefail

# ============== DYNAMIC PATH DETECTION ==============
TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TERMUX_HOME="${HOME:-/data/data/com.termux/files/home}"

# ============== CONFIGURATION ==============
CURRENT_STEP=0
TOTAL_STEPS=7

LOG_FILE="$TERMUX_HOME/termux-setup.log"

# ============== COLORS ==============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'
BOLD='\033[1m'

# ============== LOGGING ==============
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ============== PROGRESS BAR ==============
update_progress() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local PERCENT=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    local FILLED=$((PERCENT / 5))
    local EMPTY=$((20 - FILLED))

    local BAR="${GREEN}"
    for ((i=0; i<FILLED; i++)); do BAR+="█"; done
    BAR+="${GRAY}"
    for ((i=0; i<EMPTY; i++)); do BAR+="░"; done
    BAR+="${NC}"

    echo ""
    echo -e "${WHITE}────────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}  PROGRESS: ${WHITE}Step ${CURRENT_STEP}/${TOTAL_STEPS}${NC}  ${BAR}  ${WHITE}${PERCENT}%${NC}"
    echo -e "${WHITE}────────────────────────────────────────────────────────────${NC}"
    echo ""
}

# ============== SPINNER ==============
spinner() {
    local pid=$1
    local message=$2
    local spin=('⠋' '⠙' '⠸' '⠴' '⠦' '⠇')
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}${spin[$i]}${NC}  %s  " "$message"
        i=$(( (i + 1) % 6 ))
        sleep 0.1
    done

    wait "$pid"
    local exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        printf "\r  ${GREEN}✔${NC}  %-55s\n" "$message"
        log "OK: $message"
    else
        printf "\r  ${RED}✘${NC}  %-55s ${RED}(failed — see $LOG_FILE)${NC}\n" "$message"
        log "FAILED: $message"
    fi

    return "$exit_code"
}

# ============== TERMUX PACKAGE INSTALLER ==============
safe_install_pkg() {
    local pkg=$1
    local name=${2:-$pkg}

    if dpkg -s "$pkg" &>/dev/null; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already installed)${NC}\n" "$name"
        log "SKIP (already installed): $pkg"
        return 0
    fi

    local conflicts
    conflicts=$(apt-cache show "$pkg" 2>/dev/null \
        | grep -i "^Conflicts:" \
        | sed 's/^Conflicts://i' \
        | tr ',' '\n' \
        | awk '{print $1}')

    for conflict in $conflicts; do
        [ -z "$conflict" ] && continue
        if dpkg -s "$conflict" &>/dev/null; then
            printf "  ${YELLOW}⚠${NC}  %-55s ${YELLOW}(skipped — conflicts with: %s)${NC}\n" \
                "$name" "$conflict"
            log "SKIP (conflict with $conflict): $pkg"
            return 0
        fi
    done

    (DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::="--force-confold" \
        "$pkg" >> "$LOG_FILE" 2>&1) &
    spinner $! "Installing ${name}..."
}

# ============== PROOT UBUNTU PACKAGE INSTALLER ==============
proot_install_pkg() {
    local pkg=$1
    local name=${2:-$pkg}

    # Check if already installed inside the proot
    if proot-distro login ubuntu -- dpkg -s "$pkg" &>/dev/null; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already installed)${NC}\n" "$name"
        log "SKIP (already installed in Ubuntu): $pkg"
        return 0
    fi

    (proot-distro login ubuntu -- bash -c \
        "DEBIAN_FRONTEND=noninteractive apt-get install -y '$pkg'" \
        >> "$LOG_FILE" 2>&1) &
    spinner $! "Installing ${name} (Ubuntu)..."
}

# ============== BANNER ==============
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║                                                      ║
  ║        Home Assistant — Smart Home Server Setup      ║
  ║        Turn your phone into a smart home hub         ║
  ║                                                      ║
  ╚══════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
    echo -e "${GRAY}  Detailed logs → $LOG_FILE${NC}"
    echo ""
}

# ============== PRE-FLIGHT CHECKS ==============
preflight_checks() {
    log "=== Home Assistant setup started ==="

    echo -e "${PURPLE}[*] Checking prerequisites...${NC}"
    echo ""

    # Check architecture
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "aarch64" && "$arch" != "arm64" ]]; then
        echo -e "  ${RED}✘ Unsupported architecture: ${arch}${NC}"
        echo -e "    ${WHITE}Home Assistant requires a 64-bit ARM device.${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✔${NC}  Architecture: ${WHITE}${arch}${NC}"

    # Check available storage (need ~3 GB)
    local free_mb
    free_mb=$(df -m "$TERMUX_HOME" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$free_mb" ] && [ "$free_mb" -lt 2500 ]; then
        echo -e "  ${YELLOW}⚠${NC}  Free storage: ${YELLOW}${free_mb} MB${NC} (3000 MB+ recommended)"
        echo ""
        echo -e "  ${WHITE}You might run out of space during installation.${NC}"
        echo -e "  ${WHITE}Continue anyway? (y/n)${NC}"
        read -rp "  " CONTINUE_INPUT
        if [[ ! "$CONTINUE_INPUT" =~ ^[Yy] ]]; then
            echo -e "  ${RED}Aborted.${NC}"
            exit 1
        fi
    else
        echo -e "  ${GREEN}✔${NC}  Free storage: ${WHITE}${free_mb:-unknown} MB${NC}"
    fi

    # Check network connectivity
    if ping -c 1 -W 3 google.com &>/dev/null; then
        echo -e "  ${GREEN}✔${NC}  Network: ${WHITE}Connected${NC}"
    else
        echo -e "  ${RED}✘ No internet connection detected.${NC}"
        echo -e "    ${WHITE}This script requires an internet connection to download packages.${NC}"
        exit 1
    fi

    # Detect phone IP for later
    PHONE_IP=$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    if [ -z "$PHONE_IP" ]; then
        PHONE_IP="<your-phone-ip>"
    fi

    echo ""
    log "Preflight OK: arch=$arch, free=${free_mb}MB, ip=$PHONE_IP"
}

# ============== STEP 1: INSTALL PROOT-DISTRO ==============
step_proot() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing proot-distro...${NC}"
    echo ""

    safe_install_pkg "proot-distro" "proot-distro (Linux container manager)"
    safe_install_pkg "proot"        "proot (user-space chroot)"
}

# ============== STEP 2: INSTALL UBUNTU ==============
step_ubuntu() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Setting up Ubuntu 24.04 container...${NC}"
    echo ""

    # Check if Ubuntu is already installed
    if proot-distro list 2>/dev/null | grep -q "ubuntu.*Installed"; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already installed)${NC}\n" "Ubuntu 24.04"
        log "SKIP (already installed): Ubuntu proot"
    else
        (proot-distro install ubuntu >> "$LOG_FILE" 2>&1) &
        spinner $! "Downloading and installing Ubuntu 24.04..."
    fi

    # Update package lists inside Ubuntu
    (proot-distro login ubuntu -- bash -c \
        "DEBIAN_FRONTEND=noninteractive apt-get update -y" \
        >> "$LOG_FILE" 2>&1) &
    spinner $! "Updating Ubuntu package lists..."
}

# ============== STEP 3: INSTALL UBUNTU DEPENDENCIES ==============
step_ubuntu_deps() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing build dependencies in Ubuntu...${NC}"
    echo ""

    proot_install_pkg "python3"        "Python 3"
    proot_install_pkg "python3-pip"    "pip"
    proot_install_pkg "python3-venv"   "Python venv"
    proot_install_pkg "python3-dev"    "Python dev headers"
    proot_install_pkg "build-essential" "Build tools (gcc, make, etc.)"
    proot_install_pkg "libffi-dev"     "libffi (foreign function interface)"
    proot_install_pkg "libssl-dev"     "OpenSSL development headers"
    proot_install_pkg "libjpeg-dev"    "JPEG library"
    proot_install_pkg "zlib1g-dev"     "zlib compression library"
    proot_install_pkg "autoconf"       "Autoconf"
    proot_install_pkg "cargo"          "Rust/Cargo (for cryptography)"
    proot_install_pkg "pkg-config"     "pkg-config"
}

# ============== STEP 4: INSTALL HOME ASSISTANT ==============
step_homeassistant() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Home Assistant Core...${NC}"
    echo ""
    echo -e "  ${YELLOW}This step compiles native extensions and may take 15–30 minutes.${NC}"
    echo -e "  ${YELLOW}Keep your screen on or use termux-wake-lock.${NC}"
    echo ""

    # Create venv if it doesn't exist
    if proot-distro login ubuntu -- test -d "${TERMUX_HOME}/hass-venv"; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already exists)${NC}\n" "Python virtual environment"
    else
        (proot-distro login ubuntu -- python3 -m venv "${TERMUX_HOME}/hass-venv" \
            >> "$LOG_FILE" 2>&1) &
        spinner $! "Creating Python virtual environment..."
    fi

    # Upgrade pip inside the venv
    # NOTE: Call venv binaries directly — "source activate" fails inside proot
    (proot-distro login ubuntu -- ${TERMUX_HOME}/hass-venv/bin/pip install --upgrade pip wheel setuptools \
        >> "$LOG_FILE" 2>&1) &
    spinner $! "Upgrading pip and setuptools..."

    # Install Home Assistant Core.
    # HA lazy-loads many components whose deps aren't pulled in by pip.
    # We explicitly install the ones needed for the core UI to function.
    (proot-distro login ubuntu -- ${TERMUX_HOME}/hass-venv/bin/pip install \
        homeassistant \
        hassil home-assistant-intents pyspeex-noise \
        numpy av mutagen pymicro-vad ha-ffmpeg PyTurboJPEG PyNaCl \
        cached-ipaddress file-read-backwards go2rtc-client async-upnp-client \
        >> "$LOG_FILE" 2>&1) &
    spinner $! "Installing Home Assistant Core (this takes a while)..."

    # Patch ifaddr: Android 10+ blocks getifaddrs() inside proot, causing
    # PermissionError in HA's network detection. We patch the library to
    # return an empty adapter list instead of crashing. HA still works fine
    # because we explicitly set server_host in configuration.yaml.
    local IFADDR_POSIX="${TERMUX_HOME}/hass-venv/lib/python3.*/site-packages/ifaddr/_posix.py"
    proot-distro login ubuntu -- bash -c \
        "sed -i 's/        raise OSError(eno, os.strerror(eno))/        return []/g' ${IFADDR_POSIX}" \
        >> "$LOG_FILE" 2>&1
    echo -e "  ${GREEN}✔${NC}  Patched ifaddr for Android network compatibility."
}

# ============== STEP 5: INITIALIZE HA CONFIG ==============
step_ha_config() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Initializing Home Assistant config...${NC}"
    echo ""

    # Create config dir and write configuration.yaml directly.
    # We skip the "run HA once to generate config" approach — it's fragile
    # inside proot. Instead we create a minimal valid config ourselves.
    local HASS_CONFIG="${TERMUX_HOME}/hass-config"

    if proot-distro login ubuntu -- test -f "${HASS_CONFIG}/configuration.yaml"; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already exists)${NC}\n" "HA config directory"
    else
        proot-distro login ubuntu -- mkdir -p "${HASS_CONFIG}"
        echo -e "  ${GREEN}✔${NC}  Created config directory."
    fi

    # Ensure HA is accessible from the local network (not just localhost).
    # NOTE: must use double quotes so ${HASS_CONFIG} expands from Termux.
    if proot-distro login ubuntu -- grep -q "server_host" "${HASS_CONFIG}/configuration.yaml" 2>/dev/null; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already configured)${NC}\n" "Network binding (0.0.0.0)"
    else
        proot-distro login ubuntu -- sh -c "printf 'homeassistant:\nhttp:\n  server_host: 0.0.0.0\n' > ${HASS_CONFIG}/configuration.yaml"
        echo -e "  ${GREEN}✔${NC}  Configured HA to accept connections from your network."
    fi
}

# ============== STEP 6: CREATE LAUNCHER SCRIPTS ==============
step_launchers() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Creating start/stop scripts...${NC}"
    echo ""

    # start-homeassistant.sh
    # NOTE: proot-distro shares the Termux filesystem. The venv and config live
    # at the Termux home path, NOT at /root/. We bake the absolute path into
    # the script so ~ expansion can't break it.
    local HASS_BIN="${TERMUX_HOME}/hass-venv/bin/hass"
    local HASS_CFG="${TERMUX_HOME}/hass-config"

    cat > "$TERMUX_HOME/start-homeassistant.sh" << STARTEOF
#!${TERMUX_PREFIX}/bin/bash
echo ""
echo "[*] Starting Home Assistant Core..."
echo ""

if command -v termux-wake-lock &>/dev/null; then
    termux-wake-lock
    echo "[*] Wake lock acquired."
fi

PHONE_IP=\$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1)

echo "-----------------------------------------------------"
echo "  Home Assistant is starting up."
echo ""
echo "  First launch takes 5-10 minutes to initialize."
echo "  When ready, open in your browser:"
echo ""
echo "    http://\${PHONE_IP:-localhost}:8123"
echo ""
echo "  Press Ctrl+C to stop."
echo "-----------------------------------------------------"
echo ""

proot-distro login ubuntu -- "${HASS_BIN}" -c "${HASS_CFG}"
STARTEOF
    chmod +x "$TERMUX_HOME/start-homeassistant.sh"
    echo -e "  ${GREEN}✔ Created ~/start-homeassistant.sh${NC}"

    # stop-homeassistant.sh
    cat > "$TERMUX_HOME/stop-homeassistant.sh" << 'STOPEOF'
#!/data/data/com.termux/files/usr/bin/bash
echo "[*] Stopping Home Assistant..."

pkill -f "hass" 2>/dev/null || true

if command -v termux-wake-unlock &>/dev/null; then
    termux-wake-unlock
    echo "[*] Wake lock released."
fi

echo "[*] Home Assistant stopped."
STOPEOF
    chmod +x "$TERMUX_HOME/stop-homeassistant.sh"
    echo -e "  ${GREEN}✔ Created ~/stop-homeassistant.sh${NC}"
}

# ============== STEP 7: VERIFY INSTALLATION ==============
step_verify() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Verifying installation...${NC}"
    echo ""

    # Check that hass binary exists in the venv
    # NOTE: Call venv binaries directly — "source activate" fails inside proot
    if proot-distro login ubuntu -- ${TERMUX_HOME}/hass-venv/bin/hass --version &>/dev/null; then
        echo -e "  ${GREEN}✔${NC}  Home Assistant binary found."
        log "Verification OK: hass binary found"

        local HA_VERSION
        HA_VERSION=$(proot-distro login ubuntu -- ${TERMUX_HOME}/hass-venv/bin/hass --version 2>/dev/null)
        if [ -n "$HA_VERSION" ]; then
            echo -e "  ${GREEN}✔${NC}  Version: ${WHITE}${HA_VERSION}${NC}"
            log "HA version: $HA_VERSION"
        fi
    else
        echo -e "  ${RED}✘${NC}  Home Assistant binary not found."
        echo -e "    ${WHITE}Check $LOG_FILE for pip install errors.${NC}"
        log "FAILED: hass binary not found after install"
    fi

    # Check launcher scripts exist
    if [ -x "$TERMUX_HOME/start-homeassistant.sh" ]; then
        echo -e "  ${GREEN}✔${NC}  ~/start-homeassistant.sh is ready."
    fi
    if [ -x "$TERMUX_HOME/stop-homeassistant.sh" ]; then
        echo -e "  ${GREEN}✔${NC}  ~/stop-homeassistant.sh is ready."
    fi
}

# ============== COMPLETION ==============
show_completion() {
    echo ""
    echo -e "${GREEN}"
    cat << 'COMPLETE'
  ╔══════════════════════════════════════════════════════╗
  ║                                                      ║
  ║          ✔  HOME ASSISTANT INSTALLED!                ║
  ║                                                      ║
  ╚══════════════════════════════════════════════════════╝
COMPLETE
    echo -e "${NC}"

    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}▶  START:${NC}  ${GREEN}bash ~/start-homeassistant.sh${NC}"
    echo -e "  ${WHITE}■  STOP: ${NC}  ${GREEN}bash ~/stop-homeassistant.sh${NC}"
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${CYAN}Access the dashboard from any device on your network:${NC}"
    echo -e "    ${WHITE}http://${PHONE_IP}:8123${NC}"
    echo ""
    echo -e "  ${CYAN}First launch takes 5–10 minutes to initialize.${NC}"
    echo -e "  ${CYAN}You'll create your admin account in the browser.${NC}"
    echo ""
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}ADDING YOUR SMART DEVICES${NC}"
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${CYAN}TP-Link Kasa (smart lights/plugs):${NC}"
    echo -e "    1. Open HA dashboard → Settings → Devices & Services"
    echo -e "    2. Click \"+ Add Integration\" → search \"TP-Link Kasa\""
    echo -e "    3. Enter the device's IP address (find it in the Kasa app"
    echo -e "       under Device Settings → Device Info)"
    echo -e "    ${GRAY}mDNS auto-discovery is disabled on Android — you must add by IP.${NC}"
    echo ""
    echo -e "  ${CYAN}Tuya / Smart Life (smart lights/plugs):${NC}"
    echo -e "    1. Create a Tuya IoT developer account at:"
    echo -e "       ${WHITE}https://iot.tuya.com${NC}"
    echo -e "    2. Create a Cloud Project and link your Smart Life app"
    echo -e "    3. In HA: Settings → Devices → Add Integration → \"Tuya\""
    echo -e "    4. Enter your Access ID, Access Secret, and country code"
    echo -e "    ${GRAY}Tuya uses cloud API — works even without local network access.${NC}"
    echo ""
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}KEEPING HA RUNNING IN THE BACKGROUND${NC}"
    echo -e "${YELLOW}  ─────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  To keep Home Assistant running when you close Termux:"
    echo ""
    echo -e "    ${GREEN}termux-wake-lock${NC}"
    echo -e "    ${GREEN}nohup bash ~/start-homeassistant.sh > ~/hass.log 2>&1 &${NC}"
    echo ""
    echo -e "  ${GRAY}The start script already acquires a wake lock, but running it"
    echo -e "  with nohup ensures it survives Termux being backgrounded.${NC}"
    echo ""
    echo -e "  ${GRAY}Full install log: $LOG_FILE${NC}"
    echo ""
}

# ============== MAIN ==============
main() {
    log "setup-homeassistant.sh started"

    # Acquire wake lock
    if command -v termux-wake-lock &>/dev/null; then
        termux-wake-lock
        log "Wake lock acquired."
    else
        echo -e "${YELLOW}  [!] termux-wake-lock unavailable — keep your screen on during install.${NC}"
        echo ""
    fi

    show_banner
    preflight_checks

    step_proot
    step_ubuntu
    step_ubuntu_deps
    step_homeassistant
    step_ha_config
    step_launchers
    step_verify
    show_completion

    if command -v termux-wake-unlock &>/dev/null; then
        termux-wake-unlock
        log "Wake lock released."
    fi
}

main
