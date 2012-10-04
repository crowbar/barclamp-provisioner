# Copyright 2011, Dell
# Copyright 2012, SUSE Linux Products GmbH
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
append_line = ''
os_token="#{node[:platform]}-#{node[:platform_version]}"

tftproot = node[:provisioner][:root]

if node[:provisioner][:use_serial_console]
  append_line += " console=tty0 console=ttyS1,115200n8"
end

pxecfg_dir="#{tftproot}/discovery/pxelinux.cfg"
pxecfg_default="#{tftproot}/discovery/pxelinux.cfg/default"
uefi_dir="#{tftproot}/discovery"

["share","lib"].each do |d|
  next unless ::File.exists?("/usr/#{d}/syslinux/pxelinux.0")
  bash "Install pxelinux.0" do
    code "cp /usr/#{d}/syslinux/pxelinux.0 #{tftproot}/discovery"
    not_if do ::File.exists?("#{tftproot}/discovery/pxelinux.0") end
  end
  break
end

bash "Install elilo as UEFI netboot loader" do
  code <<EOC
cd #{uefi_dir}
tar xzf '#{tftproot}/files/elilo-3.14-all.tar.gz'
mv elilo-3.14-x86_64.efi bootx64.efi
mv elilo-3.14-ia32.efi bootia32.efi
mv elilo-3.14-ia64.efi bootia64.efi
rm elilo*.efi elilo*.tar.gz || :
EOC
  not_if "test -f '#{uefi_dir}/bootx64.efi'"
end


if File.exists? pxecfg_default
  append_line = IO.readlines(pxecfg_default).detect{|l| /APPEND/i =~ l}
  if append_line
    append_line = append_line.strip.gsub(/(^APPEND |initrd=[^ ]+|rhgb|quiet|crowbar\.[^ ]+)/i,'')
  else
    append_line = "root=/sledgehammer.iso rootfstype=iso9660 rootflags=loop"
  end
end

if ::File.exists?("/etc/crowbar.install.key")
  append_line += " crowbar.install.key=#{::File.read("/etc/crowbar.install.key").chomp.strip}"
end
append_line = append_line.split.join(' ')
node[:provisioner][:sledgehammer_append_line] = append_line

template "#{pxecfg_dir}/default" do
  mode 0644
  owner "root"
  group "root"
  source "default.erb"
  variables(:append_line => "#{append_line} crowbar.state=discovery",
            :install_name => "discovery",
            :initrd => "initrd0.img",
            :kernel => "vmlinuz0")
end
template "#{uefi_dir}/elilo.conf" do
  mode 0644
  owner "root"
  group "root"
  source "default.elilo.erb"
  variables(:append_line => "#{append_line} crowbar.state=discovery",
            :install_name => "discovery",
            :initrd => "initrd0.img",
            :kernel => "vmlinuz0")
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
  append = params["append"]
  initrd = params["initrd"]
  kernel = params["kernel"]

  # Don't bother for OSes that are not actaully present on the provisioner node.
  next unless File.directory? os_dir and File.directory? "#{os_dir}/install"

  # Index known barclamp repositories for this OS
  node[:provisioner][:repositories][os] ||= Mash.new
  if File.exists? "#{os_dir}/crowbar-extra" and File.directory? "#{os_dir}/crowbar-extra"
    Dir.foreach("#{os_dir}/crowbar-extra") do |f|
      next unless File.symlink? "#{os_dir}/crowbar-extra/#{f}"
      node[:provisioner][:repositories][os][f] ||= Hash.new
      case
      when os =~ /(ubuntu|debian)/
        bin="deb http://#{admin_ip}:#{web_port}/#{os}/crowbar-extra/#{f} /"
        src="deb-src http://#{admin_ip}:#{web_port}/#{os}/crowbar-extra/#{f} /"
        node[:provisioner][:repositories][os][f][bin] = true if
          File.exists? "#{os_dir}/crowbar-extra/#{f}/Packages.gz"
        node[:provisioner][:repositories][os][f][src] = true if
          File.exists? "#{os_dir}/crowbar-extra/#{f}/Sources.gz"
      when os =~ /(redhat|centos|suse)/
        bin="baseurl=http://#{admin_ip}:#{web_port}/#{os}/crowbar-extra/#{f}"
        node[:provisioner][:repositories][os][f][bin] = true
        else
          raise ::RangeError.new("Cannot handle repos for #{os}")
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
  when /^(suse)/ =~ os
    # Add base OS install repo for suse
    node[:provisioner][:repositories][os]["base"] = { "baseurl=http://#{admin_ip}:#{web_port}/#{os}/install" => true }

    template "#{os_dir}/crowbar_join.sh" do
      mode 0644
      owner "root"
      group "root"
      source "crowbar_join.suse.sh.erb"
      variables(:admin_ip => admin_ip)
    end

  when /^(redhat|centos)/ =~ os
    # Add base OS install repo for redhat/centos
    if ::File.exists? "/tftpboot/#{os}/install/repodata"
      node[:provisioner][:repositories][os]["base"] = { "baseurl=http://#{admin_ip}:#{web_port}/#{os}/install" => true }
    else
      node[:provisioner][:repositories][os]["base"] = { "baseurl=http://#{admin_ip}:#{web_port}/#{os}/install/Server" => true }
    end
    # Default kickstarts and crowbar_join scripts for redhat.
    
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
    node[:provisioner][:repositories][os]["base"] = { "http://#{admin_ip}:#{web_port}/#{os}/install" => true }
    # Default files needed for Ubuntu.
    

    template "#{os_dir}/net-post-install.sh" do
      mode 0644
      owner "root"
      group "root"
      variables(:admin_web => admin_web,
                :os_codename => os_codename,
                :repos => node[:provisioner][:repositories][os],
                :admin_ip => admin_ip,
                :provisioner_web => provisioner_web,
                :web_path => web_path)
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

  node[:provisioner][:available_oses] ||= Mash.new
  node[:provisioner][:available_oses][os] ||= Mash.new
  node[:provisioner][:available_oses][os][:append_line] = append
  node[:provisioner][:available_oses][os][:webserver] = admin_web
  node[:provisioner][:available_oses][os][:install_name] = role
  node[:provisioner][:available_oses][os][:initrd] = "../#{os}/install/#{initrd}"
  node[:provisioner][:available_oses][os][:kernel] = "../#{os}/install/#{kernel}"
end
# Save this node config.
node.save
