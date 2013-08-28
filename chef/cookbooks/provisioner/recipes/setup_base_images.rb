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

tftproot = node[:provisioner][:root]

pxecfg_dir="#{tftproot}/discovery/pxelinux.cfg"
pxecfg_default="#{tftproot}/discovery/pxelinux.cfg/default"
uefi_dir="#{tftproot}/discovery"

["share","lib"].each do |d|
  next unless ::File.exists?("/usr/#{d}/syslinux/pxelinux.0")
  bash "Install pxelinux.0" do
    code "cp /usr/#{d}/syslinux/pxelinux.0 #{tftproot}/discovery"
    not_if "cmp /usr/#{d}/syslinux/pxelinux.0 #{tftproot}/discovery/pxelinux.0"
  end
  break
end

if node[:platform] != "suse"
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
else
  bash "Install bootx64.efi" do
    code "cp /usr/lib64/efi/elilo.efi #{uefi_dir}/bootx64.efi"
    not_if "cmp /usr/lib64/efi/elilo.efi #{uefi_dir}/bootx64.efi"
  end
end


# FIXME: What is the purpose of this, really? If pxecfg_default does not exist
# the root= parameters will not get appended to the kernel commandline. (Luckily
# we don't need those with the SLES base sledgehammer)
# Later on pxecfg_default will even be replace with a link to "discovery"
# Probably this pxecfg_default check can go a way and we can just unconditionally
# append the root= parameters?
if File.exists? pxecfg_default
  append_line = IO.readlines(pxecfg_default).detect{|l| /APPEND/i =~ l}
  if append_line
    append_line = append_line.strip.gsub(/(^APPEND |initrd=[^ ]+|console=[^ ]+|rhgb|quiet|crowbar\.[^ ]+)/i,'').strip
  elsif node[:platform] != "suse"
    append_line = "root=/sledgehammer.iso rootfstype=iso9660 rootflags=loop"
  end
end

if node[:provisioner][:use_serial_console]
  append_line += " console=tty0 console=ttyS1,115200n8"
end

if ::File.exists?("/etc/crowbar.install.key")
  append_line += " crowbar.install.key=#{::File.read("/etc/crowbar.install.key").chomp.strip}"
end
append_line = append_line.split.join(' ')
node.set[:provisioner][:sledgehammer_append_line] = append_line

directory pxecfg_dir do
  recursive true
  mode 0755
  owner "root"
  group "root"
  action :create
end

template pxecfg_default do
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

if node[:platform] == "suse"

  include_recipe "apache2"

  template "#{node[:apache][:dir]}/vhosts.d/provisioner.conf" do
    source "base-apache.conf.erb"
    mode 0644
    variables(:docroot => "/srv/tftpboot",
              :port => 8091,
              :logfile => "/var/log/apache2/provisioner-access_log",
              :errorlog => "/var/log/apache2/provisioner-error_log")
    notifies :reload, resources(:service => "apache2")
  end

else

  include_recipe "bluepill"


  case node.platform
  when "ubuntu","debian"
    package "nginx-light"
  else
    package "nginx"
  end

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
    variables(:docroot => tftproot,
              :port => 8091,
              :logfile => "/var/log/provisioner-webserver.log",
              :pidfile => "/var/run/provisioner-webserver.pid")
  end

file "/var/run/provisioner-webserver.pid" do
  mode "0644"
  action :create
end

template "/etc/bluepill/provisioner-webserver.pill" do
  source "provisioner-webserver.pill.erb"
end

  bluepill_service "provisioner-webserver" do
    action [:load, :start]
  end

end # !suse

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
when "suse"
  package "tftp"
end

cookbook_file "/etc/tftpd.conf" do
  owner "root"
  group "root"
  mode "0644"
  action :create
  source "tftpd.conf"
end

if node[:platform] == "suse"
  service "tftp" do
    # just enable, don't start (xinetd takes care of it)
    enabled true
    action [ :enable ]
  end

  service "xinetd" do
    running true
    enabled true
    action [ :enable, :start ]
    supports :reload => true
    subscribes :reload, resources(:service => "tftp"), :immediately
  end

  template "/etc/xinetd.d/tftp" do
    source "tftp.erb"
    variables( :tftproot => tftproot )
    notifies :reload, resources(:service => "xinetd")
  end
else
  template "/etc/bluepill/tftpd.pill" do
    source "tftpd.pill.erb"
    variables( :tftproot => tftproot )
  end

  bluepill_service "tftpd" do
    action [:load, :start]
  end
end

bash "copy validation pem" do
  code <<-EOH
  cp /etc/chef/validation.pem #{tftproot}
  chmod 0444 #{tftproot}/validation.pem
EOH
  not_if "test -f #{tftproot}/validation.pem"
end

# By default, install the same OS that the admin node is running
# If the comitted proposal has a default, try it.
# Otherwise use the OS the provisioner node is using.

unless default_os = node[:provisioner][:default_os]
  node.set[:provisioner][:default_os] = default = "#{node[:platform]}-#{node[:platform_version]}"
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
        node.set[:provisioner][:repositories][os][f][bin] = true if
          File.exists? "#{os_dir}/crowbar-extra/#{f}/Packages.gz"
        node.set[:provisioner][:repositories][os][f][src] = true if
          File.exists? "#{os_dir}/crowbar-extra/#{f}/Sources.gz"
      when os =~ /(redhat|centos|suse)/
        bin="baseurl=http://#{admin_ip}:#{web_port}/#{os}/crowbar-extra/#{f}"
        node.set[:provisioner][:repositories][os][f][bin] = true
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
    node.set[:provisioner][:repositories][os]["base"] = { "baseurl=http://#{admin_ip}:#{web_port}/#{os}/install" => true }

    template "#{os_dir}/crowbar_join.sh" do
      mode 0644
      owner "root"
      group "root"
      source "crowbar_join.suse.sh.erb"
      variables(:admin_ip => admin_ip)
    end

  when /^(redhat|centos)/ =~ os
    # Add base OS install repo for redhat/centos
    if ::File.exists? "#{tftproot}/#{os}/install/repodata"
      node.set[:provisioner][:repositories][os]["base"] = { "baseurl=http://#{admin_ip}:#{web_port}/#{os}/install" => true }
    else
      node.set[:provisioner][:repositories][os]["base"] = { "baseurl=http://#{admin_ip}:#{web_port}/#{os}/install/Server" => true }
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
    node.set[:provisioner][:repositories][os]["base"] = { "http://#{admin_ip}:#{web_port}/#{os}/install" => true }
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

  when /^(hyperv|windows)/ =~ os

    # Copy the crowbar_join script
    cookbook_file "/tftpboot/windows-6.2/extra/crowbar_join.ps1" do
      owner "root"
      group "root"
      mode "0644"
      action :create
      source "crowbar_join.ps1"
    end

    # Copy the script required for setting the hostname
    cookbook_file "/tftpboot/windows-6.2/extra/set_hostname.ps1" do
      owner "root"
      group "root"
      mode "0644"
      action :create
      source "set_hostname.ps1"
    end

    # Also copy the required files to install chef-client and communicate with Crowbar
    cookbook_file "/tftpboot/windows-6.2/extra/chef-client-11.4.4-2.windows.msi" do
      owner "root"
      group "root"
      mode "0644"
      action :create
      source "chef-client-11.4.4-2.windows.msi"
    end
    cookbook_file "/tftpboot/windows-6.2/extra/curl.exe" do
      owner "root"
      group "root"
      mode "0644"
      action :create
      source "curl.exe"
    end

  end

  node.set[:provisioner][:available_oses] ||= Mash.new
  node.set[:provisioner][:available_oses][os] ||= Mash.new
  if /^(hyperv|windows)/ =~ os
    node.set[:provisioner][:available_oses][os][:kernel] = "../#{os}/#{kernel}"
    node.set[:provisioner][:available_oses][os][:initrd] = " "
    node.set[:provisioner][:available_oses][os][:append_line] = " "
  else
    node.set[:provisioner][:available_oses][os][:kernel] = "../#{os}/install/#{kernel}"
    node.set[:provisioner][:available_oses][os][:initrd] = "../#{os}/install/#{initrd}"
    node.set[:provisioner][:available_oses][os][:append_line] = append
  end
  node.set[:provisioner][:available_oses][os][:webserver] = admin_web
  node.set[:provisioner][:available_oses][os][:install_name] = role
end
# Save this node config.
node.save
