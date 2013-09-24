domain_name = (node[:crowbar][:dns][:domain] || node[:domain] rescue node[:domain])
admin_ip = node.address("admin",IP::IP4).addr
admin_net = node[:crowbar][:network][:admin]
lease_time = node[:crowbar][:provisioner][:server][:dhcp][:lease_time]
net_pools = admin_net["ranges"].select{|range|["dhcp","host"].include? range["name"]}
  
pool_opts = {
  "dhcp" => ['allow unknown-clients',
             '      if option arch = 00:06 {
      filename = "discovery/bootia32.efi";
   } else if option arch = 00:07 {
      filename = "discovery/bootx64.efi";
   } else {
      filename = "discovery/pxelinux.0";
   }',
             "next-server #{admin_ip}" ],
  "host" => ['deny unknown-clients']
}

dhcp_subnet IP.coerce(net_pools[0]["first"]).network do
  action :add
  network admin_net
  pools net_pools
  pool_options pool_opts
  options [ "option domain-name \"#{domain_name}\"",
            "option domain-name-servers #{node.address("admin",IP::IP4).addr}",
            "default-lease-time #{lease_time}",
            "max-lease-time #{lease_time * 3}"]
end
