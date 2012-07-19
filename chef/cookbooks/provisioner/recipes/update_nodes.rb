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
append_line = ''
os_token="#{node[:platform]}-#{node[:platform_version]}"
tftproot = node[:provisioner][:root]
discover_dir="#{tftproot}/discovery"
pxecfg_dir="#{discover_dir}/pxelinux.cfg"
uefi_dir=discover_dir
pxecfg_default="#{pxecfg_dir}/default"
nodes = search(:node, "crowbar_usedhcp:true")

if not nodes.nil? and not nodes.empty?
  nodes.map{|n|Node.load(n.name)}.each do |mnode|
    Chef::Log.info("Testing if #{mnode[:fqdn]} needs a state transition")
    if mnode[:state].nil?
      Chef::Log.info("#{mnode[:fqdn]} has no current state!")
      next
    end
    new_group = mnode[:provisioner_state]

    if new_group.nil? || new_group == "noop"
      Chef::Log.info("#{mnode[:fqdn]}: #{mnode[:state]} does not map to a DHCP state.")
      next
    end
    Chef::Log.info("#{mnode[:fqdn]} transitioning to group #{new_group}")

    # Delete the node
    system("knife node delete -y #{mnode.name} -u chef-webui -k /etc/chef/webui.pem") if new_group == "delete"
    system("knife role delete -y crowbar-#{mnode.name.gsub(".","_")} -u chef-webui -k /etc/chef/webui.pem") if new_group == "delete"

    mac_list = []
    mnode["network"]["interfaces"].each do |net, net_data|
      net_data.each do |field, field_data|
        next if field != "addresses" 
        field_data.each do |addr, addr_data|
          next if addr_data["family"] != "lladdr"
          mac_list << addr unless mac_list.include? addr
        end
      end
    end

    # Build entries for each mac address.
    count = 0
    mac_list.each do |mac|
      pxelink = "#{pxecfg_dir}/01-#{mac.gsub(':','-').downcase}"
      uefilink = "#{uefi_dir}/#{sprintf("%X",mnode.address("admin",IP::IP4).address)}.conf"
      count = count+1
      if new_group == "reset" or new_group == "delete"
        [ pxelink,uefilink ].each do |l|
          link l do
            action :delete
          end
        end
        dhcp_host "#{mnode.name}-#{count}" do
          hostname mnode.name
          ipaddress "0.0.0.0"
          macaddress mac
          action :remove
        end
      else
        # Skip if we don't have admin
        next if mnode.address("admin",IP::IP4).nil?
        link pxelink do
          to "#{new_group}"
        end
        link uefilink do
          to "#{new_group}.uefi"
        end
        dhcp_host "#{mnode.name}-#{count}" do
          hostname mnode.name
          ipaddress mnode.address("admin",IP::IP4).addr
          macaddress mac
          action :add
        end
      end
    end
  end
end
