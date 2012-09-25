# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

admin_ip = node.address.addr
domain_name = node[:dns].nil? ? node[:domain] : (node[:dns][:domain] || node[:domain])
web_port = node[:provisioner][:web_port]
use_local_security = node[:provisioner][:use_local_security]
provisioner_web="http://#{admin_ip}:#{web_port}"
os_token="#{node[:platform]}-#{node[:platform_version]}"
tftproot = node[:provisioner][:root]
discover_dir="#{tftproot}/discovery"
pxecfg_dir="#{discover_dir}/pxelinux.cfg"
uefi_dir=discover_dir
pxecfg_default="#{pxecfg_dir}/default"
nodes = search(:node, "*:*")
Chef::Log.info("Node ount = #{nodes.length}")
admin_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
if not nodes.nil? and not nodes.empty?
  nodes.map{|n|Node.load(n.name)}.each do |mnode|
    Chef::Log.info("Testing if #{mnode[:fqdn]} needs a state transition")
    if mnode[:state].nil?
      Chef::Log.info("#{mnode[:fqdn]} has no current state!")
      next
    end
    new_group = mnode[:provisioner_state]

    if new_group.nil?
      Chef::Log.info("#{mnode[:fqdn]}: #{mnode[:state]} does not map to a DHCP state.")
      next
    end
    Chef::Log.info("#{mnode[:fqdn]} transitioning to group #{new_group}")

    mac_list = []
    mnode["network"]["interfaces"].each do |net, net_data|
      net_data.each do |field, field_data|
        next if field != "addresses" 
        field_data.each do |addr, addr_data|
          next if addr_data["family"] != "lladdr"
          Chef::Log.info("#{mnode.name}: #{net}: #{addr}")
          mac_list << addr unless mac_list.include? addr
        end
      end
    end
    mac_list.sort!
    # Build DHCP, PXE, and ELILO config files for each system
    nodeaddr = sprintf("%X",mnode.address("admin",IP::IP4).address)
    pxefile = "#{pxecfg_dir}/#{nodeaddr}"
    uefifile = "#{uefi_dir}/#{nodeaddr}.conf"
    if new_group == "reset" or new_group == "delete"
      Chef::Log.info("Deleting config for #{mnode.name}")
      # Kill DHCP config and netboot configs for this system.
      mac_list.each_index do |idx|
        Chef::Log.info("Deleting DHCP config for #{mnode.name}-#{idx}")
        dhcp_host "#{mnode.name}-#{idx}" do
          hostname mnode.name
          ipaddress "0.0.0.0"
          macaddress mac_list[idx]
          action :remove
        end
      end
      [ pxefile,uefifile ].each do |f|
        Chef::Log.info("Deleting netboot info for #{mnode.name}: #{f}")
        file f do
          action :delete
        end
      end
    elsif mnode.address("admin",IP::IP4)
      # Make our DHCP config for this system.
      mac_list.each_index do |idx|
        if new_group == "execute"
          dhcp_opts = []
        else
          dhcp_opts = [
                     '  if option arch = 00:06 {
      filename = "discovery/bootia32.efi";
   } else if option arch = 00:07 {
      filename = "discovery/bootx64.efi";
   } else {
      filename = "discovery/pxelinux.0";
   }',
                     "next-server #{admin_ip}"]
        end
        dhcp_host "#{mnode.name}-#{idx}" do
          hostname mnode.name
          ipaddress mnode.address.addr
          macaddress mac_list[idx]
          options dhcp_opts
          action :add
        end
      end
      case
      when ["discovery","update","hwinstall","debug"].member?(new_group)
        append_line = node[:provisioner][:sledgehammer_kernel_params]
        # Generate the appropriate pxe config file for discovery and execute.
        template pxefile do
          mode 0644
          owner "root"
          group "root"
          source "default.erb"
          variables(:append_line => "#{append_line} crowbar.state=#{new_group}",
                    :install_name => new_group,
                    :initrd => "initrd0.img",
                    :kernel => "vmlinuz0")
        end
        template uefifile do
          mode 0644
          owner "root"
          group "root"
          source "default.elilo.erb"
          variables(:append_line => "#{append_line} crowbar.state=#{new_group}",
                    :install_name => new_group,
                    :initrd => "initrd0.img",
                    :kernel => "vmlinuz0")
        end
      when new_group =~ /.*_install$/
        os = new_group.split('_')[0]
        web_path = "#{provisioner_web}/#{os}"
        admin_web="#{web_path}/install"
        crowbar_repo_web="#{web_path}/crowbar-extra"
        os_dir="#{tftproot}/#{os}"
        os_codename=node[:lsb][:codename]
        params = node[:provisioner][:boot_specs][os]
        append_line = ""
        if (mnode[:crowbar_wall][:uefi][:boot]["LastNetBootMac"] rescue nil)
          append_line = "BOOTIF=01-#{mnode[:crowbar_wall][:uefi][:boot]["LastNetBootMac"].gsub(':','-')}"
        end
        # These should really be made libraries or something.
        case
        when /^(suse)/ =~ os
          template "#{os_dir}/#{mnode.name}.xml" do
            mode 0644
            source "autoyast.xml.erb"
            owner "root"
            group "root"
            variables(:admin_node_ip => admin_ip,
                      :name => mnode.name,
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
          append_line << " autoyast=#{web_path}/#{mnode.name}.xml"
        when /^(redhat|centos)/ =~ os
          # Default kickstarts and crowbar_join scripts for redhat.
          template "#{os_dir}/#{mnode.name}.ks" do
            mode 0644
            source "compute.ks.erb"
            owner "root"
            group "root"
            variables(:admin_node_ip => admin_ip,
                      :web_port => web_port,
                      :name => mnode.name,
                      :online => node[:provisioner][:online],
                      :proxy => "http://#{node.address.addr}:8123/",
                      :provisioner_web => provisioner_web,
                      :repos => node[:provisioner][:repositories][os],
                      :admin_web => admin_web,
                      :os_install_site => params[:os_install_site],
                      :crowbar_join => "#{web_path}/crowbar_join.sh")
          end
          template "#{os_dir}/crowbar_join.sh" do
            mode 0644
            owner "root"
            group "root"
            source "crowbar_join.redhat.sh.erb"
            variables(:os_codename => os_codename,
                      :crowbar_repo_web => crowbar_repo_web,
                      :admin_ip => admin_ip,
                      :provisioner_web => provisioner_web,
                      :web_path => web_path)
          end
          append_line << " ks=#{web_path}/#{mnode.name}.ks ksdevice=bootif"
        when /^ubuntu/ =~ os
          # Default files needed for Ubuntu.
          template "#{os_dir}/#{mnode.name}.seed" do
            mode 0644
            owner "root"
            group "root"
            source "net_seed.erb"
            variables(:install_name => os,
                      :name => mnode.name,
                      :cc_use_local_security => use_local_security,
                      :os_install_site => params[:os_install_site],
                      :online => node[:provisioner][:online],
                      :provisioner_web => provisioner_web,
                      :web_path => web_path,
                      :proxy => "http://#{node.address.addr}:8123/")
          end
          template "#{os_dir}/#{mnode.name}-post-install.sh" do
            mode 0644
            owner "root"
            group "root"
            source "net-post-install.sh.erb"
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
          append_line << " url=#{web_path}/#{mnode.name}.seed netcfg/get_hostname=#{mnode.name}"
        end

        # Create the pxe linux config for this OS.
        template pxefile do
          mode 0644
          owner "root"
          group "root"
          source "default.erb"
          variables(:append_line => "#{params[:kernel_params]} #{append_line}",
                    :install_name => os,
                    :initrd => params[:initrd],
                    :kernel => params[:kernel])
      end

        template uefifile do
          mode 0644
          owner "root"
          group "root"
          source "default.elilo.erb"
          variables(:append_line => "#{params[:kernel_params]} #{append_line}",
                    :install_name => os,
                    :initrd => params[:initrd],
                    :kernel => params[:kernel])
        end
      when new_group == "execute"
        append_line = node[:provisioner][:sledgehammer_kernel_params]
        cookbook_file pxefile do
          mode 0644
          owner "root"
          group "root"
          source "localboot.default"
        end

        # If we ever netboot through UEFI for the execute state, then something went wrong.
        # Drop the node into debug state intead.
        template uefifile do
          mode 0644
          owner "root"
          group "root"
          source "default.elilo.erb"
          variables(:append_line => "#{append_line} crowbar.state=debug",
                    :install_name => "debug",
                    :initrd => "initrd0.img",
                    :kernel => "vmlinuz0")
        end
      end
    end
  end
end
