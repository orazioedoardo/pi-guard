#!/bin/bash

setupVars="/etc/pi-guard/setupVars.conf"

# Must be root to uninstall
if [ $EUID -ne 0 ];then
    if dpkg-query -s sudo &> /dev/null; then
        export SUDO="sudo"
    else
        echo "::: Please install sudo or run this as root."
        exit 1
  fi
fi

if [ ! -f "${setupVars}" ]; then
    echo "::: Missing setup vars file!"
    exit 1
fi

source "${setupVars}"

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

stop_wireguard(){
    if systemctl stop wg-quick@wg0 && systemctl disable wg-quick@wg0 &> /dev/null; then
        echo "::: WireGuard stopped"
    else
        echo "::: Failed to stop WireGuard"
        exit 1
    fi
}

remove_all(){
    # Removing firewall rules.
    echo "::: Removing firewall rules..."
    if [ "$USEUFW" = "True" ]; then
        ufw delete allow "${PORT}"/udp > /dev/null
        ufw route delete allow in on wg0 from 10.6.0.0/24 out on "${piguardInterface}" to any > /dev/null
        sed -z "s/*nat\n:POSTROUTING ACCEPT \[0:0\]\n-I POSTROUTING -s 10.6.0.0\/24 -o ${piguardInterface} -j MASQUERADE\nCOMMIT\n\n//" -i /etc/ufw/before.rules
        ufw reload &> /dev/null
    elif [ "$USEUFW" = "False" ]; then
        if [ "$INPUT_CHAIN_EDITED" = "True" ]; then
            iptables -D INPUT -i "${piguardInterface}" -p udp --dport "${PORT}" -j ACCEPT
        fi

        if [ "$FORWARD_CHAIN_EDITED" = "True" ]; then
            iptables -D FORWARD -d 10.6.0.0/24 -i "${piguardInterface}" -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
            iptables -D FORWARD -s 10.6.0.0/24 -i wg0 -o "${piguardInterface}" -j ACCEPT
        fi

        iptables -t nat -D POSTROUTING -s 10.6.0.0/24 -o "${piguardInterface}" -j MASQUERADE
        iptables-save > /etc/iptables/rules.v4
    fi

    # Purge dependencies
    INSTALLED_DEPS=(${DEPS_TO_INSTALL[@]})

    for i in "${INSTALLED_DEPS[@]}"; do
        while true; do
            read -rp "::: Do you wish to remove $i from your system? [Y/n]: " yn
            case $yn in
                [Yy]* ) if [ "${i}" = "wireguard" ]; then
                            UNINST_WG=1
                            printf ":::\t%s will be uninstalled in a few... \n" "${i}"
                        else
                            printf ":::\tRemoving %s... " "${i}"; apt-get -y remove --purge "${i}" &> /dev/null; printf "done!\n"
                        fi
                        
                        if [ "${i}" = "unattended-upgrades" ]; then
                            UINST_UNATTUPG=1;
                        fi
                        break;;
                [Nn]* ) printf ":::\tSkipping %s\n" "$i";
                        break;;
                * ) printf "::: You must answer yes or no!\n";;
            esac
        done
    done

    # Take care of any additional package cleaning
    printf "::: Auto removing remaining dependencies... "
    apt-get -y autoremove &> /dev/null; printf "done!\n";
    printf "::: Auto cleaning remaining dependencies... "
    apt-get -y autoclean &> /dev/null; printf "done!\n";

    # Removing pi-guard files
    echo "::: Removing pi-guard system files..."
    rm -r /opt/pi-guard
    rm -r /etc/pi-guard
    rm /usr/local/bin/pi-guard

    # Disable IPv4 forwarding
    sed "/net.ipv4.ip_forward=1/s/^/#/g" -i /etc/sysctl.conf
    sysctl -p &> /dev/null

    if [ "${UNINST_WG}" = 1 ]; then
        # Find and delete all client configs in the home folder of the user.
        LIST=($(awk '{print $1}' /etc/wireguard/configs/clients.txt))
        for CLIENT_NAME in "${LIST[@]}"; do
            REQUESTED="$(sha256sum "/etc/wireguard/configs/${CLIENT_NAME}.conf" | cut -c 1-64)"
            find "/home/${INSTALL_USER}" -maxdepth 3 -type f -name '*.conf' -print0 | while IFS= read -r -d '' CONFIG; do
                if sha256sum -c <<< "${REQUESTED}  ${CONFIG}" &> /dev/null; then
                    rm "${CONFIG}"
                fi
            done
        done

        echo "::: Unloading WireGuard kernel module..."
        modprobe -r wireguard
        depmod -a

        echo "::: Removing WireGuard system files..."
        rm "$(modinfo -n wireguard)"
        rm /usr/bin/wg
        rm /usr/share/man/man8/wg.8
        rm /usr/share/bash-completion/completions/wg
        rm /usr/bin/wg-quick
        rm /usr/share/man/man8/wg-quick.8
        rm /usr/share/bash-completion/completions/wg-quick
        rm /lib/systemd/system/wg-quick@.service
        rm -r /etc/wireguard
    fi

    if [ "${UINST_UNATTUPG}" = 1 ]; then
        rm -r /var/log/unattended-upgrades
        rm /etc/apt/apt.conf.d/*periodic
    fi

    printf "::: Finished removing Pi-guard from your system.\n"
}

ask_reboot(){
    printf "It is \e[1mstrongly\e[0m recommended to reboot after un-installation.\n"
    read -p "Would you like to reboot now? [Y/n]: " -n 1 -r
    echo
    if [[ ${REPLY} =~ ^[Yy]$ ]]; then
        printf "\nRebooting system...\n"
        sleep 3
        reboot
    fi
}

######### SCRIPT ###########
echo "::: Preparing to remove packages, be sure that each may be safely removed depending on your operating system."
echo "::: (SAFE TO REMOVE ALL ON RASPBIAN)"
while true; do
    read -rp "::: Do you wish to completely remove Pi-guard configuration and installed packages from your system? (You will be prompted for each package) [Y/n]: " yn
    case $yn in
        [Yy]* ) stop_wireguard; remove_all; ask_reboot; break;;

        [Nn]* ) printf "::: Not removing anything, exiting...\n"; break;;
    esac
done
