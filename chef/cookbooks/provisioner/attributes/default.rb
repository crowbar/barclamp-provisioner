case node[:platform]
when "suse"
  default[:provisioner][:root] = "/srv/tftpboot"
else
  default[:provisioner][:root] = "/tftpboot"
end

default[:provisioner][:coredump] = false
default[:provisioner][:dhcp_hosts] = "/etc/dhcp3/hosts.d/"
