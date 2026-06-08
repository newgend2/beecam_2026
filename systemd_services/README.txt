Copy all service files in this directory to /etc/systemd/system.

Enable every service except beecam.service:

  sudo systemctl enable beecam-init-data.service
  sudo systemctl enable beecam-oled-boot.service
  sudo systemctl enable wittypi-log-links.service
  sudo systemctl disable beecam.service

beecam.service is intentionally started by wittypi/afterStartup.sh and stopped
by wittypi/beforeShutdown.sh.

beecam-oled-boot.service is a short oneshot splash. It exits immediately when
the camera config has [oled] enabled = false.
