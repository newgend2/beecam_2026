Copy all service files in this directory to /etc/systemd/system.

Enable every service except weather-station.service:

  sudo systemctl enable weather-station-init-data.service
  sudo systemctl enable wittypi-log-links.service
  sudo systemctl disable weather-station.service

weather-station.service is intentionally started by wittypi/afterStartup.sh and
stopped by wittypi/beforeShutdown.sh.
