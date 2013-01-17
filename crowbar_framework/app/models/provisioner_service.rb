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
          node = Node.find_by_name(name)
          chash = prop_config.get_node_config_hash(node)
          chash["crowbar"] = {} if chash["crowbar"].nil?
          chash["crowbar"]["links"] = {} if chash["crowbar"]["links"].nil?
          chash["crowbar"]["links"]["Chef"] = "http://#{server_ip}:4040/nodes/#{node.name}"
          prop_config.set_node_config_hash(node, chash)
        end
      end
    end

    #
    # test state machine and call chef-client if state changes
    #
    node = Node.find_by_name(name)
    if ! node
      @logger.error("Provisioner transition: leaving #{name} for #{state}: Node not found")
      return [404, "Failed to find node"]
    end
    return [200,"admin does not transition provisioner state"] if node.admin?
    node_hash = prop_config.get_node_config_hash(node)
    node_hash["crowbar"] = {} if node_hash["crowbar"].nil?
    cstate = node_hash["provisioner_state"]
    nstate = prop_config.config_hash["provisioner"]["dhcp"]["state_machine"][state] rescue nil
    nstate = cstate unless nstate
    if cstate == nstate
      @logger.info("Provisioner transition: #{name} does not need a provisioner state transition")
      return [200,'']
    end

    if nstate == "os_install"
      # Handle turning os_install into the proper state for the preferred OS.
      target_os = node_hash["crowbar"]["os"]
      if target_os.nil? || (target_os == "default_os")
        # If not otherwise configured, use whatever OS the provisioner prefers.
        target_os = prop_config.config_hash["provisioner"]["default_os"]
        node_hash["crowbar"]["os"] = target_os
      end
      provisioner = Node.find_by_role_name('provisioner-server')
      if provisioner &&
          provisioner[0] &&
          provisioner[0].jig_hash["provisioner"]["available_oses"][target_os]
        nstate = "#{target_os}_install"
      else
        return [500, "#{node.name} wants to install #{target_os}, but #{name} doesn't know how to do that!"]
      end
    end

    node_hash["provisioner_state"] = nstate
    prop_config.set_node_config_hash(node, node_hash)
    node.update_jig

    # We need a real process runner here.
    # Blocking Puma to wait on these state transitions is bad, mmkay?
    if cstate == "execute"
      @logger.info("Provisioner transition: going from #{cstate} => #{nstate}, run chef-client on #{node.name}")
      run_remote_chef_client(node.name, "chef-client", "log/#{node.name}.chef_client.log")
      Process.waitall
    end

    # GREG: Remote the provisioner call.
    @logger.info("Provisioner transition: Run the chef-client locally")
    system("sudo -i /opt/dell/bin/blocking_chef_client.sh")
    @logger.info("Provisioner transition: exiting for #{name} for #{state}")
    [200, ""]
  end

end

