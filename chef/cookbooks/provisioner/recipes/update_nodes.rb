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

states = node["provisioner"]["dhcp"]["state_machine"]
tftproot=node["provisioner"]["root"]
pxecfg_dir="#{tftproot}/discovery/pxelinux.cfg"
nodes = search(:node, "crowbar_usedhcp:true")
admin_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
if not nodes.nil? and not nodes.empty?
  nodes.each do |thenode|
    mnode = Node.load(thenode.name) 

    Chef::Log.info("Testing if #{mnode[:fqdn]} needs a state transition")
    if mnode[:state].nil?
      Chef::Log.info("#{mnode[:fqdn]} has no current state!")
      next
    end

    new_group = nil
    newstate = states[mnode[:state]]
    new_group = newstate if !newstate.nil? && newstate != "noop"

    if new_group.nil? || new_group == "noop"
      Chef::Log.info("#{mnode[:fqdn]}: #{mnode[:state]} does not map to a DHCP state.")
      next
    end
    Chef::Log.info("#{mnode[:fqdn]} transitioning to group #{new_group}")

    if new_group == "delete"
      system("knife node delete -y #{mnode.name} -u chef-webui -k /etc/chef/webui.pem")
      system("knife role delete -y crowbar-#{mnode.name.gsub(".","_")} -u chef-webui -k /etc/chef/webui.pem")
    end

    mac_list = []
    interfaces = mnode["network"]["interfaces"]
    if ! interfaces
      log("no interfaces found for node #{mnode.name}") {level :warn}
      interfaces = []
    end

    interfaces.each do |net, net_data|
      net_data.each do |field, field_data|
        next if field != "addresses"
        field_data.each do |addr, addr_data|
          next if addr_data["family"] != "lladdr"
          mac_list << addr unless mac_list.include? addr
        end
      end
    end

    admin_data_net = Chef::Recipe::Barclamp::Inventory.get_network_by_type(mnode, "admin")

    # Build entries for each mac address.
    count = 0
    mac_list.each do |mac|
      count = count+1
      if new_group == "reset" or new_group == "delete"
        dhcp_host "#{mnode.name}-#{count}" do
          hostname mnode.name
          ipaddress "0.0.0.0"
          macaddress mac
          action :remove
        end
        link "#{pxecfg_dir}/01-#{mac.gsub(':','-').downcase}" do
          action :delete
        end
      else
        # Skip if we don't have admin
        next if admin_data_net.nil?
        if new_group == "execute"
          dhcp_host "#{mnode.name}-#{count}" do
            hostname mnode.name
            ipaddress admin_data_net.address
            macaddress mac
            action :add
          end
        else
          dhcp_host "#{mnode.name}-#{count}" do
            hostname mnode.name
            ipaddress admin_data_net.address
            macaddress mac
            options [
                     'filename "discovery/pxelinux.0"',
                     "next-server #{admin_ip}"
                    ]
            action :add
          end
        end
        link "#{pxecfg_dir}/01-#{mac.gsub(':','-').downcase}" do
          to "#{new_group}"
        end
      end
    end
  end
end
