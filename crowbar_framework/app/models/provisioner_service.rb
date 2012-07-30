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
      else
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
            server_ip = node.address("public").addr rescue node.address.addr
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

    #
    # test state machine and call chef-client if state changes
    #
    node = NodeObject.find_node_by_name(name)
    if ! node
      @logger.error("Provisioner transition: leaving #{name} for #{state}: Node not found")
      return [404, "Failed to find node"]
    end
    unless node.admin?
      cstate = node.crowbar["provisioner_state"]
      nstate = (role.default_attributes["provisioner"]["dhcp"]["state_machine"][state] || node.crowbar["provisioner_state"])
      # All non-admin nodes call single_chef_client if the state machine says to.
      if cstate != nstate
        if nstate == "os_install"
          target_os = (node[:crowbar][:os] rescue nil)
          target_os ||= role.default_attributes["provisioner"]["default_os"]
          if role.default_attributes["provisioner"]["supported_oses"][target_os]
            nstate = "#{target_os}_install"
          else
            return [500, "#{node.name} wants to install #{target_os}, but #{name} doesn't know how to do that!"]
          end
        end

        node.crowbar["provisioner_state"] = nstate
        node.save

        # We need a real process runner here.
        if cstate == "execute"
          @logger.info("Provisioner transition: going from #{cstate} => #{nstate}, run chef-client on #{node.name}")
          run_remote_chef_client(node["fqdn"], "chef-client", "log/#{node.name}.chef_client.log")
          Process.waitall
        end
        @logger.info("Provisioner transition: Run the chef-client locally")
        system("sudo -i /opt/dell/bin/blocking_chef_client.sh")
      end
      #
      # The temp booting images need to have clients cleared.
      #
      if ["discovered","hardware-installed","hardware-updated",
          "hardware-installing","hardware-updating","reinstall",
          "update","installing","installed"].member?(state) and !node.admin?
        @logger.info("Provisioner transition: should be deleting a client entry for #{node.name}")
        client = ClientObject.find_client_by_name node.name
        @logger.info("Provisioner transition: found and trying to delete a client entry for #{node.name}") unless client.nil?
        client.destroy unless client.nil?

        # Make sure that the node can be accessed by knife ssh or ssh
        if ["reset","reinstall","update","delete"].member?(state)
          system("sudo rm /root/.ssh/known_hosts")
        end
      end
    end
    @logger.info("Provisioner transition: exiting for #{name} for #{state}")
    [200, node.to_hash ]
  end

end

