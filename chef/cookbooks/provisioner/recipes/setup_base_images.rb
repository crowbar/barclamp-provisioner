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

unless node[:provisioner][:sledgehammer_kernel_params]
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
  
  node[:provisioner][:sledgehammer_kernel_params] = append_line
else
  append_line = node[:provisioner][:sledgehammer_kernel_params]
end

# Generate the appropriate pxe and uefi config files for discovery
# These will only be used if we have not already discovered the system.
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

# Do uefi as well.
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

node[:apache][:listen_ports] = [ web_port, 8123 ]
include_recipe "apache2"
include_recipe "apache2::mod_proxy"
include_recipe "apache2::mod_proxy_http"
apache_module "cache"
apache_module "disk_cache"

template "#{node[:apache][:dir]}/sites-available/provisioner.conf" do
  path "#{node[:apache][:dir]}/vhosts.d/provisioner.conf" if node[:platform] == "suse"
  source "base-apache.conf.erb"
  mode 0644
  variables(:docroot => "#{tftproot}",
            :port => web_port,
            :logfile => "/var/log/apache2/provisioner-access_log",
            :errorlog => "/var/log/apache2/provisioner-error_log")
  notifies :reload, resources(:service => "apache2")
end
template "#{node[:apache][:dir]}/sites-available/proxy.conf" do
  path "#{node[:apache][:dir]}/vhosts.d/proxy.conf" if node[:platform] == "suse"
  source "proxy-apache.conf.erb"
  mode 0644
  variables(:port => 8123,
            :logfile => "/var/log/apache2/proxy-access_log",
            :errorlog => "/var/log/apache2/proxy-error_log",
            :allowed_clients => ["127.0.0.1"] + node.all_addresses.map{|a|a.network.to_s}.sort,
            :upstream_proxy => (node[:provisioner][:upstream_proxy] || "" rescue ""),
            :no_cache => "http://#{admin_ip}"
            )
  notifies :reload, resources(:service => "apache2")
end
apache_site "provisioner.conf"
apache_site "proxy.conf"

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
    enabled true
    if node[:platform_version].to_f >= 12.3
      provider Chef::Provider::Service::Systemd
      service_name "tftp.socket"
      action [ :enable, :start ]
    else
      # on older releases just enable, don't start (xinetd takes care of it)
      action [ :enable ]
    end
  end
  service "xinetd" do
    running true
    enabled true
    action [ :enable, :start ]
  end unless node[:platform_version].to_f >= 12.3
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
node[:provisioner][:available_oses] = Mash.new
node[:provisioner][:supported_oses].each do |os,params|

  web_path = "#{provisioner_web}/#{os}"
  admin_web = os_install_site = "#{web_path}/install"
  crowbar_repo_web="#{web_path}/crowbar-extra"
  os_dir="#{tftproot}/#{os}"
  os_codename=node[:lsb][:codename]
  role="#{os}_install"
  initrd = params["initrd"]
  kernel = params["kernel"]

  # Don't bother for OSes that are not actaully present on the provisioner node.
  next unless (File.directory? os_dir and File.directory? "#{os_dir}/install") or
    (node[:provisioner][:online] and params[:online_mirror])
  node[:provisioner][:available_oses][os] = true

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

    if params[:online_mirror]
      directory "#{os_dir}/install/#{initrd.split('/')[0...-1].join('/')}" do
        recursive true
      end
      case
      when os =~ /^(ubuntu|debian)/
        raise ArgumentError.new("Cannot configure provisioner for online deploy of #{os}: missing codename") unless params[:codename]
        netboot_urls = {
          initrd => "#{params[:online_mirror]}/dists/#{params[:codename]}/main/installer-amd64/current/images/#{initrd.split('/')[1..-1].join('/')}",
          kernel => "#{params[:online_mirror]}/dists/#{params[:codename]}/main/installer-amd64/current/images/#{kernel.split('/')[1..-1].join('/')}"
        }
        os_install_site = params[:online_mirror]
      when os =~/^(centos|redhat)/
        netboot_urls = {
          initrd => "#{params[:online_mirror]}/os/x86_64/#{initrd}",
          kernel => "#{params[:online_mirror]}/os/x86_64/#{kernel}"
        }
        os_install_site = "#{params[:online_mirror]}/os/x86_64"
      else
        raise ArgumentError.new("Cannot configure provisioner for online deploy of #{os}: missing codepaths.")
      end
      netboot_urls.each do |k,v|
        bash "#{os}: fetch #{k}" do
          code <<EOC
set -x
export http_proxy=http://127.0.0.1:8123/
curl -sfL -o '#{os_dir}/install/#{k}.new' '#{v}' && \
mv '#{os_dir}/install/#{k}.new' '#{os_dir}/install/#{k}'
EOC
          not_if "test -f '#{os_dir}/install/#{k}'"
        end
      end
    end
  end

  replaces={
    '%os_site%'         => web_path,
    '%os_install_site%' => os_install_site
  }
  append = params["append"]

  # Sigh.  There has to be a more elegant way.
  replaces.each { |k,v|
    append.gsub!(k,v)
  }

  # If we were asked to use a serial console, arrange for it.
  if node[:provisioner][:use_serial_console]
    append << " console=tty0 console=ttyS1,115200n8"
  end

  # Make sure we get a crowbar install key as well.
  if ::File.exists?("/etc/crowbar.install.key")
    append << " crowbar.install.key=#{::File.read("/etc/crowbar.install.key").chomp.strip}"
  end

  # If we were asked to use a serial console, arrange for it.
  if node[:provisioner][:use_serial_console]
    append << " console=tty0 console=ttyS1,115200n8"
  end
  # Add per-OS base repos that may not have been added above.

  node[:provisioner][:boot_specs] ||= Mash.new
  node[:provisioner][:boot_specs][os] ||= Mash.new
  node[:provisioner][:boot_specs][os][:kernel] = "../#{os}/install/#{kernel}"
  node[:provisioner][:boot_specs][os][:initrd] = "../#{os}/install/#{initrd}"
  node[:provisioner][:boot_specs][os][:os_install_site] = os_install_site
  node[:provisioner][:boot_specs][os][:kernel_params] = append

  case
  when (/^ubuntu/ =~ os and File.exists?("/tftpboot/#{os}/install/dists"))
    node[:provisioner][:repositories][os]["base"] = { "http://#{admin_ip}:#{web_port}/#{os}/install" => true }
  when /^(suse)/ =~ os
    node[:provisioner][:repositories][os]["base"] = { "baseurl=http://#{admin_ip}:#{web_port}/#{os}/install" => true }
  when /^(redhat|centos)/ =~ os
    # Add base OS install repo for redhat/centos
    if ::File.exists? "/tftpboot/#{os}/install/repodata"
      node[:provisioner][:repositories][os]["base"] = { "baseurl=http://#{admin_ip}:#{web_port}/#{os}/install" => true }
    elsif ::File.exists? "/tftpboot/#{os}/install/Server/repodata"
      node[:provisioner][:repositories][os]["base"] = { "baseurl=http://#{admin_ip}:#{web_port}/#{os}/install/Server" => true }
    end
  end
end

package "syslinux"

["share","lib"].each do |d|
  next unless ::File.exists?("/usr/#{d}/syslinux/pxelinux.0")
  bash "Install pxelinux.0" do
    code "cp /usr/#{d}/syslinux/pxelinux.0 #{discover_dir}"
    not_if do ::File.exists?("#{discover_dir}/pxelinux.0") end
  end
  break
end

bash "Fetch elilo 3.14" do
  code <<EOC
export http_proxy=http://#{admin_ip}:8123
mkdir -p #{tftproot}/files
cd #{tftproot}/files
curl -J -O 'http://sourceforge.net/projects/elilo/files/elilo/elilo-3.14/elilo-3.14-all.tar.gz'
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


# Generate an appropriate control.sh for the system.
template "/updates/control.sh" do
  source "control.sh.erb"
  mode "0755"
  variables(
            :provisioner_ip => admin_ip,
            :online => node[:provisioner][:online],
            :provisioner_web => provisioner_web,
            :proxy => "http://#{admin_ip}:8123"
            )
end


# Save this node config.
node.save
