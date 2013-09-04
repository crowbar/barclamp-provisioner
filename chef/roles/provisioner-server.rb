
name "provisioner-server"
description "Provisioner Server role - Apt and Networking"
run_list(
         "recipe[utils]",
         "recipe[provisioner::make_ssh_keys]",
         "recipe[dhcp]",
         "recipe[nfs-server]",
         "recipe[provisioner::dhcp_update]",
         "recipe[provisioner::setup_base_images]"
)
default_attributes()
override_attributes()
