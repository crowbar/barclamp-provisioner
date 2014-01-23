

domain_name = node[:dns].nil? ? node[:domain] : (node[:dns][:domain] || node[:domain])
admin_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
admin_net = node[:network][:networks]["admin"]
lease_time = node[:provisioner][:dhcp]["lease-time"]
pool_opts = {
  "dhcp" => ['allow unknown-clients',
             '      if option arch = 00:06 {
      filename = "discovery/bootia32.efi";
   } else if option arch = 00:07 {
      filename = "discovery/bootx64.efi";
   } else if option arch = 00:09 {
      filename = "discovery/bootx64.efi";
   } else {
      filename = "discovery/pxelinux.0";
   }',
             "next-server #{admin_ip}" ],
  "host" => ['deny unknown-clients']
}
dhcp_subnet admin_net["subnet"] do
  action :add
  network admin_net
  pools ["dhcp","host"]
  pool_options pool_opts
  options [ "option domain-name \"#{domain_name}\"",
            "option domain-name-servers #{admin_ip}",
            "default-lease-time #{lease_time}",
            "max-lease-time #{lease_time}"]
end
