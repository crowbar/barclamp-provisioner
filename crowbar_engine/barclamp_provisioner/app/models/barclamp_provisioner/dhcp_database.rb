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
    Rails.logger.info("provisioner-dhcp-database: Updating for changed node #{node.name}")
    rerun_my_noderoles
  end

  def on_node_delete(node)
    Rails.logger.info("provisioner-dhcp-database: Updating for deleted node #{node.name}")
    rerun_my_noderoles
  end

  def rerun_my_noderoles
    clients = {}
    Role.transaction do
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
    end
    new_sysdata = {
      "crowbar" =>{
        "dhcp" => {
          "clients" => clients
        }
      }
    }
    NodeRole.transaction do
      node_roles.committed.each do |nr|
        if nr.sysdata == new_sysdata
          Rails.logger.info("DHCP database: No changes, not enqueuing #{nr.name}")
          next
        end
        nr.sysdata = new_sysdata
        nr.save!
        Rails.logger.info("DHCP database: enqueing #{nr.name}")
        Run.enqueue(nr)
      end
    end
  end

end
