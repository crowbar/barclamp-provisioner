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

# Set up the OS images as well
# Common to all OSes
admin_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
domain_name = node[:dns].nil? ? node[:domain] : (node[:dns][:domain] || node[:domain])
web_port = node[:provisioner][:web_port]
use_local_security = node[:provisioner][:use_local_security]
provisioner_web="http://#{admin_ip}:#{web_port}"
append_line = "append root=/sledgehammer.iso rootfstype=iso9660 rootflags=loop"
os_token="#{node[:platform]}-#{node[:platform_version]}"

tftproot = node[:provisioner][:root]

if node[:provisioner][:use_serial_console]
  append_line += " console=tty0 console=ttyS1,115200n8"
end
if ::File.exists?("/etc/crowbar.install.key")
  append_line += " crowbar.install.key=#{::File.read("/etc/crowbar.install.key").chomp.strip}"
end

pxecfg_dir="#{tftproot}/discovery/pxelinux.cfg"

bash "Install pxelinux.0" do
  code "cp /usr/lib/syslinux/pxelinux.0 #{tftproot}/discovery"
  not_if do ::File.exists?("#{tftproot}/discovery/pxelinux.0") end
end

# Generate the appropriate pxe config file for each state
[ "discovery","update","hwinstall"].each do |state|
  template "#{pxecfg_dir}/#{state}" do
    mode 0644
    owner "root"
    group "root"
    source "default.erb"
    variables(:append_line => "#{append_line} crowbar.state=#{state}",
              :install_name => state,
              :initrd => "initrd0.img",
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

package "nginx"

service "nginx" do
  action :disable
end

link "/etc/nginx/sites-enabled/default" do
  action :delete
end

# Set up our the webserver for the provisioner.
file "/var/log/provisioner-webserver.log" do
  owner "nobody"
  action :create
end

template "/etc/nginx/provisioner.conf" do
  source "base-nginx.conf.erb"
  variables(:docroot => "/tftpboot",
            :port => 8091,
            :logfile => "/var/log/provisioner-webserver.log",
            :pidfile => "/var/run/provisioner-webserver.pid")
end

bluepill_service "provisioner-webserver" do
  variables(:processes => [ {
                              "daemonize" => false,
                              "pid_file" => "/var/run/provisioner-webserver.pid",
                              "start_command" => "nginx -c /etc/nginx/provisioner.conf",
                              "stderr" => "/var/log/provisioner-webserver.log",
                              "stdout" => "/var/log/provisioner-webserver.log",
                              "name" => "provisioner-webserver"
                            } ] )
  action [:create, :load]
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
                              "start_command" => "in.tftpd -4 -L -a 0.0.0.0:69 -s #{tftproot}",
                              "stderr" => "/dev/null",
                              "stdout" => "/dev/null",
                              "name" => "tftpd"
                            } ] )
  action [:create, :load]
end

bash "copy validation pem" do
  code <<-EOH
  cp /etc/chef/validation.pem #{tftproot}
  chmod 0444 #{tftproot}/validation.pem
EOH
  not_if "test -f #{tftproot}/validation.pem"  
end

# put our statically-linked curl into place
directory "/tftpboot/curl"
bash "copy curl into place" do
  code "cp /tftpboot/files/curl /tftpboot/curl/"
  not_if do ::File.exist?("/tftpboot/curl/curl") end
end

# By default, install the same OS that the admin node is running
# If the comitted proposal has a defualt, try it.
# Otherwise use the OS the provisioner node is using.

unless default_os = node[:provisioner][:default_os]
  node[:provisioner][:default_os] = default = "#{node[:platform]}-#{node[:platform_version]}"
  node.save
end

node[:provisioner][:repositories] ||= Mash.new
node[:provisioner][:supported_oses].each do |os,params|
  
  web_path = "#{provisioner_web}/#{os}"
  admin_web="#{web_path}/install"
  crowbar_repo_web="#{web_path}/crowbar-extra"
  os_dir="#{tftproot}/#{os}"
  os_codename=node[:lsb][:codename]
  role="#{os}_install"
  replaces={
    '%os_site%'         => web_path,
    '%os_install_site%' => admin_web
  }
  append = params["append"]
  initrd = params["initrd"]
  kernel = params["kernel"]

  # Sigh.  There has to be a more elegant way.
  replaces.each { |k,v|
    append.gsub!(k,v)
  }
  # Don't bother for OSes that are not actaully present on the provisioner node.
  next unless File.directory? os_dir and File.directory? "#{os_dir}/install"

  # Index known barclamp repositories for this OS
  node[:provisioner][:repositories][os_token] ||= Mash.new
  if File.exists? "#{os_dir}/crowbar-extra" and File.directory? "#{os_dir}/crowbar-extra"
    Dir.foreach("#{os_dir}/crowbar-extra") do |f|
      next unless File.symlink? "#{os_dir}/crowbar-extra/#{f}"
      node[:provisioner][:repositories][os_token][f] = case
        when os_token =~ /ubuntu/
          "deb http://#{admin_ip}:#{web_port}/#{os_token}/crowbar-extra/#{f} /"
        when os_token =~ /(redhat|centos)/
          "baseurl=http://#{admin_ip}:#{web_port}/#{os_token}/crowbar-extra/#{f}"
        else
          raise ::RangeError.new("Cannot handle repos for #{os_token}")
        end
    end
  end

  # If we were asked to use a serial console, arrange for it.
  if node[:provisioner][:use_serial_console]
    append << " console=tty0 console=ttyS1,115200n8"
  end
  
  # Make sure we get a crowbar install key as well.
  if ::File.exists?("/etc/crowbar.install.key")
    append << " crowbar.install.key=#{::File.read("/etc/crowbar.install.key").chomp.strip}"
  end

  # These should really be made libraries or something.
  case
  when /^(redhat|centos)/ =~ os
    # Add base OS install repo for redhat/centos
    node[:provisioner][:repositories][os_token]["base"] = "baseurl=http://#{admin_ip}:#{web_port}/#{os_token}/install/Server"
    # Default kickstarts and crowbar_join scripts for redhat.
    template "#{os_dir}/compute.ks" do
      mode 0644
      source "compute.ks.erb"
      owner "root"
      group "root"
      variables(
                :admin_node_ip => admin_ip,
                :web_port => web_port,
                :repos => node[:provisioner][:repositories][os_token],
                :admin_web => admin_web,
                :crowbar_join => "#{web_path}/crowbar_join.sh")  
    end
    template "#{os_dir}/crowbar_join.sh" do
      mode 0644
      owner "root"
      group "root"
      source "crowbar_join.redhat.sh.erb"
      variables(:admin_web => admin_web,
                :os_codename => os_codename,
                :crowbar_repo_web => crowbar_repo_web,
                :admin_ip => admin_ip,
                :provisioner_web => provisioner_web,
                :web_path => web_path)
    end

  when /^ubuntu/ =~ os
    node[:provisioner][:repositories][os_token]["base"] = "http://#{admin_ip}:#{web_port}/#{os_token}/install"
    # Default files needed for Ubuntu.
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
    
    template "#{os_dir}/net-post-install.sh" do
      mode 0644
      owner "root"
      group "root"
      variables(:admin_web => admin_web,
                :os_codename => os_codename,
                :repos => node[:provisioner][:repositories][os_token],
                :admin_ip => admin_ip,
                :provisioner_web => provisioner_web,
                :web_path => web_path)
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
      variables(:admin_web => admin_web,
                :os_codename => os_codename,
                :crowbar_repo_web => crowbar_repo_web,
                :admin_ip => admin_ip,
                :provisioner_web => provisioner_web,
                :web_path => web_path)
    end
  end
  
  # Create the pxe linux config for this OS.
  template "#{pxecfg_dir}/#{role}" do
    mode 0644
    owner "root"
    group "root"
    source "default.erb"
    variables(:append_line => "#{append}",
              :install_name => os,
              :webserver => "#{admin_web}",
              :initrd => "../#{os}/install/#{initrd}",
              :kernel => "../#{os}/install/#{kernel}")
  end
  
  # If this is our default, create the appropriate symlink.
  if os == default_os
    link "#{pxecfg_dir}/os_install" do
      link_type :symbolic
      to "#{role}"
    end
  end
end
# Save this node config.
node.save
