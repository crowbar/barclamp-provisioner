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

if not nodes.nil? and not nodes.empty?
  nodes.map{|n|Node.load(n.name)}.each do |mnode|
    Chef::Log.info("Testing if #{mnode[:fqdn]} needs a state transition")
    if mnode[:state].nil?
      Chef::Log.info("#{mnode[:fqdn]} has no current state!")
      next
    end
    new_group = states[mnode[:state]]

    if new_group.nil? || new_group == "noop"
      Chef::Log.info("#{mnode[:fqdn]}: #{mnode[:state]} does not map to a DHCP state.")
      next
    end
    Chef::Log.info("#{mnode[:fqdn]} transitioning to group #{new_group}")

    # Delete the node
    system("knife node delete -y #{mnode.name} -u chef-webui -k /etc/chef/webui.pem") if new_group == "delete"
    system("knife role delete -y crowbar-#{mnode.name.gsub(".","_")} -u chef-webui -k /etc/chef/webui.pem") if new_group == "delete"
    if new_group == "os_install"
      target_os = mnode[:crowbar][:os] || node[:provisioner][:default_os]
      if node[:provisioner][:supported_oses][target_os]
        new_group = "#{target_os}_install"
      else
        raise ArgumentError.new("#{mnode.name} wants to install #{target_os}, but #{node.name} doesn't know how to do that!")
      end
    end

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
      count = count+1
      if new_group == "reset" or new_group == "delete"
        link "#{pxecfg_dir}/01-#{mac.gsub(':','-').downcase}" do
          action :delete
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

        link "#{pxecfg_dir}/01-#{mac.gsub(':','-').downcase}" do
          to "#{new_group}"
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
