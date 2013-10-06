# Copyright 2013, Dell
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

class BarclampProvisioner::DhcpDatabase < Role

  def on_node_change(node)
    ints = (node.discovery["ohai"]["network"]["interfaces"] rescue nil)
    return unless ints
    mac_list = []
    ints.each do |net, net_data|
      net_data.each do |field, field_data|
        next if field != "addresses" 
        field_data.each do |addr, addr_data|
          next if addr_data["family"] != "lladdr"
          mac_list << addr unless mac_list.include? addr
        end
      end
    end
    client = {
      "mac_addresses" => mac_list.sort,
      "v4addr" => node.addresses.reject{|a|a.v6?}.sort.first.to_s,
      "bootenv" => node.bootenv
    }
    node_roles.each do |nr|
      need_poke = false
      nr_client = (nr.sysdata["crowbar"]["dhcp"]["clients"][node.name] || {} rescue {})
      next if nr_client == client
      new_sysdata = {
        "crowbar" =>{
          "dhcp" => {
            "clients" => {
              node.name => client
            }
          }
        }
      }
      nr.sysdata = nr.sysdata.deep_merge(new_sysdata)
      Rails.logger.info("DHCP database: enqueing #{nr.name} for #{node.name}")
      Run.enqueue(nr) if nr.active? || nr.transition?
    end
  end

  def on_node_delete(node)
    node_roles.each do |nr|
      clients = (nr.sysdata["crowbar"]["dhcp"]["clients"] || {} rescue {} )
      next unless clients.key?(node.name)
      clients.delete(node.name)
      nr.sysdata = {
        "crowbar" =>{
          "dhcp" => {
            "clients" => clients
          }
        }
      }
      Rails.logger.info("DHCP database: enqueing #{nr.name} because #{node.name} is being deleted.")
      Run.enqueue(nr) if nr.active? || nr.transition?
    end
  end
end
