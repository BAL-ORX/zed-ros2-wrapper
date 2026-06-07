# 1. Install udev rules on the host (run this in your terminal)
echo 'SUBSYSTEM=="usb", ATTRS{idVendor}=="2b03", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb_device", ATTRS{idVendor}=="2b03", MODE="0666", GROUP="plugdev"' \
  | sudo tee /etc/udev/rules.d/69-stereolabs-zed.rules

# 2. Reload and trigger udev
sudo udevadm control --reload-rules && sudo udevadm trigger

# 3. Verify the device permissions changed (should now show GROUP=plugdev or mode 0666)
ls -la /dev/bus/usb/003/005 /dev/bus/usb/004/002
