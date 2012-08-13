# Copyright 2012, Dell 
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

  def transition(inst, name, state)
    @logger.debug("Provisioner transition: entering for #{name} for #{state}")

    prop = @barclamp.get_proposal(inst)
    prop_config = prop.active_config

    #
    # If the node is discovered, add the provisioner base to the node
    #
    if state == "discovered"
      @logger.debug("Provisioner transition: discovered state for #{name} for #{state}")

      #
      # Add the first node as the provisioner server
      #
      nodes = prop_config.get_nodes_by_role("provisioner-server")
      if nodes.empty?
        @logger.debug("Provisioner transition: if we have no provisioner add one: #{name} for #{state}")
        add_role_to_instance_and_node(name, inst, "provisioner-server")
        nodes = [ Node.find_by_name(name) ]
      end

      @logger.debug("Provisioner transition: Make sure that base is on everything: #{name} for #{state}")
      result = add_role_to_instance_and_node(name, inst, "provisioner-base")

      if !result
        @logger.error("Provisioner transition: existing discovered state for #{name} for #{state}: Failed")
        return [400, "Failed to add role to node"]
      else
        # Get the server IP address
        server_ip = nodes[0].address("public").addr rescue nodes[0].address.addr

        unless server_ip.nil?
          node = Node.find_node_by_name(name)
          chash = prop_config.get_node_config_hash(node)
          chash["crowbar"] = {} if chash["crowbar"].nil?
          chash["crowbar"]["links"] = {} if chash["crowbar"]["links"].nil?
          chash["crowbar"]["links"]["Chef"] = "http://#{server_ip}:4040/nodes/#{node.name}"
          prop_config.set_node_config_hash(node, chash)
        end
      end
    end

    if state == "delete"
      # BA LOCK NOT NEEDED HERE.  NODE IS DELETING
      node = Node.find_by_name(name)
      node.set_state("delete-final")
      node.save
    end

    #
    # test state machine and call chef-client if state changes
    #
    node = NodeObject.find_by_name(name)
    if ! node
      @logger.error("Provisioner transition: leaving #{name} for #{state}: Node not found")
      return [404, "Failed to find node"]
    end
    unless node.is_admin? or prop_config.config_hash["dhcp"]["state_machine"][state].nil? 
      # All non-admin nodes call single_chef_client if the state machine says to.
      @logger.info("Provisioner transition: Run the chef-client locally")
      system("sudo -i /opt/dell/bin/single_chef_client.sh")
    end
    @logger.debug("Provisioner transition: exiting for #{name} for #{state}")
    [200, ""]
  end

end

