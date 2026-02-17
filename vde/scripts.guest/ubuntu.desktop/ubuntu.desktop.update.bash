apt-get update;
apt-get upgrade -y;
apt-get dist-upgrade -y;
apt-get autoclean -y;
apt-get autoremove -y;
apt-get install deborphan -y;
deborphan | xargs apt-get -y remove --purge;
deborphan --guess-data | xargs apt-get -y remove --purge;