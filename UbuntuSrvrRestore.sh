#!/bin/bash

##########################################################
# Automated Ubuntu server installation and configuration
##########################################################

# Set variables
srvrname=fully qualified domain name
dbuser=admin
dbpasswd=password
adminUser=admin
smbuser=smbusername
smbgrp=smbusergroup
bkpdir=/mnt/backup/$srvrname
bkpdev=/dev/sdb
ip=10.10.10.10
uuid=      	#find uuid of backup device for fstab entry: "sudo blkid /dev/sd?"
phpvrsn=  	

###########################################################

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
sleep 7 


############ Make backup directory, create fstab entry and mount the backup drive

mkdir /mnt/backup
#echo UUID=$uuid  /mnt/backup  auto  defaults  0 0 >>/etc/fstab

echo "Connect backup media at this time..."
read -p "Backup media connected (y/n)?" CONT
if [ "$CONT" = "y" ]; then
  echo "Great! Let's continue";
  mount /mnt/backup
else
  echo "Sorry, no dice.";
  exit 1;
fi

MNTPNT='/mnt/backup'
if ! mountpoint -q ${MNTPNT}/; then
	echo "Drive not mounted! Cannot continue without backup volume mounted!"
	exit 1
fi

# Set FQDN hostname
hostnamectl set-hostname $srvrname

echo "$ip   $srvrname" >>/etc/hosts

## Update system first 
apt-get upgrade -y

## Extra packages
apt-get install -y lnav lm-sensors wget whois bash-completion clamav smartmontools haveged goaccess tuned colorized-logs

## PHP install
apt-get install -y php php-mysql php-zip php-imap php-xml php-mbstring php-intl php-pear zip unzip git composer php-ldap php-imagick php-gd

## PHPMYAdmin install
apt-get install -y phpmyadmin
rsync -arv $bkpdir/etc/phpmyadmin/apache.conf /etc/phpmyadmin


###########################################################################################
#			Apache web server and security packages			          #
###########################################################################################
#
# install
apt-get install -y apache2 openssl libapache2-mod-php
# restore and configure
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout /etc/ssl/private/$srvrname.key -out /etc/ssl/certs/$srvrname.crt
rsync -arv $bkpdir/etc/apache2/sites-available/ /etc/apache2/sites-available
cd /etc/apache2/sites-available
a2ensite *
# install security packages for apache2

#apt install -y libapache2-mod-evasive # DOS protection redundant and too sensitive.  Already included in firewall

# Mod security for Content Security Policies - good
apt install libapache2-mod-security2
a2enmod security2 headers ssl rewrite

# restore configuration files for modsecurity
rsync -arv $bkpdir/etc/modsecurity/modsecurity.conf /etc/modsecurity
rsync -arv $bkpdir/etc/modsecurity/crs/crs-setup.conf /etc/modsecurity/crs
rsync -arv $bkpdir/etc/apache2/conf-available/security.conf /etc/apache2/conf-available

systemctl restart apache2


# install certbot and configure apache to use ssl
snap install --classic certbot
ln -s /snap/bin/certbot /usr/bin/certbot
certbot --apache

# Create default self-signed ssl certificates for localhost

if [ ! -f /etc/ssl/private/$srvrname.key ]; then

  openssl genrsa -des3 -out /etc/ssl/private/$srvrname.key 2048
  openssl rsa -in /etc/ssl/private/$srvrname.key -out /etc/ssl/private/$srvrname.key.insecure
  mv /etc/ssl/private/$srvrname.key /etc/ssl/private/$srvrname.key.secure
  mv /etc/ssl/private/$srvrname.key.insecure /etc/ssl/private/$srvrname.key
  openssl req -new -key /etc/ssl/private/$srvrname.key -out /etc/ssl/certs/$srvrname.csr
  openssl x509 -req -days 3650 -in /etc/ssl/certs/$srvrname.csr -signkey /etc/ssl/private/$srvrname.key -out /etc/ssl/certs/$srvrname.crt

else
    echo "Key pair already exists."

fi
#####################################################################
#			Cockpit and related packages                #
#####################################################################

apt-get install -y cockpit cockpit-packagekit cockpit-storaged cockpit-pcp
# add dirs and files for compatibility
mkdir /usr/lib/x86_64-linux-gnu/udisks2
mkdir /usr/lib/x86_64-linux-gnu/udisks2/modules
# if problem with software updates - "vim /etc/netplan/00-installer-config.yaml" and add renderer: NetworkManager to end of file
systemctl disable systemd-networkd
netplan apply 
####################################################################
#			MariaDB Install                            #
#################################################################### 
# install
apt-get install -y mariadb-server

# configure
echo "Begin MariaDB configuration"
echo

mysql_secure_installation

mysql --user=root -p<<_EOF_
GRANT ALL PRIVILEGES ON *.* TO '$dbuser'@'localhost' IDENTIFIED BY '$dbpasswd';
_EOF_

# Gunzip latest database backup sql.gz file for each database and restore the database

echo "Listing of backed up databases:"
echo "$(ls -I "*.log" $bkpdir/sql)"
echo "-------------------------------------"
echo "Enter name of databases separated by spaces to restore?"
read -p 'databases: ' dbases

for dbase in $dbases
 do
DIR="$bkpdir/sql/${dbase}"
NEWEST=`ls -tr1d "${DIR}/"*.gz 2>/dev/null | tail -1`
TODAY=$(date +"%a")

mysql --user=root -e "CREATE DATABASE $dbase DEFAULT CHARACTER SET utf8";

  if [ ! -f "*.sql" ] ; then
   gunzip -f ${NEWEST}
   mysql --user=root "$dbase" < $DIR/$TODAY.sql
else
    echo "The .sql file already exists for this $dbase"

fi
done

echo "Securing SQL installation"


############ Postfix and Dovecot
apt-get install -y postfix postfix-mysql dovecot-lmtpd dovecot-mysql dovecot-core dovecot-imapd dovecot-pop3d
cp /etc/postfix/main.cf /etc/postfix/main.cf.bkp
rsync -arv $bkpdir/etc/postfix/main.cf /etc/postfix
cp /etc/postfix/master.cf /etc/postfix/master.cf.bkp
rsync -arv $bkpdir/etc/postfix/master.cf /etc/postfix
rsync -arv $bkpdir/etc/postfix/sql /etc/postfix
rsync -arv $bkpdir/etc/dovecot/dovecot.conf /etc/dovecot
cp /etc/dovecot/dovecot-sql.conf.ext /etc/dovecot/dovecot-sql.conf.ext.bak
rsync -arv $bkpdir/etc/dovecot/dovecot-sql.conf.ext /etc/dovecot
rsync -arv $bkpdir/etc/dovecot/conf.d/ /etc/dovecot/conf.d
rsync -arv $bkpdir/etc/mailname /etc
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


############ Create holes in firewall
ufw allow imap
ufw allow imaps
ufw allow pop3
ufw allow pop3s
ufw allow smtp
ufw allow http
ufw allow https
ufw allow Samba
ufw allow ssh
ufw allow 9090      #Cockpit
#ufw allow 19999     #NetData
ufw allow 2020      #SSHD
ufw allow 587
ufw allow 465
ufw reload
ufw enable


############ miscellaneous file restoration

rsync -arv $bkpdir/home/$adminUser/ /home/$adminUser
rsync -arv $bkpdir/etc/ssh/sshd_config /etc/ssh
rsync -arv $bkpdir/etc/php.ini /etc
rsync -arv $bkpdir/etc/goaccess/ /etc/goaccess
rsync -arv $bkpdir/srv/ /srv
rsync -arv $bkpdir/var/www/html/ /var/www/html
rsync -arv $bkpdir/var/storage /var


############ Samba
apt-get install -y samba
useradd -M -s /sbin/nologin $smbuser
passwd $smbuser
smbpasswd -a $smbuser
groupadd $smbgrp
usermod -aG $smbgrp $smbuser
rsync -arv $bkpdir/etc/samba/smb.conf /etc/samba
chmod -R 770 /srv/samba
chown -R root:$smbgrp /srv/samba

############# Root Crontab 
# restore custom cron jobs
rsync -arv $bkpdir/etc/cron.custom /etc
# restore crontab for root
crontab /home/zach/repo/crontab.bak
# verify crontab entries
echo 
echo "###############################"
echo
crontab -l
sleep 8

############ Install security packages
# Fail2Ban Logwatch and Lynis
apt-get install -y logwatch fail2ban lynis
apt-get install -y tripwire
# restore config files
rsync -arv $bkpdir/etc/fail2ban/ /etc/fail2ban
rsync -arv $bkpdir/etc/logwatch/ /etc/logwatch
# create cache dir for logwatch
mkdir /var/cache/logwatch

############# Tripwire
apt-get install tripwire
# Segmentation Fault Error - edit the twcfg.txt file and add RESOLVE_IDS_TO_NAMES =false
# update config file after edit
twadmin --create-cfgfile -S site.key /etc/tripwire/twcfg.txt 
# automate the no directory list and exclusion *needs editing to work on ubuntu
sh -c "tripwire --check | grep Filename > no-directory.txt"
for f in $(grep "Filename:" no-directory.txt | cut -f2 -d:); do
sed -i "s|\($f\) |#\\1|g" /etc/tripwire/twpol.txt
done
# update policy file
twadmin --create-polfile -S site.key /etc/tripwire/twpol.txt
# initialize database
tripwire --init
# test email delivery of tripwire
tripwire --test --email root

############# RKHunter installation and update
apt-get install -y rkhunter
# restore configuration files
rsync -arv $bkpdir/etc/rkhunter.conf /etc
rsync -arv $bkpdir/etc/default/rkhunter /etc/defalut
# initialize rkhunter
rkhunter --propupd


echo "All Finished!  The computer will reboot in 10 seconds."
sleep 10

# reboot computer
reboot




