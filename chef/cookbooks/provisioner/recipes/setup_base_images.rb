# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied
# See the License for the specific language governing permissions and
# limitations under the License
#

package "syslinux"

append_line = "append initrd=initrd0.img root=/sledgehammer.iso rootfstype=iso9660 rootflags=loop"
if node[:provisioner][:use_serial_console]
  append_line += " console=tty0 console=ttyS1,115200n8"
end
if ::File.exists?("/etc/crowbar.install.key")
  append_line += " crowbar.install.key=#{::File.read("/etc/crowbar.install.key").chomp.strip}"
end

pxecfg_dir="/tftpboot/discovery/pxelinux.cfg"

# Generate the appropriate pxe config file for each state
[ "discovery","update","hwinstall"].each do |state|
  template "#{pxecfg_dir}/#{state}" do
    mode 0644
    owner "root"
    group "root"
    source "default.erb"
    variables(:append_line => "#{append_line} crowbar.state=#{state}",
              :install_name => state,  
              :kernel => "vmlinuz0")
  end
end

# and the execute state as well
cookbook_file "#{pxecfg_dir}/execute" do
  mode 0644
  owner "root"
  group "root"
  source "localboot.default"
end

# Make discovery our default state
link "#{pxecfg_dir}/default" do
  to "discovery"
end

include_recipe "bluepill"

# Set up our the webserver for the provisioner.
file "/var/log/provisioner-webserver.log" do
  owner "nobody"
  action :create
end

template "/etc/bluepill/provisioner-webserver.pill" do
  variables(:docroot => "/tftpboot",
            :port =>8091,
            :appname => "provisioner-webserver",
            :logfile => "/var/log/provisioner-webserver.log")
  source "provisioner-webserver.pill.erb"
end

bluepill_service "provisioner-webserver" do
  action [:load, :enable, :start]
end

# Set up the TFTP server as well.
case node[:platform]
when "ubuntu", "debian"
  package "tftpd-hpa"
  bash "stop ubuntu tftpd" do
    code "service tftpd-hpa stop; killall in.tftpd; rm /etc/init/tftpd-hpa.conf"
    only_if "test -f /etc/init/tftpd-hpa.conf"
  end
when "redhat","centos"
  package "tftp-server"
end

bluepill_service "tftpd" do
  variables(:processes => [ {
                              "daemonize" => true,
                              "start_command" => "in.tftpd -4 -L -a 0.0.0.0:69 -s /tftpboot",
                              "stderr" => "/dev/null",
                              "stdout" => "/dev/null",
                              "name" => "tftpd"
                            } ] )
  action [:create, :load]
end

bash "copy validation pem" do
  code <<-EOH
  cp /etc/chef/validation.pem /tftpboot
  chmod 0444 /tftpboot/validation.pem
EOH
  not_if "test -f /tftpboot/validation.pem"  
end
case node[:platform]
when "ubuntu","debian"
  directory "/tftpboot/curl"
  
  [ "/usr/bin/curl",
    "/usr/lib/libcurl.so.4",
    "/usr/lib/libidn.so.11",
    "/usr/lib/liblber-2.4.so.2",
    "/usr/lib/libldap_r-2.4.so.2",
    "/usr/lib/libgssapi_krb5.so.2",
    "/usr/lib/libssl.so.0.9.8",
    "/usr/lib/libcrypto.so.0.9.8",
    "/usr/lib/libsasl2.so.2",
    "/usr/lib/libgnutls.so.26",
    "/usr/lib/libkrb5.so.3",
    "/usr/lib/libk5crypto.so.3",
    "/usr/lib/libkrb5support.so.0",
    "/lib/libkeyutils.so.1",
    "/usr/lib/libtasn1.so.3",
    "/lib/librt.so.1",
    "/lib/libcom_err.so.2",
    "/lib/libgcrypt.so.11",
    "/lib/libgpg-error.so.0"
  ].each { |file|
    basefile = file.gsub("/usr/bin/", "").gsub("/usr/lib/", "").gsub("/lib/", "")
    bash "copy #{file} to curl dir" do
      code "cp #{file} /tftpboot/curl"
    not_if "test -f /tftpboot/curl/#{basefile}"
    end  
  }
end

# Set up the OS images as well
# Common to all OSes
admin_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
domain_name = node[:dns].nil? ? node[:domain] : (node[:dns][:domain] || node[:domain])
web_port = node[:provisioner][:web_port]
use_local_security = node[:provisioner][:use_local_security]

# By default, install the same OS that the admin node is running
default_os="#{node[:platform]}-#{node[:platform_version]}"

[ "redhat-5.6", "redhat-5.7", "centos-5.7","ubuntu-10.10" ].each do |os|
  append_line = ""
  if node[:provisioner][:use_serial_console]
    append_line << "console=tty0 console=ttyS1,115200n8 "
  end
  if ::File.exists?("/etc/crowbar.install.key")
    append_line << "crowbar.install.key=#{::File.read("/etc/crowbar.install.key").chomp.strip} "
  end

  admin_web="http://#{admin_ip}:#{web_port}/#{os}/install"
  crowbar_repo_web="http://#{admin_ip}:#{web_port}/#{os}/crowbar-extra"
  os_dir="/tftpboot/#{os}"
  install_state="#{os}_install"
  next unless File.directory? os_dir and File.directory? "#{os_dir}/install"
  case
  when /^(redhat|centos)/ =~ os
    os_repo_web="#{admin_web}/Server"
    append_line << "method=#{admin_web} ks=http://#{admin_ip}:#{web_port}/#{os}/compute.ks ksdevice=bootif initrd=../#{os}/install/images/pxeboot/initrd.img"
    template "#{os_dir}/compute.ks" do
      mode 0644
      source "compute.ks.erb"
      owner "root"
      group "root"
      variables(
                :admin_node_ip => admin_ip,
                :web_port => web_port,
                :os_repo => os_repo_web,
                :crowbar_repo => crowbar_repo_web,
                :admin_web => admin_web,
                :crowbar_join => "http://#{admin_ip}:#{web_port}/#{os}/crowbar_join.sh")  
    end

    template "#{pxecfg_dir}/#{install_state}" do
      mode 0644
      owner "root"
      group "root"
      source "default.erb"
      variables(:append_line => "append " + append_line,
                :install_name => os,  
                :kernel => "../#{os}/install/images/pxeboot/vmlinuz")
    end

    template "#{os_dir}/crowbar_join.sh" do
      mode 0644
      owner "root"
      group "root"
      source "crowbar_join.redhat.sh.erb"
      variables(:admin_ip => admin_ip)
    end
  when /^ubuntu/ =~ os
    append_line << "url=http://#{admin_ip}:#{web_port}/#{os}/net_seed debian-installer/locale=en_US.utf8 console-setup/layoutcode=us localechooser/translation/warn-light=true localechooser/translation/warn-severe=true netcfg/dhcp_timeout=120 netcfg/choose_interface=auto netcfg/get_hostname=\"redundant\" initrd=../#{os}/install/install/netboot/ubuntu-installer/amd64/initrd.gz ramdisk_size=16384 root=/dev/ram rw quiet --"

    template "#{pxecfg_dir}/#{install_state}" do
      mode 0644
      owner "root"
      group "root"
      source "default.erb"
      variables(:append_line => "append " + append_line,
                :install_name => os,  
                :kernel => "../#{os}/install/install/netboot/ubuntu-installer/amd64/linux")
    end
    
    template "#{os_dir}/net_seed" do
      mode 0644
      owner "root"
      group "root"
      source "net_seed.erb"
      variables(:install_name => os,  
                :cc_use_local_security => use_local_security,
                :cc_install_web_port => web_port,
                :cc_built_admin_node_ip => admin_ip,
                :install_path => "#{os}/install")
    end
    
    cookbook_file "#{os_dir}/net-post-install.sh" do
      mode 0644
      owner "root"
      group "root"
      source "net-post-install.sh"
    end
    
    cookbook_file "#{os_dir}/net-pre-install.sh" do
      mode 0644
      owner "root"
      group "root"
      source "net-pre-install.sh"
    end

    template "#{os_dir}/crowbar_join.sh" do
      mode 0644
      owner "root"
      group "root"
      source "crowbar_join.ubuntu.sh.erb"
      variables(:admin_ip => admin_ip)
    end
    
  end

  if os == default_os
    link "#{pxecfg_dir}/os_install" do
      link_type :symbolic
      to "#{install_state}"
    end
  end
end
