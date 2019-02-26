#!/bin/bash

######## VARIABLES #########

piguardGitUrl="https://github.com/orazioedoardo/pi-guard.git"

WG_SNAPSHOT="0.0.20190123"
WG_SOURCE="https://git.zx2c4.com/WireGuard/snapshot/WireGuard-${WG_SNAPSHOT}.tar.xz"
WG_PATH="/etc/wireguard"

PKG_INSTALL="apt-get --no-install-recommends install -y"
PKG_CACHE="/var/lib/apt/lists/"
PKG_SOURCES="/etc/apt/sources.list"

dhcpcdFile="/etc/dhcpcd.conf"
setupVars="/etc/pi-guard/setupVars.conf"

UNATTUPG_RELEASE="1.9"
UNATTUPG_CONFIG="https://github.com/mvo5/unattended-upgrades/archive/${UNATTUPG_RELEASE}.tar.gz"

#PIGUARD_DEPS=(raspberrypi-kernel-headers libmnl-dev libelf-dev build-essential pkg-config git qrencode tar wget grep dnsutils whiptail net-tools xz-utils)
PIGUARD_DEPS=(raspberrypi-kernel-headers libelf-dev git qrencode dnsutils)

# Find the rows and columns. Will default to 80x24 if it can not be detected.
screen_size=$(stty size 2>/dev/null || echo 24 80)
rows=$(awk '{print $1}' <<< "${screen_size}")
columns=$(awk '{print $2}' <<< "${screen_size}")

# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$(( rows / 2 ))
c=$(( columns / 2 ))
# Unless the screen is tiny
r=$(( r < 20 ? 20 : r ))
c=$(( c < 70 ? 70 : c ))

######## FUNCTIONS #########

main(){
    # Must be root to install
    if [ $EUID -eq 0 ]; then
        echo "::: You are root."
    else
        echo "::: sudo will be used for the install."
        # Check if it is actually installed
        # If it isn't, exit because the install cannot complete
        if dpkg-query -s sudo &> /dev/null; then
            export SUDO="sudo"
        else
            echo "::: Please install sudo or run this as root."
            exit 1
        fi
    fi

    # Check for supported distribution
    distro_check

    # Verify there is enough disk space for the install
    verify_free_disk_space

    # Install the packages (we do this first because we need whiptail)
    update_package_cache

    # Notify user of package availability
    notify_package_updates_available

    # Install packages used by this installation script
    install_dependent_packages

    # Display welcome dialogs
    welcome_dialogs

    # Find interfaces and let the user choose one
    choose_interface

    # Set a static IP for the server
    set_static_ipv4

    # Choose the user for the confs
    choose_user

    # The default port is 51820, protocol is UDP
    set_custom_port

    set_client_dns

    ask_public_ip_or_dns

    # Ask if unattended-upgrades will be enabled
    unattended_upgrades

    # WireGuard will be compiled from source into a deb package (for easy uninstallation)
    install_wireguard

    conf_wireguard

    # The firewall has to be configured at last, otherwhise the wg0 interface wouldn't be available
    conf_firewall

    start_wireguard

    install_scripts

    final_exports

    whiptail --title "Installation Complete!" --msgbox "Now run 'pi-guard add' to create a conf profile for each of your devices.

Run 'pi-guard help' to see what else you can do!

It is strongly recommended you reboot after installation." "${r}" "${c}"
}

distro_check(){
    # if lsb_release command is on their system
    if hash lsb_release 2>/dev/null; then
        DIST="$(lsb_release -si)"
        CODE="$(lsb_release -sc)"
    # else get info from os-release
    else
        if [ ! -f /etc/os-release ]; then
            echo "::: Unable to detect the current system, exiting..."
            exit 1
        fi
        source /etc/os-release
        DIST=$(awk '{print $1}' <<< "${NAME}")
        declare -A VER_MAP=(["9"]="stretch" ["8"]="jessie" ["7"]="wheezy")
        CODE="${VER_MAP["${VERSION_ID}"]}"
    fi

    if [ "${DIST}" = "Raspbian" ]; then
        if [ "${CODE}" != "stretch" ]; then
            if (whiptail --title "Compatibility check" --yesno "You are running ${DIST} ${CODE} but this script has been tested on Raspbian stretch only, do you still want to continue?" "${r}" "${c}"); then
                echo "::: Did not detect perfectly supported OS but,"
                echo "::: Continuing installation at user's own risk..."
            else
                echo "::: Exiting due to unsupported os..."
                exit 1
            fi
        fi
    else
        whiptail --title "Compatibility check" --msgbox "You are running ${DIST} ${CODE} but this script has been tested on Raspbian stretch only. Press enter to exit the script." "${r}" "${c}"
        echo "::: Exiting due to unsupported os..."
        exit 1
    fi
}

verify_free_disk_space(){
    # About 245000 kilobytes are required (including tar files that will be deleted at the end of the installation)
    local required_free_kilobytes=245000
    local existing_free_kilobytes=$(df -Pk | grep -m1 '\/$' | awk '{print $4}')

    # Unknown free disk space, not a integer
    if ! [[ "${existing_free_kilobytes}" =~ ^([0-9])+$ ]]; then
        if (whiptail --title "Unknown free disk space!" --yesno "We were unable to determine available free disk space on this system. Continue with the installation (not recommended)?" "${r}" "${c}"); then
            echo "::: Did not detect the free space but,"
            echo "::: Continuing installation at user's own risk..."
        else
            echo "::: Exiting due to unknown disk space..."
            exit 1
        fi
    # Insufficient free disk space
    elif [ "${existing_free_kilobytes}" -lt "${required_free_kilobytes}" ]; then
        whiptail --title "Insufficient free disk space!" --msgbox "Your system appears to be low on disk space. Pi-guard recommends a minimum of ${required_free_kilobytes} KiloBytes. You only have ${existing_free_kilobytes} KiloBytes free.

If this is a new install on a Raspberry Pi you may need to expand your disk.

Try running 'sudo raspi-config', choose 'Advanced options', then 'Expand file system'.

After rebooting, run this installation again." "${r}" "${c}"
        echo "::: Exiting due to insufficient disk space..."
        exit 1
    fi
}

package_installed(){
    dpkg-query -W -f='${Status}' "${1}" 2> /dev/null | grep -q 'ok installed'
}

update_package_cache(){
    #Running apt-get update/upgrade with minimal output can cause some issues with
    #requiring user input

    #Check to see if apt-get update has already been run today
    #it needs to have been run at least once on new installs!
    timestamp="$(stat -c %Y "${PKG_CACHE}")"
    timestampAsDate="$(date -d @"${timestamp}" "+%b %e")"
    today="$(date "+%b %e")"

    if [ ! "${today}" = "${timestampAsDate}" ]; then
        #update package lists
        echo -n "::: apt-get update has not been run today. Running now..."
        $SUDO apt-get update &> /dev/null
        echo " done!"
    fi
}

notify_package_updates_available(){
    # Let user know if they have outdated packages on their system and
    # advise them to run a package update at soonest possible.
    echo -n "::: Checking apt-get for upgraded packages..."
    updatesToInstall="$(eval "apt-get -s -o Debug::NoLocking=true upgrade | grep -c ^Inst || true")"
    echo " done!"
    if [ "${updatesToInstall}" -eq 0 ]; then
        echo "::: Your system is up to date! Continuing with Pi-guard installation..."
    else
        echo "::: There are ${updatesToInstall} updates available for your system!"
        echo "::: We recommend you update your OS after installing Pi-guard! "
    fi
}

install_dependent_packages(){
    # Only install packages that are not already installed
    DEPS_TO_INSTALL=()
    for PACKAGE in "${PIGUARD_DEPS[@]}"; do
        if ! package_installed "${PACKAGE}"; then
            DEPS_TO_INSTALL+=("${PACKAGE}")
        fi
    done

    # Add support for https repositories if there are any that use it otherwise the installation will fail
    if grep -q https "${PKG_SOURCES}";then 
        if ! package_installed "apt-transport-https"; then
            DEPS_TO_INSTALL+=("apt-transport-https")
        fi
    fi

    if command -v debconf-apt-progress &> /dev/null; then
        $SUDO debconf-apt-progress -- ${PKG_INSTALL} "${DEPS_TO_INSTALL[@]}"
    else
        $SUDO ${PKG_INSTALL} "${DEPS_TO_INSTALL[@]}" &> /dev/null
    fi
}

welcome_dialogs(){
    # Display the welcome dialog
    whiptail --title "Pi-guard Automated Installer" --msgbox "This installer will transform your Raspberry Pi into a WireGuard server!" "${r}" "${c}"

    # Explain the need for a static address
    whiptail --title "Static IP Needed" --msgbox "The Pi-guard is a SERVER so it needs a STATIC IP ADDRESS to function properly.

In the next section, you can choose to use your current network settings (DHCP) or to manually edit them." "${r}" "${c}"
}

choose_interface(){
    availableInterfaces=$(ip -o link | grep "state UP" | awk '{print $2}' | cut -d':' -f1 | cut -d'@' -f1)

    # Turn the available interfaces into an array so it can be used with a whiptail dialog
    local interfacesArray=()
    # Number of available interfaces
    local interfaceCount
    # Whiptail variable storage
    local chooseInterfaceCmd
    # Temporary Whiptail options storage
    local chooseInterfaceOptions
    # Loop sentinel variable
    local firstloop=1

    if [ "$(wc -l <<< "${availableInterfaces}")" -eq 1 ]; then
        piguardInterface="${availableInterfaces}"
        return
    fi

    while read -r line; do
        mode="OFF"
        if [[ ${firstloop} -eq 1 ]]; then
            firstloop=0
            mode="ON"
        fi
        interfacesArray+=("${line}" "available" "${mode}")
    done <<< "${availableInterfaces}"

    # Find out how many interfaces are available to choose from
    interfaceCount="$(wc -l <<< "${availableInterfaces}")"
    chooseInterfaceCmd=(whiptail --separate-output --radiolist "Choose An Interface (press space to select):" "${r}" "${c}" "${interfaceCount}")
    if chooseInterfaceOptions=$("${chooseInterfaceCmd[@]}" "${interfacesArray[@]}" 2>&1 >/dev/tty); then
        for desiredInterface in ${chooseInterfaceOptions}; do
            piguardInterface=${desiredInterface}
            echo "::: Using interface: ${piguardInterface}"
        done
    else
        echo "::: Cancel selected, exiting..."
        exit 1
    fi
}

choose_user(){
    # Explain the local user
    whiptail --title "Local Users" --msgbox "Choose a local user that will hold your configurations." "${r}" "${c}"
    # First, let's check if there is a user available.
    numUsers=$(awk -F':' 'BEGIN {count=0} $3>=1000 && $3<=60000 { count++ } END{ print count }' /etc/passwd)
    if [ "${numUsers}" -eq 0 ]; then
        # We don't have a user, let's ask to add one.
        if userToAdd=$(whiptail --title "Choose A User" --inputbox "No non-root user account was found. Please type a new username." "${r}" "${c}" 3>&1 1>&2 2>&3); then
            # See http://askubuntu.com/a/667842/459815
            PASSWORD=$(whiptail  --title "password dialog" --passwordbox "Please enter the new user password" "${r}" "${c}" 3>&1 1>&2 2>&3)
            CRYPT=$(perl -e 'printf("%s\n", crypt($ARGV[0], "password"))' "${PASSWORD}")
            if $SUDO useradd -m -p "${CRYPT}" -s /bin/bash "${userToAdd}"; then
                echo "::: Succeeded"
                ((numUsers+=1))
            else
                echo "::: Failed to create a new user, exiting..."
                exit 1
            fi
        else
            echo "::: You have not provided a username, exiting..."
            exit 1
        fi
    fi
    availableUsers=$(awk -F':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd)
    local userArray=()
    local firstloop=1

    while read -r line; do
        mode="OFF"
        if [[ "${firstloop}" -eq 1 ]]; then
            firstloop=0
            mode="ON"
        fi
        userArray+=("${line}" "" "${mode}")
    done <<< "${availableUsers}"
    chooseUserCmd=(whiptail --title "Choose A User" --separate-output --radiolist "Choose (press space to select):" "${r}" "${c}" "${numUsers}")
    
    if chooseUserOptions=$("${chooseUserCmd[@]}" "${userArray[@]}" 2>&1 >/dev/tty); then
        for desiredUser in ${chooseUserOptions}; do
            piguardUser="${desiredUser}"
            echo "::: Using User: ${piguardUser}"
        done
    else
        echo "::: Cancel selected, exiting..."
        exit 1
    fi
}

set_static_ipv4(){
    # Find IP used to route to outside world
    IPv4addr="$(ip route get 8.8.8.8| awk '{print $7}')"
    IPv4gw="$(ip route get 8.8.8.8 | awk '{print $3}')"

    # Grab their current DNS Server
    IPv4dns="$(nslookup 127.0.0.1 | grep Server: | awk '{print $2}')"

    local ipSettingsCorrect
    # Ask if the user wants to use DHCP settings as their static IP
    if (whiptail --title "Static IP Address" --yesno "Do you want to use your current network settings as a static address?
                    IP address:    ${IPv4addr}
                    Gateway:       ${IPv4gw}" "${r}" "${c}"); then
        # If they choose yes, let the user know that the IP address will not be available via DHCP and may cause a conflict.
        whiptail --title "IP conflict" --msgbox "It is possible your router could still try to assign this IP to a device, which would cause a conflict. But in most cases the router is smart enough to not do that.

If you are worried, either manually set the address, or modify the DHCP reservation pool so it does not include the IP you want.

It is also possible to use a DHCP reservation, but if you are going to do that, you might as well set a static address." "${r}" "${c}"
        # Nothing else to do since the variables are already set above
    else
        # Otherwise, we need to ask the user to input their desired settings.
        # Start by getting the IPv4 address (pre-filling it with info gathered from DHCP)
        # Start a loop to let the user enter their information with the chance to go back and edit it if necessary
        until [ "${ipSettingsCorrect}" = 'True' ]; do
            # Ask for the IPv4 address
            if IPv4addr=$(whiptail --title "IPv4 address" --inputbox "Enter your desired IPv4 address" "${r}" "${c}" "${IPv4addr}" 3>&1 1>&2 2>&3); then
            echo "::: Your static IPv4 address:    ${IPv4addr}"
            # Ask for the gateway
            if IPv4gw=$(whiptail --title "IPv4 gateway (router)" --inputbox "Enter your desired IPv4 default gateway" "${r}" "${c}" "${IPv4gw}" 3>&1 1>&2 2>&3); then
                echo "::: Your static IPv4 gateway:    ${IPv4gw}"
                # Give the user a chance to review their settings before moving on
                if (whiptail --title "Static IP Address" --yesno "Are these settings correct?
                    IP address:    ${IPv4addr}
                    Gateway:       ${IPv4gw}" "${r}" "${c}"); then
                    # After that's done, the loop ends and we move on
                    ipSettingsCorrect='True'
                else
                    # If the settings are wrong, the loop continues
                    ipSettingsCorrect='False'
                fi
            else
                # Cancelling gateway settings window
                ipSettingsCorrect='False'
                echo "::: Cancel selected. Exiting..."
                exit 1
            fi
        else
            # Cancelling IPv4 settings window
            ipSettingsCorrect=False
            echo "::: Cancel selected. Exiting..."
            exit 1
        fi
        done
        # End the if statement for DHCP vs. static
    fi

    # Tries to set the IPv4 address
    if [ -f "${dhcpcdFile}" ]; then
        if grep -q "${IPv4addr}" "${dhcpcdFile}"; then
            echo "::: Static IP already configured."
        else
            # Append these lines to dhcpcd.conf to enable a static IP
            echo "interface ${piguardInterface}
static ip_address=${IPv4addr}
static routers=${IPv4gw}
static domain_name_servers=${IPv4dns}" >> "${dhcpcdFile}"
            $SUDO ip addr replace dev "${piguardInterface}" "${IPv4addr}"
            echo "::: Setting IP to ${IPv4addr}."
            whiptail --title "Static IP" --msgbox "You may need to restart after the install is complete." "${r}" "${c}"
        fi
    else
        echo "::: Critical: Unable to locate configuration file to set static IPv4 address!"
        exit 1
    fi
}

set_custom_port() {
    until [ "${PORTNumCorrect}" = True ]; do
            portInvalid="Invalid"
            DEFAULT_PORT=51820

            if PORT=$(whiptail --title "Default WireGuard Port" --inputbox "You can modify the default WireGuard port.\n\nEnter a new value or hit 'Enter' to retain the default" "${r}" "${c}" "${DEFAULT_PORT}" 3>&1 1>&2 2>&3); then
                if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                    PORT=$portInvalid
                fi
            else
                echo "::: Cancel selected, exiting..."
                exit 1
            fi

            if [ "${PORT}" = "${portInvalid}" ]; then
                whiptail --title "Invalid Port" --msgbox "You entered an invalid Port number.\n\nPlease enter a number from 1 - 65535.\n\nIf you are not sure, please just keep the default." "${r}" "${c}"
                PORTNumCorrect=False
            else
                if (whiptail --title "Confirm Custom Port Number" --yesno "Are these settings correct?
                    PORT:   $PORT" "${r}" "${c}") then
                    PORTNumCorrect=True
                else
                    # If the settings are wrong, the loop continues
                    PORTNumCorrect=False
                fi
            fi
        done
}

# See https://stackoverflow.com/a/13777424
valid_ip(){
    local IP="$1" # Get the first argument passed to the function.
    local STAT=1 # Start with 1, so invalid.

    # Specify the format (numbers from 0 to 9 with 1 to 3 digits).
    if [[ "$IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS # Save the IFS.
        IFS='.' # Set a new IFS.
        IP=($IP) # Save the value as an array.
        IFS=$OIFS # Restore the IFS.
        # Check whether the 4 octects are less or equal to 255.
        [ "${IP[0]}" -le 255 ] && [ "${IP[1]}" -le 255 ] && [ "${IP[2]}" -le 255 ] && [ "${IP[3]}" -le 255 ]
        STAT=$? # Will be 0 on success.
    fi
    return $STAT
}

set_client_dns() {
    DNSChoseCmd=(whiptail --separate-output --radiolist "Select the DNS Provider for your VPN Clients (press space to select). To use your own, select Custom." "${r}" "${c}" 6)
    DNSChooseOptions=(Google "" on
            OpenDNS "" off
            Level3 "" off
            DNS.WATCH "" off
            Norton "" off
            FamilyShield "" off
            CloudFlare "" off
            Custom "" off)

    if DNSchoices=$("${DNSChoseCmd[@]}" "${DNSChooseOptions[@]}" 2>&1 >/dev/tty); then

        if [ "${DNSchoices}" != "Custom" ]; then

            echo "::: Using ${DNSchoices} servers."
            declare -A DNS_MAP=(["Google"]="8.8.8.8 8.8.4.4" ["OpenDNS"]="208.67.222.222 208.67.220.220" ["Level3"]="209.244.0.3 209.244.0.4" ["DNS.WATCH"]="84.200.69.80 84.200.70.40" ["Norton"]="199.85.126.10 199.85.127.10" ["FamilyShield"]="208.67.222.123 208.67.220.123" ["CloudFlare"]="1.1.1.1 1.0.0.1")

            WGDNS1="$(awk '{print $1}' <<< "${DNS_MAP["${DNSchoices}"]}")"
            WGDNS2="$(awk '{print $2}' <<< "${DNS_MAP["${DNSchoices}"]}")"

        else
            until [ "${DNSSettingsCorrect}" = 'True' ]; do

                if WGDNS=$(whiptail --title "Specify Upstream DNS Provider(s)" --inputbox "Enter your desired upstream DNS provider(s), seperated by a space.\n\nFor example '8.8.8.8 8.8.4.4'" "${r}" "${c}" "" 3>&1 1>&2 2>&3); then
                    WGDNS1="$(awk '{print $1}' <<< "$WGDNS")"
                    WGDNS2="$(awk '{print $2}' <<< "$WGDNS")"

                    if ! valid_ip "${WGDNS1}"; then
                        WGDNS1="Invalid"
                    fi

                    if [ -z "${WGDNS2}" ]; then
                        WGDNS2="Not set"
                    else
                        if ! valid_ip "${WGDNS2}"; then
                            WGDNS2="Invalid"
                        fi
                    fi

                else
                    echo "::: Cancel selected, exiting..."
                    exit 1
                fi
                
                if [ $WGDNS1 = "Invalid" ] || [ "${WGDNS2}" = "Invalid" ]; then
                    whiptail --title "Invalid IP" --msgbox "One or both entered IP addresses were invalid. Please try again.\n\n    DNS Server 1:   $WGDNS1\n    DNS Server 2:   $WGDNS2" "${r}" "${c}"
                    if [ "${WGDNS1}" = "Invalid" ]; then
                        WGDNS1=""
                    fi
                    if [ "${WGDNS2}" = "Invalid" ]; then
                        WGDNS2=""
                    fi
                    DNSSettingsCorrect=False
                else
                    if (whiptail --backtitle "Specify Upstream DNS Provider(s)" --title "Upstream DNS Provider(s)" --yesno "Are these settings correct?\n    DNS Server 1:   $WGDNS1\n    DNS Server 2:   $WGDNS2" "${r}" "${c}") then
                        DNSSettingsCorrect=True
                    else
                        # If the settings are wrong, the loop continues
                        DNSSettingsCorrect=False
                    fi
                fi
            done
        fi
    else
        echo "::: Cancel selected. Exiting..."
        exit 1
    fi
}

ask_public_ip_or_dns(){
    if ! IPv4pub="$(dig +short myip.opendns.com @208.67.222.222)" || ! valid_ip "${IPv4pub}"; then
        echo "dig failed, now trying to curl checkip.amazonaws.com"
        if ! IPv4pub="$(curl -s https://checkip.amazonaws.com)" || ! valid_ip "${IPv4pub}"; then
            echo "checkip.amazonaws.com failed, please check your internet connection/DNS"
            exit 1
        fi
    fi

    if ! METH=$(whiptail --title "Public IP or DNS" --radiolist "Will clients use a Public IP or DNS Name to connect to your server (press space to select)?" "${r}" "${c}" 2 \
        "${IPv4pub}" "Use this public IP" "ON" \
        "DNS Entry" "Use a public DNS" "OFF" 3>&1 1>&2 2>&3); then
        echo "::: Cancel selected. Exiting..."
        exit 1
    fi

    if [ "$METH" = "${IPv4pub}" ]; then
        PUBLICDNS="${IPv4pub}"
    else
        until [ "${publicDNSCorrect}" = 'True' ]; do
            if ! PUBLICDNS=$(whiptail --title "Pi-guard Setup" --inputbox "What is the public DNS name of this Server?" "${r}" "${c}" 3>&1 1>&2 2>&3); then
                echo "::: Cancel selected. Exiting..."
                exit 1
            fi

            if (whiptail --title "Confirm DNS Name" --yesno "Is this correct?\n\n Public DNS Name:  ${PUBLICDNS}" "${r}" "${c}") then
                publicDNSCorrect=True
            else
                publicDNSCorrect=False
            fi
        done
    fi
}

unattended_upgrades(){
    whiptail --title "Unattended Upgrades" --msgbox "Since this server will have at least one port open to the internet, it is recommended you enable unattended-upgrades.

This feature will check daily for package updates only and apply them when necessary.

It will NOT automatically reboot the server so to fully apply some updates you should periodically reboot." "${r}" "${c}"

    if (whiptail --title "Unattended Upgrades" --yesno "Do you want to enable unattended upgrades to this server?" "${r}" "${c}") then

        UNATTUPG="True"
        DEPS_TO_INSTALL+=("unattended-upgrades")

        if command -v debconf-apt-progress &> /dev/null; then
            $SUDO debconf-apt-progress -- ${PKG_INSTALL} "unattended-upgrades"
        else
            $SUDO ${PKG_INSTALL} "unattended-upgrades" &> /dev/null
        fi

        # Raspbian's unattended-upgrades package downloads Debian's config, so we need to download the proper config 
        cd /etc/apt/apt.conf.d
        wget -q -O- "${UNATTUPG_CONFIG}" | $SUDO tar xz
        $SUDO cp "unattended-upgrades-${UNATTUPG_RELEASE}/data/50unattended-upgrades.Raspbian" "50unattended-upgrades"
        $SUDO rm -r "unattended-upgrades-${UNATTUPG_RELEASE}"
        
        echo "APT::Periodic::Enable \"1\";
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Download-Upgradeable-Packages \"1\";
APT::Periodic::Unattended-Upgrade \"1\";
APT::Periodic::AutocleanInterval \"7\";
APT::Periodic::Verbose \"0\";" | $SUDO tee -a 02periodic &> /dev/null
    else
        UNATTUPG="False"
    fi
}

install_wireguard(){
    DEPS_TO_INSTALL+=("wireguard")

    whiptail --title "Installation from source" --msgbox "WireGuard will now be compiled and installed from source." "${r}" "${c}"

    # Delete the folder if for some reason it is still there after a failed installation
    if [ -d "${WG_PATH}" ]; then
        $SUDO rm -r "${WG_PATH}"
    fi

    if [ ! -d "${WG_PATH}" ]; then
        $SUDO mkdir "${WG_PATH}"
    fi

    cd "${WG_PATH}"
    echo -n "::: Downloading source code... "
    wget -q -O- "${WG_SOURCE}" | $SUDO tar xJ
    echo "done!"
    echo -n "::: Compiling WireGuard (this may take a while)... "
    cd "WireGuard-${WG_SNAPSHOT}/src"
    if $SUDO make > /dev/null; then
        echo "done!"
    else
        echo "failed!"
        exit 1
    fi

    echo -n "::: Installing WireGuard... "
    if $SUDO make install > /dev/null; then
        echo "done!"
    else
        echo "failed!"
        exit 1
    fi

    $SUDO rm -r "${WG_PATH}/WireGuard-${WG_SNAPSHOT}"
}

conf_wireguard(){
    whiptail --title "Server Information" --msgbox "The Server Keys and Pre-Shared key will now be generated." "${r}" "${c}"
    $SUDO mkdir "${WG_PATH}/configs"
    $SUDO touch "${WG_PATH}/configs/clients.txt"
    $SUDO mkdir "${WG_PATH}/keys"

    # Generate private key and derive public key from it
    wg genkey | $SUDO tee "${WG_PATH}/keys/server_priv" &> /dev/null
    wg genpsk | $SUDO tee "${WG_PATH}/keys/psk" &> /dev/null
    $SUDO cat "${WG_PATH}/keys/server_priv" | wg pubkey | $SUDO tee "${WG_PATH}/keys/server_pub" &> /dev/null

    echo "::: Server Keys and Pre-Shared Key have been generated."

    echo "[Interface]
PrivateKey = $($SUDO cat "${WG_PATH}/keys/server_priv")
Address = 10.6.0.1/24
ListenPort = ${PORT}
" | $SUDO tee "${WG_PATH}/wg0.conf" &> /dev/null
    echo "::: Server config generated."
}

conf_firewall(){
    IPv4dev=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++)if($i~/dev/)print $(i+1)}')

    # Enable forwarding of internet traffic
    cd /etc
    $SUDO sed -i '/net.ipv4.ip_forward=1/s/^#//g' sysctl.conf
    $SUDO sysctl -p &> /dev/null

    INPUT_CHAIN_EDITED="False"
    FORWARD_CHAIN_EDITED="False"

    if hash ufw 2>/dev/null && LANG=en_US.UTF-8 $SUDO ufw status | grep -qw 'active'; then
        USEUFW="True"
        echo "::: Detected UFW is enabled."
        echo "::: Adding UFW rules..."

        # If ufw is active, by default it has policy DROP both on INPUT as well as FORWARD,
        # so we need to allow connections to the port and explicitly forward packets.
        $SUDO ufw insert 1 allow "${PORT}"/udp > /dev/null
        $SUDO ufw route insert 1 allow in on wg0 from 10.6.0.0/24 out on "${IPv4dev}" to any > /dev/null

        # There is no front-end commmand to perform masquerading, so we need to edit the rules file.
        $SUDO sed "/delete these required/i *nat\n:POSTROUTING ACCEPT [0:0]\n-I POSTROUTING -s 10.6.0.0/24 -o ${IPv4dev} -j MASQUERADE\nCOMMIT\n" -i ufw/before.rules
        $SUDO ufw reload &> /dev/null

        echo "::: UFW configuration completed."
    else
        USEUFW="False"
        DEPS_TO_INSTALL+=("iptables-persistent")

        $SUDO debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v4 boolean false"
        $SUDO debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v6 boolean false"

        if command -v debconf-apt-progress &> /dev/null; then
            $SUDO debconf-apt-progress -- ${PKG_INSTALL} "iptables-persistent"
        else
            $SUDO ${PKG_INSTALL} "iptables-persistent" &> /dev/null
        fi

        # Now some checks to detect which rules we need to add. On a newly installed system all policies
        # should be ACCEPT, so the only required rule would be the MASQUERADE one.

        # Count how many rules are in the INPUT and FORWARD chain. When parsing input from
        # iptables -S, '^-P' skips the policies and 'ufw-' skips ufw chains (in case ufw was found
        # installed but not enabled).
        local INPUT_RULES_COUNT="$($SUDO iptables -S INPUT | grep -vcE '(^-P|ufw-)')"
        local FORWARD_RULES_COUNT="$($SUDO iptables -S FORWARD | grep -vcE '(^-P|ufw-)')"

        local INPUT_POLICY="$($SUDO iptables -S INPUT | grep '^-P' | awk '{print $3}')"
        local FORWARD_POLICY="$($SUDO iptables -S FORWARD | grep '^-P' | awk '{print $3}')"

        # If rules count is not zero, we assume we need to explicitly allow traffic. Same conclusion if
        # there are no rules and the policy is not ACCEPT. Note that rules are being added to the top of the
        # chain (using -I).
        if [ "${INPUT_RULES_COUNT}" -ne 0 ] || [ "${INPUT_POLICY}" != "ACCEPT" ]; then
            $SUDO iptables -I INPUT 1 -i "${IPv4dev}" -p udp --dport "${PORT}" -j ACCEPT
            INPUT_CHAIN_EDITED="True"
        fi

        if [ "${FORWARD_RULES_COUNT}" -ne 0 ] || [ "${FORWARD_POLICY}" != "ACCEPT" ]; then
            $SUDO iptables -I FORWARD 1 -d 10.6.0.0/24 -i "${IPv4dev}" -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
            $SUDO iptables -I FORWARD 2 -s 10.6.0.0/24 -i wg0 -o "${IPv4dev}" -j ACCEPT
            INPUT_CHAIN_EDITED="True"
        fi

        $SUDO iptables -t nat -I POSTROUTING 1 -s 10.6.0.0/24 -o "${IPv4dev}" -j MASQUERADE
        $SUDO iptables-save | $SUDO tee iptables/rules.v4 &> /dev/null

        echo "::: Iptables configuration applied."
    fi
}

start_wireguard(){
    if $SUDO systemctl start wg-quick@wg0 && $SUDO systemctl enable wg-quick@wg0 &> /dev/null; then
        echo "::: WireGuard started and enabled on boot."
    else
        echo "::: Failed to start WireGuard."
        exit 1
    fi
}

install_scripts(){
    $SUDO echo -n "::: Installing scripts to /opt/pi-guard... "
    
    if [ ! -d "/opt/pi-guard" ]; then
        $SUDO mkdir "/opt/pi-guard"
    fi

    $SUDO git clone -q "${piguardGitUrl}" /etc/pi-guard/repo > /dev/null
    $SUDO cp /etc/pi-guard/repo/scripts/* /opt/pi-guard
    $SUDO chmod 0755 /opt/pi-guard/{listCONF,makeCONF,qrcodeCONF,removeCONF,uninstall}.sh
    $SUDO cp /etc/pi-guard/repo/pi-guard /usr/local/bin/pi-guard
    $SUDO chmod 0755 /usr/local/bin/pi-guard
    $SUDO rm -r /etc/pi-guard/repo
    echo "done!"
}

final_exports() {
    # Save variables to file for later referencing
    if [ ! -d "/etc/pi-guard" ]; then
        $SUDO mkdir "/etc/pi-guard"
    fi

    {
    # These are used when creating a profile
    echo "INSTALL_USER=${piguardUser}"
    echo "PUBLICDNS=${PUBLICDNS}"
    echo "PORT=${PORT}"
    echo "WGDNS1=${WGDNS1}"
    echo "WGDNS2=${WGDNS2}"
    
    # These are used when uninstalling
    echo "UNATTUPG=${UNATTUPG}"
    echo "USEUFW=${USEUFW}"
    echo "INPUT_CHAIN_EDITED=${INPUT_CHAIN_EDITED}"
    echo "FORWARD_CHAIN_EDITED=${FORWARD_CHAIN_EDITED}"
    echo "piguardInterface=${piguardInterface}"
    echo "IPv4dns=${IPv4dns}"
    echo "IPv4addr=${IPv4addr}"
    echo "IPv4gw=${IPv4gw}"
    echo "DEPS_TO_INSTALL=\"${DEPS_TO_INSTALL[*]}\""

    } | $SUDO tee "${setupVars}" > /dev/null
}

main "$@"
