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
    do_stuff
  end

  def on_node_delete(node)
    do_stuff
  end

  private

  def do_stuff()
    clients = {}
    Node.all.each do |node|
      ints = (node.discovery["ohai"]["network"]["interfaces"] rescue nil)
      next unless ints
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
      clients[node.name] = {
        "mac_addresses" => mac_list.sort,
        "v4addr" => node.addresses.reject{|a|a.v6?}.sort.first.to_s,
        "bootenv" => node.bootenv
      }
    end
    node_roles.each do |nr|
      nr_clients = (nr.sysdata["crowbar"]["dhcp"]["clients"] || {} rescue {})
      next if nr_clients == clients
      nr.sysdata = {
        "crowbar" =>{
          "dhcp" => {
            "clients" => clients
          }
        }
      }
      nr.save!
      Rails.logger.info("DHCP database: enqueing #{nr.name}")
      Run.enqueue(nr) if nr.active? || nr.transition?
    end
  end
end
