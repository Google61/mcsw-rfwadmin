#!/bin/bash
sudo add-apt-repository ppa:ondrej/php
sudo apt update
sudo apt-get install tmux php5.6 openjdk-17-jre wget zip unzip && /etc/init.d/apache2 restart
sudo update-java-alternatives -s java-1.17.0-openjdk-amd64
git clone https://github.com/Thue/rfwadmin
cd rfwadmin
mv ../minecraft_base.sh fsroot/var/lib/minecraft/

#If a previous installation exists, this script installs a new code version while preserverving configuration and data

### Settings ###

#You can also use WEBINTERFACE_DIR=/var/www/ to put the web interface in the www root
if [ -d /var/www/html ]; then
  #centos has webroot /var/www/html
  WEBINTERFACE_DIR="/var/www/html/rfwadmin"
else
  #Ubuntu has webroot /var/www
  WEBINTERFACE_DIR="/var/www/rfwadmin"
fi

#rfwadmin runs as the web server user. If $WEBSERVER_USER is empty, this script will try to guess the web server user from the owner of the process currently using port 80
WEBSERVER_USER=

PATH_BASE="/var/lib/minecraft"

#Symlink /var/lib/minecraft/web and /var/lib/minecraft/minecraft.sh
#back to fsroot . Useful for rfwadmin development if symlinking to a
#git checkout
SYMLINK_CODE=0

### Checks ###

function error_exit
{
    PROGNAME=$(basename $0)
    echo "${PROGNAME}: ${1:-"Unknown Error"}" 1>&2
    exit 1
}

if [ "`whoami`" != "root" ]; then
  echo "Script must be run as root"
  exit 1
fi

#determine web server user by looking at who is using port 80
if [ -z "$WEBSERVER_USER" ]; then
  WEBSERVER_USER=$(ps axho user,comm|grep -E "httpd|apache"|uniq|grep -v "root"|awk 'END {if ($1) print $1}')
  echo "Using '$WEBSERVER_USER' as the HTTP server user, which will also run the Minecraft server."
fi
#See if what we got looks remotely like a unix username
if ! [[ "$WEBSERVER_USER" =~ ^[a-zA-Z_][0-9a-zA-Z_-]*$ ]] ; then
    error_exit "error: HTTP server user ($WEBSERVER_USER) looks wrong"
fi




### Customize files to install ###

#If there is already stuff in /servers, then we are updating an old installation, and don't want to overwrite with a blank server configuration
if  [ ! -d "$PATH_BASE/servers" ] || [ ! "$(ls -A $PATH_BASE/servers)" ]; then
  CONFIGURE_SERVER="1"
else
  CONFIGURE_SERVER="0"
  echo "Not configuring any new Minecraft servers, since there already seem to be a configured server in $PATH_BASE/servers . Delete that directory and rerun the install script if you want to configure a new server."
fi

#Configure a default server if no previous configuration exists
if  [ $CONFIGURE_SERVER == "1" ]; then
  version_manifest_url="https://piston-meta.mojang.com/mc/game/version_manifest.json"
  tmp="version_manifest.json"
  curl -Ss -o "$tmp" "$version_manifest_url"
  latest_version=$(jq .latest.release -r "$tmp")
  latest_manifest_url=$(cat "$tmp" | jq -r ".versions[] | select(contains({type: \"release\", id: \"$latest_version\"})) | .url")
  manifest="/tmp/manifest.$latest_version.json"
  curl -Ss -o "$manifest" "$latest_manifest_url"
  jar_url=$(jq -r ".downloads.server.url" "$manifest")

  LATEST_SERVER_VERSION=$latest_version
  DOWNLOAD_URL=$jar_url

  #LATEST_SERVER_VERSION=`wget --quiet -O - $MANIFESTURL |head -c 100|sed  's/^{"latest":{[^}]*"release":"\([^"]\+\)".\+$/\1/'`
  #PATTERN='^[0-9.]+$'
  #if [[ ! $LATEST_SERVER_VERSION =~ $PATTERN ]] ; then
  #   error_exit "Failed to parse latest Minecraft server version from $MANIFESTURL"
  #fi
  LATEST_SERVER_BINARY=server.jar
  #DOWNLOAD_URL="https://s3.amazonaws.com/Minecraft.Download/versions/${LATEST_SERVER_VERSION}/minecraft_server.${LATEST_SERVER_VERSION}.jar"
  #If we are re-running the install script on the same day, no need to re-download the server
  if [ ! -f "fsroot/var/lib/minecraft/jars/serverjars/$LATEST_SERVER_BINARY" ]; then
    echo "Downloading latest minecraft server jar from Mojang."
    wget -O "fsroot/var/lib/minecraft/jars/serverjars/${LATEST_SERVER_BINARY}.tmp"  $DOWNLOAD_URL || error_exit "Failed to download minecraft server"
    mv "fsroot/var/lib/minecraft/jars/serverjars/${LATEST_SERVER_BINARY}.tmp" "fsroot/var/lib/minecraft/jars/serverjars/${LATEST_SERVER_BINARY}"
  fi
  cat fsroot/var/lib/minecraft/servers/default/minecraft.sh | sed "s|^FILE_JAR=.*\$|FILE_JAR=\"$PATH_BASE/jars/serverjars/$LATEST_SERVER_BINARY\"|" | sed "s|^PATH_BASE=.*\$|PATH_BASE=\"$PATH_BASE\"|" > fsroot/var/lib/minecraft/servers/default/minecraft.sh.customized
fi

#Maps from before Minecraft 1.2 is not in the "anvil" format. Mojang's
#server will autoconvert them, but if you are repeatably reloading a
#map that is slow. So minecraft_base.sh has a "convert" command to
#convert them once and for all (not available from web interface).
if [ ! -f fsroot/var/lib/minecraft/jars/converter/AnvilConverter.jar -a ! -f $PATH_BASE/jars/converter/AnvilConverter.jar ]; then
  echo "Downloading Anvil converter used to convert old maps."
  wget -O "fsroot/var/lib/minecraft/jars/converter/Minecraft.AnvilConverter.zip" "http://assets.minecraft.net/12w07a/Minecraft.AnvilConverter.zip"
  unzip -q -d "fsroot/var/lib/minecraft/jars/converter" "fsroot/var/lib/minecraft/jars/converter/Minecraft.AnvilConverter.zip" || echo "Failed to extract anvil converter because 'unzip' is not installed. You probably don't need that anyway."
fi

#Configure index.php to use correct PATH_BASE
cat fsroot/var/www/rfwadmin/index.php | sed "s|^\\\$include_base = .*\$|\$include_base = \"$PATH_BASE\";|" > fsroot/var/www/rfwadmin/index.php.customized

#Create a default password (using only unambiguous chars, no 0O1lI...)
#PASSWORD=`cat /dev/urandom | tr -dc 23456789abcdefghkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ | head -c${1:-10};`
# will be in secrets
PASSWORD="test"
cat  fsroot/var/www/rfwadmin/index.php.customized | sed "s|^\\\$passwords = null;.*\$|\$passwords = Array('${PASSWORD}');|" > fsroot/var/www/rfwadmin/index.php.customized2
mv fsroot/var/www/rfwadmin/index.php.customized2  fsroot/var/www/rfwadmin/index.php.customized

#Configure init script to use correct userid and PATH_BASE
cat fsroot/etc/init.d/minecraft_default.sh | sed "s/^SU_TO_USER=.*$/SU_TO_USER=\"$WEBSERVER_USER\"/" | sed "s|^PATH_BASE=.*\$|PATH_BASE=\"$PATH_BASE\"|" > fsroot/etc/init.d/minecraft_default.sh.customized


### ACTUALLY INSTALL ###
#No changes made outside current directory until this point

#install /var/lib
mkdir -p $PATH_BASE
mkdir -p $PATH_BASE/maps/
mkdir -p $PATH_BASE/jars/converter
mkdir -p $PATH_BASE/jars/plugins
mkdir -p $PATH_BASE/jars/serverjars
mkdir -p $PATH_BASE/servers

cp fsroot/var/lib/minecraft/jars/plugins/README $PATH_BASE/jars/plugins
if [ $SYMLINK_CODE == 1 ]; then
    ln -s "`pwd`/fsroot/var/lib/minecraft/minecraft_base.sh" $PATH_BASE
    chmod +x $PATH_BASE/minecraft_base.sh
    ln -s "`pwd`/fsroot/var/lib/minecraft/web" $PATH_BASE
else
    cp fsroot/var/lib/minecraft/minecraft_base.sh $PATH_BASE
    chmod +x $PATH_BASE/minecraft_base.sh
    cp -r fsroot/var/lib/minecraft/web $PATH_BASE
fi
if [ -f  fsroot/var/lib/minecraft/jars/converter/AnvilConverter.jar ]; then
  #If downloaded for installation above, then install it
  cp fsroot/var/lib/minecraft/jars/converter/AnvilConverter.jar $PATH_BASE/jars/converter
fi

#If no server config exists from previous install, then configure a server
if  [ $CONFIGURE_SERVER == "1" ]; then
  cp -r fsroot/var/lib/minecraft/servers/default $PATH_BASE/servers
  echo "Marking Minecraft EULA as accepted in $PATH_BASE/servers/default/server/eula.txt (otherwise the server won't start)"
  mkdir $PATH_BASE/servers/default/backups
  mv $PATH_BASE/servers/default/minecraft.sh.customized $PATH_BASE/servers/default/minecraft.sh
  chmod +x $PATH_BASE/servers/default/minecraft.sh
  cp fsroot/var/lib/minecraft/jars/serverjars/* $PATH_BASE/jars/serverjars

  #Install init script
  cp fsroot/etc/init.d/minecraft_default.sh.customized /etc/init.d/minecraft_default.sh
  chmod +x /etc/init.d/minecraft_default.sh
  ##Set to stop in ( http://refspecs.linuxbase.org/LSB_3.0.0/LSB-Core-generic/LSB-Core-generic/runlevels.html ):
  #halt
  ln -s /etc/init.d/minecraft_default.sh /etc/rc0.d/K01minecraft_default.sh
  #single user mode
  ln -s /etc/init.d/minecraft_default.sh /etc/rc1.d/K01minecraft_default.sh
  #reboot
  ln -s /etc/init.d/minecraft_default.sh /etc/rc6.d/K01minecraft_default.sh
  #without network
  ln -s /etc/init.d/minecraft_default.sh /etc/rc2.d/K01minecraft_default.sh
  ##set to start in the more or less normal levels
  ln -s /etc/init.d/minecraft_default.sh /etc/rc3.d/S99minecraft_default.sh
  ln -s /etc/init.d/minecraft_default.sh /etc/rc4.d/S99minecraft_default.sh
  ln -s /etc/init.d/minecraft_default.sh /etc/rc5.d/S99minecraft_default.sh
fi

chown -R $WEBSERVER_USER:root $PATH_BASE

#install web interface files
if [ ! -d "$WEBINTERFACE_DIR" ]; then
  mkdir --parents "$WEBINTERFACE_DIR"
fi
if [ ! -e "$WEBINTERFACE_DIR"/index.php ]; then
  cp -v fsroot/var/www/rfwadmin/index.php.customized "$WEBINTERFACE_DIR/index.php"
  echo -e "NOTE: The \033[1mpassword\033[m for the web interface is '\033[1m$PASSWORD\033[m'; it can be changed by editing $WEBINTERFACE_DIR/index.php"
else
  if [ ! -e "$WEBINTERFACE_DIR"/rfwadmin_files ]; then
     echo "Refusing to overwrite existing $WEBINTERFACE_DIR/index.php file, but I don't think it belongs to rfwadmin. Do a manual 'cp fsroot/var/www/index.php $WEBINTERFACE_DIR/index.php' if you really want to."
  fi
fi
if [ ! -e "$WEBINTERFACE_DIR"/rfwadmin_files ]; then
  ln -s /var/lib/minecraft/web/visible "$WEBINTERFACE_DIR"/rfwadmin_files
fi

/etc/init.d/minecraft_default.sh start

