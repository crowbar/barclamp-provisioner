name "provisioner-dhcp-database"
description "Provisioner DHCP Database role"
run_list("recipe[provisioner::update_nodes]")
default_attributes()
override_attributes()
