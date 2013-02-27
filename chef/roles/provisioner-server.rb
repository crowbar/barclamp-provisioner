
name "provisioner-server"
description "Provisioner Server role - Apt and Networking"
run_list(
         "recipe[utils]",
         "recipe[dhcp]",
         "recipe[nfs-server]",
         "recipe[provisioner::dhcp_update]",
         "recipe[provisioner::setup_base_images]",
         "recipe[provisioner::update_nodes]"
)
default_attributes "provisioner" => {
  "online" => false,
  "upstream_proxy" => "",
  "default_user" => "crowbar",
  "default_password_hash" => "$1$BDC3UwFr$/VqOWN1Wi6oM0jiMOjaPb.",
  "supported_oses" => {
    "ubuntu-12.04" => {
      "initrd" => "install/netboot/ubuntu-installer/amd64/initrd.gz",
      "kernel" => "install/netboot/ubuntu-installer/amd64/linux",
      "append" => "debian-installer/locale=en_US.utf8 console-setup/layoutcode=us keyboard-configuration/layoutcode=us netcfg/dhcp_timeout=120 netcfg/choose_interface=auto root=/dev/ram rw quiet --",
      "online_mirror" => "http://us.archive.ubuntu.com/ubuntu/",
      "codename" => "precise"
    },
    "redhat-6.2" => {
      "initrd" => "images/pxeboot/initrd.img",
      "kernel" => "images/pxeboot/vmlinuz",
      "append" => "method=%os_install_site%"
    },
    "centos-6.2" => {
      "initrd" => "images/pxeboot/initrd.img",
      "kernel" => "images/pxeboot/vmlinuz",
      "append" => "method=%os_install_site%",
      "online_mirror" => "http://mirror.centos.org/centos/6/"
    },
    "suse-11.2" => {
      "initrd" => "boot/x86_64/loader/initrd",
      "kernel" => "boot/x86_64/loader/linux",
      "append" => "install=%os_install_site%"
    }
  },
  "root" => "/tftpboot",
  "web_port" => 8091,
  "use_local_security" => true,
  "use_serial_console" => false,
  "dhcp" => {
    "lease_time" => 60,
    "state_machine" => {
      "debug" => "debug",
      "delete" => "delete",
      "discovered" => "discovery",
      "discovering" => "discovery",
      "hardware-installed" => "os_install",
      "hardware-installing" => "hwinstall",
      "hardware-updated" => "execute",
      "hardware-updating" => "update",
      "installed" => "execute",
      "installing" => "os_install",
      "ready" => "execute",
      "readying" => "execute",
      "reinstall" => "os_install",
      "reset" => "reset",
      "update" => "update"
    }
  },
  "config" => { "environment" => "provisioner-base-config" }
}
override_attributes()
