
domain_name = node[:dns].nil? ? node[:domain] : (node[:dns][:domain] || node[:domain])
admin_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
admin_net = node[:network][:networks]["admin"]
dhcp_start = admin_net[:ranges]["dhcp"]["start"]
dhcp_end = admin_net[:ranges]["dhcp"]["end"]
lease_time = node[:provisioner][:dhcp]["lease-time"]

dhcp_subnet admin_net["subnet"] do
  action :add
  broadcast admin_net["broadcast"]
  netmask admin_net["netmask"]
  routers (admin_net["router"].nil? ? [ admin_ip ] : [ admin_net["router"] ])
  options [ "option domain-name \"#{domain_name}\"",
            "option domain-name-servers #{admin_ip}",
            "range #{dhcp_start} #{dhcp_end}",
            "default-lease-time #{lease_time}",
            "max-lease-time #{lease_time}",
            "filename \"/discovery/pxelinux.0\"" ]
end
