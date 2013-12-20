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

  def on_node_create(node)
    Rails.logger.info("provisioner-dhcp-database: Updating for added node #{node.name}")
    rerun_my_noderoles node
  end

  def on_node_change(node)
    Rails.logger.info("provisioner-dhcp-database: Updating for changed node #{node.name}")
    rerun_my_noderoles node
  end

  def on_node_delete(node)
    Rails.logger.info("provisioner-dhcp-database: Updating for deleted node #{node.name}")
    rerun_my_noderoles node
  end

  def rerun_my_noderoles node

    clients = {}
    mac_hint = ::Attrib.find_key "hint-admin-mac"


    Role.transaction do
      Node.all.each do |node|
        ints = (node.discovery["ohai"]["network"]["interfaces"] rescue nil)
        mac_list = []
        # get the suggested mac (requies an ip address also!
        preseed = mac_hint.get(node, :hint) if mac_hint
        mac_list << preseed if preseed 

        # scan interfaces to capture all the mac addresses discovered
        unless ints.nil?
          ints.each do |net, net_data|
            net_data.each do |field, field_data|
              next if field != "addresses"
              field_data.each do |addr, addr_data|
                next if addr_data["family"] != "lladdr"
                mac_list << addr unless mac_list.include? addr
              end
            end
          end
        end
        # we need to have at least 1 mac (from preload or inets)
        next unless mac_list.length > 0
        # add this node to the DHCP clients list
        clients[node.name] = {
          "mac_addresses" => mac_list.sort,
          "v4addr" => node.addresses.reject{|a|a.v6?}.sort.first.to_s,
          "bootenv" => node.bootenv
        }
      end
    end
    # this gets the client list sent to the jig implementing the DHCP database role
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
