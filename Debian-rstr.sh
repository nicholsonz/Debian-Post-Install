#!/bin/bash

##########################################################
# Automated Debian server installation and configuration
##########################################################

# Set variables
srvrname=				                  # FQDN for local server machine
srvrname2=${srvrname//./-}        # replace dots (.) or better filename presentation
dbuser=
dbpasswd=
adminUser=
adminEmail=
smbuser=				                  # samba user
smbgrp=					                  # samba group
mntpnt=/mnt/backup                # mount point
bkpdir=/mnt/backup/$srvrname    	# backup dir
websrvr=var/www                   # web server root dir
bkpdev=/dev/sdb                 	# location of backup drive with backup files/dirs
ip=
uuid=      	                	    # find uuid of backup device for fstab entry: "sudo blkid /dev/sd?"
phpv=8.2  	

###########################################################

############ Check that we are up-to-date
echo "List any packages to upgrade before running installation"
echo "#######################################################"
apt update
apt list --upgradable
echo "Upgrading system"
sleep 5
apt upgrade -y
echo "#######################################################"

############ Set time and time zone
dpkg-reconfigure tzdata
echo "#"
echo "#"
echo "#####################"
echo "Verify Correct Timezone"
echo "#####################"
timedatectl
echo "#####################"
echo ""
echo "If timezone is incorrect set it manually - timedatectl set-timezone America/Chicago"
sleep 10 

############ Make backup directory, create fstab entry and mount the backup drive
mkdir $mntpnt
#echo UUID=$uuid  /mnt/backup  auto  defaults  0 0 >>/etc/fstab

echo "Connect backup media at this time..."
read -p "Backup media connected (y/n)?" yesno
if [[ "$yesno" =~ ^([Yy](es|ES|eah)?)$ ]]; then
  echo "Great! Let's continue";
  mount /mnt/backup
else
  echo "Sorry, no dice.";
  exit 1;
fi

if [ ! mountpoint -q ${mntpnt}/ ]; then
	echo "Drive not mounted! Cannot continue without backup volume mounted!"
	exit 1
fi

# Set FQDN hostname
hostnamectl set-hostname $srvrname

echo "$ip   $srvrname" >>/etc/hosts

# Restore home dir for admin user
rsync -arvp $bkpdir/home/$admin/ /home/$admin

## setup systemd-timesyncd for system time synchoronization
apt install systemd-timesyncd
rsync -arvp $bkpdir/etc/systemd/timesyncd.conf /etc/systemd/


## Extra packages
apt-get install -y lnav rsyslog lm-sensors wget whois bash-completion smartmontools haveged goaccess tuned colorized-logs

# restore goaccess files
rsync -arvp $bkpdir/etc/goaccess/ /etc/goaccess

## PHP install
apt install -y php$phpv php$phpv-bz2 php$phpv-cli php$phpv-common php$phpv-curl php$phpv-gd php$phpv-imap php$phpv-intl php$phpv-ldap php$phpv-mbstring php$phpv-mysql php$phpv-imagick php$phpv-xml php$phpv-zip php$phpv-soap php$phpv-readline php$phpv-opcache
apt install -y zip unzip git composer

## Prosody IM chat server install
#apt install -y extrepo
#extrepo enable prosody
#apt update
#apt install -y prosody
#rsync -arvp $bkpdir/etc/prosody/ /etc/prosody
#systemctl enable prosody
#systemctl start prosody

#######################################################################
#			Apache web server and security package        #
#######################################################################
#
# install
apt-get install -y apache2 openssl libapache2-mod-php

# Restore and configure Apache
#
rsync -arvp $bkpdir/etc/apache2/apache2.conf /etc/apache2
#rsync -arvp $bkpdir/etc/apache2/modsecurity-crs /etc/apache2
rsync -arvp $bkpdir/etc/apache2/sites-available/ /etc/apache2/sites-available
rsync -arvp $bkpdir/etc/apache2/conf-available/ /etc/apache2/conf-available

# enable all available sites
a2ensite *

## install security packages for apache2
# Install mod_security
apt install libapache2-mod-security2

# DOS protection redundant and too sensitive.  Already included in firewall
#apt install -y libapache2-mod-evasive

# restore configuration files for mod_security
rsync -arvp $bkpdir/etc/modsecurity/modsecurity.conf /etc/modsecurity
rsync -arvp $bkpdir/etc/modsecurity/crs/crs-setup.conf /etc/modsecurity/crs

# Disable potentially insecure modules for Apache2
a2dismod deflate

# Enable security modules for apache
a2enmod headers ssl rewrite security2

# Copy web server ssl certs
rsync -arvp $bkpdir/etc/ssl/ /etc/ssl
rsync -arvp $bkpdir/etc/letsencrypt/ /etc/letsencrypt

# Create default self-signed ssl certificates for localhost

if [ ! -f /etc/ssl/private/$srvrname2.key ]; then

  openssl genrsa -des3 -out /etc/ssl/private/$srvrname2.key 2048
  openssl rsa -in /etc/ssl/private/$srvrname2.key -out /etc/ssl/private/$srvrname2.key.insecure
  mv /etc/ssl/private/$srvrname2.key /etc/ssl/private/$srvrname2.key.secure
  mv /etc/ssl/private/$srvrname2.key.insecure /etc/ssl/private/$srvrname2.key
  openssl req -new -key /etc/ssl/private/$srvrname2.key -out /etc/ssl/certs/$srvrname2.csr
  openssl x509 -req -days 3650 -in /etc/ssl/certs/$srvrname2.csr -signkey /etc/ssl/private/$srvrname2.key -out /etc/ssl/certs/$srvrname2.crt

else
    echo "Key pair already exists."

fi

# restore /$websrvr/
rsync -arvp $bkpdir/$websrvr/ /$websrvr

# install certbot and configure apache to use ssl
apt install -y certbot python3-certbot-apache
certbot --apache

# Restart apache for configuration changes
systemctl restart apache2

###################################################
#			Cockpit and related packages                #
###################################################

apt-get install -y cockpit cockpit-packagekit cockpit-storaged cockpit-pcp
# add dirs and files for compatibility
mkdir /usr/lib/x86_64-linux-gnu/udisks2
mkdir /usr/lib/x86_64-linux-gnu/udisks2/modules
# if problem with software updates - "vim /etc/netplan/00-installer-config.yaml" and add renderer: NetworkManager to end of file
#systemctl disable systemd-networkd
#netplan apply 

##################################################
#			MariaDB Install                            #
##################################################
# install
apt-get install -y mariadb-server mariadb-backup

# configure
echo "Begin MariaDB configuration"
echo

# secure mariadb installation
mysql_secure_installation

mysql --user=root -p<<_EOF_
GRANT ALL PRIVILEGES ON *.* TO '$dbuser'@'localhost' IDENTIFIED BY '$dbpasswd';
FLUSH PRIVILEGES;
_EOF_

## Perform full restore of MariaDB      
systemctl stop mariadb.service

# Prepare MariaDB backup
mariabackup --prepare  --target-dir=$bkpdir/sql/mariadb/fullbkp

# Empty maria dir
rm -rf /var/lib/mysql/

# Restore backup of MariaDB
mariabackup --copy-back --target-dir=$bkpdir/sql/mariadb/fullbkp

# Restore ownership to files
chown -R mysql:mysql /var/lib/mysql/

systemctl start mariadb.service

############ PHPMYAdmin install - needs to be installed after database install
apt-get install -y phpmyadmin
rsync -arvp $bkpdir/etc/phpmyadmin/apache.conf /etc/phpmyadmin


############ Postfix and Dovecot
apt-get install -y postfix postfix-mysql dovecot-lmtpd dovecot-mysql dovecot-core dovecot-imapd dovecot-pop3d
cp /etc/postfix/main.cf /etc/postfix/main.cf.bkp
rsync -arvp $bkpdir/etc/postfix/main.cf /etc/postfix
cp /etc/postfix/master.cf /etc/postfix/master.cf.bkp
rsync -arvp $bkpdir/etc/postfix/master.cf /etc/postfix
rsync -arvp $bkpdir/etc/postfix/sql /etc/postfix
rsync -arvp $bkpdir/etc/dovecot/dovecot.conf /etc/dovecot
cp /etc/dovecot/dovecot-sql.conf.ext /etc/dovecot/dovecot-sql.conf.ext.bak
rsync -arvp $bkpdir/etc/dovecot/dovecot-sql.conf.ext /etc/dovecot
rsync -arvp $bkpdir/etc/dovecot/conf.d/ /etc/dovecot/conf.d
rsync -arvp $bkpdir/etc/mailname /etc
# add virtual mailbox dir and user
mkdir /var/vmail
groupadd -g 6000 vmail
useradd -r -g vmail -u 6000 vmail -d /var/vmail -c "virtual mail user"
chown -R vmail:vmail /var/vmail

# Add alias for root and update alias database 
echo "root:      $adminUser" >>/etc/aliases
newaliases


############ Netdata for monitoring
#curl -s https://packagecloud.io/install/repositories/netdata/netdata/script.rpm.sh | sudo bash
#sudo apt-get install netdata

apt-get install -y ufw
############ Create holes in firewall
ufw allow imap
ufw allow imaps
ufw allow pop3
ufw allow pop3s
ufw allow smtp
ufw allow http
ufw allow https
ufw allow samba
ufw allow ssh
ufw allow 9090      #Cockpit
#ufw allow 19999     #NetData
ufw allow 2020      #SSHD
ufw allow 587
ufw allow 465
#ufw allow 5222      #Prosody IM server
ufw reload
ufw enable


############ miscellaneous file restoration

rsync -arvp $bkpdir/home/$adminUser/ /home/$adminUser
rsync -arvp $bkpdir/etc/ssh/sshd_config /etc/ssh
#rsync -arvp $bkpdir/etc/php.ini /etc
rsync -arvp $bkpdir/etc/php/$phpv/apache2/ /etc/php/$phpv/apache2
rsync -arvp $bkpdir/etc/goaccess/ /etc/goaccess
rsync -arvp $bkpdir/srv/ /srv

# Restore smartd.conf
# run "udevadm info" from terminal to determin drive parameters to include in smartd.conf
# example entry to replace /dev/sdb
# /dev/disk/by-id/ata-ST320LT012-9WS14C_S0V0V2HA
#rsync -arvp $bkpdir/etc/smartd.conf /etc


############ Samba
apt-get install -y samba
useradd -M -s /sbin/nologin $smbuser
passwd $smbuser
smbpasswd -a $smbuser
groupadd $smbgrp
usermod -aG $smbgrp $smbuser
rsync -arvp $bkpdir/etc/samba/smb.conf /etc/samba
chmod -R 770 /srv/samba
chown -R root:$smbgrp /srv/samba

############# Root Crontab 
# restore custom cron jobs
rsync -arvp $bkpdir/etc/cron.custom /etc
# restore crontab for root
crontab /home/$adminUser/repo/crontab.bak
# verify crontab entries
echo 
echo "###############################"
echo
crontab -l
sleep 8

############ Install security packages
# Fail2Ban, Logwatch, Clamav,  and Lynis
apt-get install -y logwatch fail2ban clamav clamav-daemon python3-notify2 lynis
# restore config files
rsync -arvp $bkpdir/etc/fail2ban/ /etc/fail2ban
rsync -arvp $bkpdir/etc/logwatch/ /etc/logwatch
rsync -arvp $bkpdir/etc/clamav/freshclam.conf /etc/clamav
# create cache dir for logwatch
mkdir /var/cache/logwatch
# update clamav
systemctl stop clamav-freshclam.service
freshclam

############# Install AIDE file integrity tool
apt-get install -y aide
rsync -arvp $bkpdir/etc/aide/aide.conf /etc/aide
aideinit
## commands 
# aide --check --config /etc/aide/aide.conf
# aide --update --config /etc/aide/aide.conf
# cp /var/lib/aide/aide.db{.new,}


############# Install AuditD 
apt-get install -y auditd audispd-plugins
rsync -arvp $bkpdir/etc/audit/audit.rules /etc/audit
rsync -arvp $bkpdir/etc/audit/rules.d/ /etc/audit/rules.d
service auditd start
systemctl enable auditd

# Restore aide-update.sh file to /usr/sbin for bash use
rsync -arvp $bkpdir/home/zach/repo/scripts/aide-update.sh /usr/sbin

############# Start and enable services
systemctl enable --now cockpit.socket
systemctl enable clamav-freshclam.service
systemctl start clamav-freshclam.service
systemctl enable auditd.service

############# RKHunter installation and update
apt-get install -y rkhunter
# restore configuration files
rsync -arvp $bkpdir/etc/rkhunter.conf /etc
rsync -arvp $bkpdir/etc/default/rkhunter /etc/defalut
# initialize rkhunter
rkhunter --propupd

echo "################################################"
echo "All Finished!  The computer will reboot in 10 seconds."
echo "Restart computer for changes to take affect."
echo "################################################"
  


