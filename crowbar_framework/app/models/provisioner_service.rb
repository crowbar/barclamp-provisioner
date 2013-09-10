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

class ProvisionerService < ServiceObject

  def initialize(thelogger)
    @bc_name = "provisioner"
    @logger = thelogger
  end

  def create_proposal
    @logger.debug("Provisioner create_proposal: entering")
    base = super
    @logger.debug("Provisioner create_proposal: exiting")
    base
  end

  def transition(inst, name, state)
    @logger.debug("Provisioner transition: entering for #{name} for #{state}")

    role = RoleObject.find_role_by_name "provisioner-config-#{inst}"

    #
    # If the node is discovered, add the provisioner base to the node
    #
    if state == "discovered"
      @logger.debug("Provisioner transition: discovered state for #{name} for #{state}")
      db = ProposalObject.find_proposal "provisioner", inst

      #
      # Add the first node as the provisioner server
      #
      if role.override_attributes["provisioner"]["elements"]["provisioner-server"].nil?
        @logger.debug("Provisioner transition: if we have no provisioner add one: #{name} for #{state}")
        add_role_to_instance_and_node("provisioner", inst, name, db, role, "provisioner-server")

        # Reload the roles
        db = ProposalObject.find_proposal "provisioner", inst
        role = RoleObject.find_role_by_name "provisioner-config-#{inst}"
      end

      @logger.debug("Provisioner transition: Make sure that base is on everything: #{name} for #{state}")
      result = add_role_to_instance_and_node("provisioner", inst, name, db, role, "provisioner-base")

      if !result
        @logger.error("Provisioner transition: existing discovered state for #{name} for #{state}: Failed")
        return [400, "Failed to add role to node"]
      end

      if HAVE_CHEF_WEBUI
        # Set up the client url
        role = RoleObject.find_role_by_name "provisioner-config-#{inst}"

        # Get the server IP address
        server_ip = nil
        [ "provisioner-server" ].each do |element|
          tnodes = role.override_attributes["provisioner"]["elements"][element]
          next if tnodes.nil? or tnodes.empty?
          tnodes.each do |n|
            next if n.nil?
            node = NodeObject.find_node_by_name(n)
            pub = node.get_network_by_type("public")
            if pub and pub["address"] and pub["address"] != ""
              server_ip = pub["address"]
            else
              server_ip = node.get_network_by_type("admin")["address"]
            end
          end
        end

        unless server_ip.nil?
          node = NodeObject.find_node_by_name(name)
          node.crowbar["crowbar"] = {} if node.crowbar["crowbar"].nil?
          node.crowbar["crowbar"]["links"] = {} if node.crowbar["crowbar"]["links"].nil?
          node.crowbar["crowbar"]["links"]["Chef"] = "http://#{server_ip}:4040/nodes/#{node.name}"
          node.save
        end
      end
    end
    if state == "hardware-installing"
      role = RoleObject.find_role_by_name "provisioner-config-#{inst}"
      db = ProposalObject.find_proposal "provisioner", inst
      add_role_to_instance_and_node("provisioner",inst,name,db,role,"provisioner-bootdisk-finder")
    end
    # Remove roles not supported by the target operating system
    if state == "installing"
      node = NodeObject.find_node_by_name(name)
      @logger.debug("Node #{name} Removing roles not supported by the target operating system")
      crowbar_role = RoleObject.find_role_by_name("crowbar-#{name.gsub(".","_")}")
      @logger.debug("Node #{name} Main role: crowbar-#{name.gsub(".","_")}")
      crowbar_role.run_list.each do |node_role_ext|
        node_role=node_role_ext.to_s[node_role_ext.to_s.index('[')+1,node_role_ext.to_s.index(']')-node_role_ext.to_s.index('[')-1]
        if node_role.include? "-"
          node_barclamp = node_role[0,node_role.index('-')]
        else
          node_barclamp = node_role
        end
        bc_databag = ProposalObject.find_data_bag_item("barclamps/#{node_barclamp}")
        target_platform = node[:target_platform].to_s
        if !bc_databag.nil?
          if !bc_databag["unsupported_platform"].nil?
            barclamp_unsupported_platform=bc_databag["unsupported_platform"].to_s
            node_platform = if target_platform.include?('-')
                              target_platform[0,target_platform.index('-')]
                            else
                              target_platform
                            end
            if barclamp_unsupported_platform.include?(node_platform)
              node.delete_from_run_list(node_role)
              @logger.debug("Node #{name}: barclamp #{node_barclamp} not supported on #{node[:target_platform]}")
            else
              @logger.debug("Node #{name}: barclamp #{node_barclamp} supported on #{node[:target_platform]}")
            end
          end
        end
      end
    end

    if state == "reset"
      node = NodeObject.find_node_by_name(name)
      # clean up state capturing attributes on the node that are not likely to be the same
      # after a reset.
      ["boot_device"].each { |key |
        node["crowbar_wall"][key] = nil if (node["crowbar_wall"][key] rescue nil)
      }
      node.save
    end

    if state == "delete"
      # BA LOCK NOT NEEDED HERE.  NODE IS DELETING
      node = NodeObject.find_node_by_name(name)
      node.crowbar["state"] = "delete-final"
      node.save
    end

    #
    # test state machine and call chef-client if state changes
    #
    node = NodeObject.find_node_by_name(name)
    if ! node
      @logger.error("Provisioner transition: leaving #{name} for #{state}: Node not found")
      return [404, "Failed to find node"]
    end
    unless node.admin? or role.default_attributes["provisioner"]["dhcp"]["state_machine"][state].nil?
      # All non-admin nodes call single_chef_client if the state machine says to.
      @logger.info("Provisioner transition: Run the chef-client locally")
      system("sudo -i /opt/dell/bin/single_chef_client.sh")
    end
    @logger.debug("Provisioner transition: exiting for #{name} for #{state}")
    [200, node.to_hash ]
  end

end

