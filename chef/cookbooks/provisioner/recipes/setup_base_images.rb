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

admin_ip = node.address.addr
domain_name = node[:dns].nil? ? node[:domain] : (node[:dns][:domain] || node[:domain])
web_port = node[:provisioner][:web_port]
use_local_security = node[:provisioner][:use_local_security]
provisioner_web="http://#{admin_ip}:#{web_port}"
append_line = ''
os_token="#{node[:platform]}-#{node[:platform_version]}"
tftproot = node[:provisioner][:root]
discover_dir="#{tftproot}/discovery"
pxecfg_dir="#{discover_dir}/pxelinux.cfg"
uefi_dir=discover_dir
pxecfg_default="#{pxecfg_dir}/default"

# FIXME: What is the purpose of this, really? If pxecfg_default does not exist
# the root= parameters will not get appended to the kernel commandline. (Luckily
# we don't need those with the SLES base sledgehammer)
# Later on pxecfg_default will even be replace with a link to "discovery"
# Probably this pxecfg_default check can go a way and we can just unconditionally
# append the root= parameters?
# ANSWER:  This hackery exists to automatically do The Right Thing in handling
# CentOS 5 vs. CentOS 6 based sledgehammer images.
if File.exists? pxecfg_default
  append_line = IO.readlines(pxecfg_default).detect{|l| /APPEND/i =~ l}
  if append_line
    append_line = append_line.strip.gsub(/(^APPEND |initrd=[^ ]+|console=[^ ]+|rhgb|quiet|crowbar\.[^ ]+)/i,'').strip
  elsif node[:platform] != "suse"
    append_line = "root=/sledgehammer.iso rootfstype=iso9660 rootflags=loop"
  end
end

if ::File.exists?("/etc/crowbar.install.key")
  append_line += " crowbar.install.key=#{::File.read("/etc/crowbar.install.key").chomp.strip}"
end

if node[:provisioner][:use_serial_console]
  append_line += " console=tty0 console=ttyS1,115200n8"
end

# Generate the appropriate pxe config file for each state
[ "discovery","update","hwinstall","debug"].each do |state|
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

  # Do uefi as well.
  template "#{uefi_dir}/#{state}.uefi" do
    mode 0644
    owner "root"
    group "root"
    source "default.elilo.erb"
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

# This is designed to fail.  Success here is not an option.
template "#{uefi_dir}/execute.uefi" do
  mode 0644
  owner "root"
  group "root"
  source "default.elilo.erb"
  variables(:append_line => "fake",
            :install_name => "execute",
            :initrd => "__fake",
            :kernel => "__fake")
end

# Make discovery our default state
link "#{pxecfg_dir}/default" do
  to "discovery"
end
link "#{uefi_dir}/elilo.conf" do
  to "discovery.uefi"
end

# We have a debugging image available.  Make it available.
#if File.exists? "#{tftproot}/omsahammer/pxelinux.cfg/default"
#  bash "Setup omsahammer image" do
#    code <<EOC
#sed -e 's@(vmlinuz0|initrd0\.image)@/omsahammer/\1@' < \
#    "#{tftproot}/omsahammer/pxelinux.cfg/default" > \
#    "#{tftproot}/pxelinux.cfg/debug"
#EOC
#    not_if { File.exists? "#{tftproot}/pxelinux.cfg/debug" }
#  end
#end

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

end # !suse

# Set up our cluster HTTP proxy for package installs
package "polipo"
service "polipo" do
  action :enable
  supports :stop => true, :start => true, :restart => true
end

template "/etc/polipo/config" do
  source "polipo-conf.erb"
  mode 0644
  variables(:allowed_clients => "127.0.0.1, #{node.all_addresses.map{|a|a.network.to_s}.sort.join(", ")}",
            :upstream_proxy => (node[:provisioner][:upstream_proxy] || "" rescue "")
            )
  notifies :restart, resources(:service => "polipo"), :immediately
end

template "/etc/polipo/uncachable" do
  source "polipo-uncachable.erb"
  mode 0644
  variables(:provisioner_web => ::Regexp.escape("#{admin_ip}"))
  notifies :restart, resources(:service => "polipo"), :immediately
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
when "suse"
  package "tftp"
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
  end
else
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
end

bash "copy validation pem" do
  code <<-EOH
  cp /etc/chef/validation.pem #{tftproot}
  chmod 0444 #{tftproot}/validation.pem
EOH
  not_if "test -f #{tftproot}/validation.pem"
end

# put our statically-linked curl into place
#directory "/tftpboot/curl"
#bash "copy curl into place" do
#  code "cp /tftpboot/files/curl /tftpboot/curl/"
#  not_if do ::File.exist?("/tftpboot/curl/curl") end
#end

# By default, install the same OS that the admin node is running
# If the comitted proposal has a defualt, try it.
# Otherwise use the OS the provisioner node is using.

unless default_os = node[:provisioner][:default_os]
  node[:provisioner][:default_os] = default = os_token
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
  node[:provisioner][:repositories][os] ||= Mash.new
  if File.exists? "#{os_dir}/crowbar-extra" and File.directory? "#{os_dir}/crowbar-extra"
    Dir.foreach("#{os_dir}/crowbar-extra") do |f|
      next unless File.symlink? "#{os_dir}/crowbar-extra/#{f}"
      node[:provisioner][:repositories][os][f] ||= Mash.new
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

  if node[:provisioner][:online]
    data_bag("barclamps").each do |bc_name|
      bc = data_bag_item("barclamps",bc_name)
      if bc["debs"]
        bc["debs"]["repos"].each do |repo|
          node[:provisioner][:repositories][os]["#{bc_name}_online"] ||= Mash.new
          node[:provisioner][:repositories][os]["#{bc_name}_online"][repo] = true
        end if bc["debs"]["repos"]
        bc["debs"][os]["repos"].each do |repo|
          node[:provisioner][:repositories][os]["#{bc_name}_online"] ||= Mash.new
          node[:provisioner][:repositories][os]["#{bc_name}_online"][repo] = true
        end if (bc["debs"][os]["repos"] rescue nil)
      end if os =~ /(ubuntu|debian)/
      if bc["rpms"]
        bc["rpms"]["repos"].each do |repo|
          node[:provisioner][:repositories][os]["#{bc_name}_online"] ||= Mash.new
          node[:provisioner][:repositories][os]["#{bc_name}_online"][repo] = true
        end if bc["rpms"]["repos"]
        bc["rpms"][os]["repos"].each do |repo|
          node[:provisioner][:repositories][os]["#{bc_name}_online"] ||= Mash.new
          node[:provisioner][:repositories][os]["#{bc_name}_online"][repo] = true
        end if (bc["rpms"][os]["repos"] rescue nil)
      end if os =~ /(centos|redhat)/
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
    template "#{os_dir}/autoyast.xml" do
      mode 0644
      source "autoyast.xml.erb"
      owner "root"
      group "root"
      variables(
                :admin_node_ip => admin_ip,
                :web_port => web_port,
                :repos => node[:provisioner][:repositories][os],
                :admin_web => admin_web,
                :crowbar_join => "#{web_path}/crowbar_join.sh")
    end

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
    template "#{os_dir}/compute.ks" do
      mode 0644
      source "compute.ks.erb"
      owner "root"
      group "root"
      variables(
                :admin_node_ip => admin_ip,
                :web_port => web_port,
                :online => node[:provisioner][:online],
                :proxy => "http://#{node.address.addr}:8123/",
                :provisioner_web => provisioner_web,
                :repos => node[:provisioner][:repositories][os],
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
    node[:provisioner][:repositories][os]["base"] = { "http://#{admin_ip}:#{web_port}/#{os}/install" => true }
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
                :repos => node[:provisioner][:repositories][os],
                :admin_ip => admin_ip,
                :online => node[:provisioner][:online],
                :provisioner_web => provisioner_web,
                :proxy => "http://#{node.address.addr}:8123/",
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

  # Create the pxe linux config for this OS.
  template "#{pxecfg_dir}/#{role}" do
    mode 0644
    owner "root"
    group "root"
    source "default.erb"
    variables(:append_line => "#{append}",
              :install_name => os,
              :initrd => "../#{os}/install/#{initrd}",
              :kernel => "../#{os}/install/#{kernel}")
  end

  template "#{uefi_dir}/#{role}.uefi" do
    mode 0644
    owner "root"
    group "root"
    source "default.elilo.erb"
    variables(:append_line => "#{append}",
              :install_name => os,
              :initrd => "../#{os}/install/#{initrd}",
              :kernel => "../#{os}/install/#{kernel}")
  end

  # If this is our default, create the appropriate symlink.
  if os == default_os
    link "#{pxecfg_dir}/os_install" do
      link_type :symbolic
      to "#{role}"
    end

    link "#{uefi_dir}/os_install.uefi" do
      link_type :symbolic
      to "#{role}.uefi"
    end
  end
end

package "syslinux"

bash "Install pxelinux.0" do
  libdir = node[:platform] == "suse" ? "share" : "lib"
  code "cp /usr/#{libdir}/syslinux/pxelinux.0 #{discover_dir}"
  not_if do ::File.exists?("#{discover_dir}/pxelinux.0") end
end

bash "Fetch elilo 3.14" do
  code <<EOC
http_proxy=http://#{admin_ip}:8123
cd #{tftproot}/files
curl -LO 'http://sourceforge.net/projects/elilo/files/elilo/elilo-3.14/elilo-3.14-all.tar.gz'
EOC
  not_if "test -f '#{tftproot}/files/elilo-3.14-all.tar.gz'"
end if node[:provisioner][:online]


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


# Save this node config.
node.save
