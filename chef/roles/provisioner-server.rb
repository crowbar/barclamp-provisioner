# -*- encoding : utf-8 -*-

name "provisioner-server"
description "Provisioner Server role - Apt and Networking"
run_list(
         "recipe[utils]", 
         "recipe[dhcp]",
         "recipe[nfs-server]",
         "recipe[provisioner::dhcp_update]",
         "recipe[provisioner::update_nodes]",
         "recipe[provisioner::setup_base_images]"
)
default_attributes()
override_attributes()

