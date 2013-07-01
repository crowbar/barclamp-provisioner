case node[:platform]
when "suse"
  default[:provisioner][:root] = "/srv/tftpboot"
else
  default[:provisioner][:root] = "/tftpboot"
end

default[:provisioner][:coredump] = false
