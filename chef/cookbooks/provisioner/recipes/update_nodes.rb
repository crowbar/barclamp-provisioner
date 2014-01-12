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

domain_name = node["crowbar"]["dns"]["domain"]
web_port = node["crowbar"]["provisioner"]["server"]["web_port"]
use_local_security = node["crowbar"]["provisioner"]["server"]["use_local_security"]
provisioner_web=node["crowbar"]["provisioner"]["server"]["webserver"]
provisioner_addr = node["crowbar"]["provisioner"]["server"]["v4addr"]
provisioner_port = node["crowbar"]["provisioner"]["server"]["web_port"] 
proxy=node["crowbar"]["provisioner"]["server"]["proxy"]
os_token="#{node[:platform]}-#{node[:platform_version]}"
tftproot = node["crowbar"]["provisioner"]["server"]["root"]
discover_dir="#{tftproot}/discovery"
node_dir="#{tftproot}/nodes"
pxecfg_dir="#{discover_dir}/pxelinux.cfg"
uefi_dir=discover_dir
pxecfg_default="#{pxecfg_dir}/default"
node.normal["crowbar_wall"] ||= Mash.new
node.normal["crowbar_wall"]["dhcp"] ||= Mash.new
node.normal["crowbar_wall"]["dhcp"]["clients"] ||= Mash.new
new_clients = {}

(node["crowbar"]["dhcp"]["clients"] || {} rescue {}).each do |mnode_name,dhcp_info|
  # Build DHCP, PXE, and ELILO config files for each system
  v4addr = IP.coerce(dhcp_info["v4addr"])
  nodeaddr = sprintf("%X",v4addr.address)
  bootenv = dhcp_info["bootenv"]
  mac_list = dhcp_info["mac_addresses"]
  pxefile = "#{pxecfg_dir}/#{nodeaddr}"
  uefifile = "#{uefi_dir}/#{nodeaddr}.conf"
  new_clients[mnode_name] = {
    "v4addr" => dhcp_info["v4addr"],
    "nodeaddr" => nodeaddr,
    "mac_addresses" => mac_list,
    "pxefile" => pxefile,
    "uefifile" => uefifile
  }
  Chef::Log.info("DHCP: #{mnode_name} Updating PXE and UEFI boot for bootenv #{bootenv}")
  # Default to creating appropriate boot config files for Sledgehammer.
  case
  when bootenv == "sledgehammer"
    pxe_params = node["crowbar"]["provisioner"]["server"]["sledgehammer_kernel_params"].split(' ')
    pxe_params << "crowbar.fqdn=#{mnode_name}"
    provisioner_bootfile mnode_name do
      kernel_params pxe_params.join(" ")
      address v4addr
      bootenv "sledgehammer"
      action :add
    end
    # Generate an appropriate control.sh for the system.
    directory "#{node_dir}/#{mnode_name}" do
      action :create
      recursive true
    end
    template "#{node_dir}/#{mnode_name}/control.sh" do
      source "control.sh.erb"
      mode "0755"
      variables(:provisioner_name => node.name,
                :online => node["crowbar"]["provisioner"]["server"]["online"],
                :provisioner_web => provisioner_web,
                :proxy => node["crowbar"]["provisioner"]["server"]["proxy"],
                :keys => (node["crowbar"]["provisioner"]["server"]["access_keys"] rescue Hash.new).values.sort.join($/),
                :v4_addr => node.address("admin",IP::IP4).addr
                )
    end
  when bootenv == "local"
    provisioner_bootfile mnode_name do
      bootenv "sledgehammer"
      address v4addr
      action :remove
    end
  when bootenv == "ubuntu-12.04-install"
    provisioner_ubuntu mnode_name do
      version "12.04"
      address v4addr
      target mnode_name
      action :add
    end
  else
    Chef::Log.info("Not messing with boot files for bootenv #{bootenv}")
  end
  # Create pxe and uefi netboot files.
  # We always need our FQDN.
  mac_list.each_index do |idx|
    if bootenv == "local"
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
                   "next-server #{provisioner_addr}"]
    end
    dhcp_host "#{mnode_name}-#{idx}" do
      hostname mnode_name
      ipaddress v4addr.addr
      macaddress mac_list[idx]
      options dhcp_opts
      action :add
    end
  end
end

# Now that we have handled any updates we care about, delete any info about nodes we have deleted.
(node["crowbar_wall"]["dhcp"]["clients"].keys - new_clients.keys).each do |old_node_name|
  old_node = node["crowbar_wall"]["dhcp"]["clients"][old_node_name]
  mac_list = old_node["mac_addresses"]
  mac_list.each_index do |idx|
    a = dhcp_host "#{old_node_name}-#{idx}" do
      hostname old_node_name
      ipaddress "0.0.0.0"
      macaddress mac_list[idx]
      action :nothing
    end
    a.run_action(:remove)
  end
  a = provisioner_bootfile old_node["bootenv"] do
    action :nothing
    address IP.coerce(old_node["v4addr"])
  end
  a.run_action(:remove)
end
node.normal["crowbar_wall"]["dhcp"]["clients"]=new_clients

return

# OS install special-casing.
# This really needs to be outsourced to its own roles or providers or something.
case
when bootenv =~ /.*_install$/
  os = bootenv.split('_')[0]
  web_path = "#{provisioner_web}/#{os}"
  admin_web="#{web_path}/install"
  crowbar_repo_web="#{web_path}/crowbar-extra"
  os_dir="#{tftproot}/#{os}" /

  # I need to think about this.
  #if (mnode[:crowbar_wall][:uefi][:boot]["LastNetBootMac"] rescue nil)
  #  append_line << " BOOTIF=01-#{mnode[:crowbar_wall][:uefi][:boot]["LastNetBootMac"].gsub(':','-')}"
  #end
  # These should really be made libraries or something.
  case
  when /^(suse)/ =~ os
    template "#{os_dir}/#{mnode_name}.xml" do
      mode 0644
      source "autoyast.xml.erb"
      owner "root"
      group "root"
      variables(:admin_node_ip => provisioner_addr,
                :name => mnode_name,
                :web_port => web_port,
                :repos => node["crowbar"]["provisioner"]["server"]["repositories"][os],
                :admin_web => admin_web,
                :crowbar_join => "#{web_path}/crowbar_join.sh")
    end
    template "#{os_dir}/crowbar_join.sh" do
      mode 0644
      owner "root"
      group "root"
      source "crowbar_join.suse.sh.erb"
      variables(:admin_ip => provisioner_addr)
    end
    append_line = "autoyast=#{web_path}/#{mnode_name}.xml"
  when /^(redhat|centos)/ =~ os
    # Default kickstarts and crowbar_join scripts for redhat.
    template "#{os_dir}/#{mnode_name}.ks" do
      mode 0644
      source "compute.ks.erb"
      owner "root"
      group "root"
      variables(:admin_node_ip => provisioner_addr,
                :web_port => web_port,
                :name => mnode_name,
                :online => node["crowbar"]["provisioner"]["server"]["online"],
                :proxy => "http://#{proxy}/",
                :provisioner_web => provisioner_web,
                :repos => node["crowbar"]["provisioner"]["server"]["repositories"][os],
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
                :admin_ip => provisioner_addr,
                :provisioner_web => provisioner_web,
                :web_path => web_path)
    end
    append_line = "ks=#{web_path}/#{mnode_name}.ks ksdevice=bootif"
  end
  # Create the pxe linux config for this OS.
  append_line = "#{params[:kernel_params]} #{append_line}"
  initrd = params[:initrd]
  kernel = params[:kernel]
end
