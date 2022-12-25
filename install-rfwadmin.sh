sudo apt-get install tmux openjdk-7-jre libapache2-mod-php5 php5-curl wget zip unzip && /etc/init.d/apache2 restart
git clone https://github.com/Thue/rfwadmin
cd rfwadmin
mv ../install-custom.sh install.sh
chmod +x install.sh
./install.sh
