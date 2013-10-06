name "provisioner-dhcp-server"
description "Provisioner DHCP Server role"
run_list("recipe[dhcp]")
default_attributes()
override_attributes()
