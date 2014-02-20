#
# Copyright 2013-2014, SUSE LINUX Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

class Provisioner
  class Repositories
    class << self
      def suse_optional_repos
        %w(SLE11-HAE-SP3-Pool SLE11-HAE-SP3-Updates)
      end

      def suse_get_repos_from_attributes(node)
        repos = Mash.new

        if node[:provisioner][:suse]
          if node[:provisioner][:suse][:autoyast]
            if node[:provisioner][:suse][:autoyast][:repos]
              repos = node[:provisioner][:suse][:autoyast][:repos].to_hash
            end
          end
        end

        repos
      end

      def inspect_repos(node)
        unless node.roles.include? "provisioner-server"
          raise "Internal error: inspect_repos method should only be called on provisioner-server node."
        end

        case node[:platform]
        when "suse"
          repos = suse_get_repos_from_attributes(node)

          missing = false
          suse_optional_repos.each do |name|
            repos[name] ||= Mash.new
            next unless repos[name][:url].nil?
            missing ||= !(File.exists? "#{node[:provisioner][:root]}/repos/#{name}")
          end

          node.set[:provisioner][:suse] ||= {}
          if node[:provisioner][:suse][:missing_hae] != missing
            node.set[:provisioner][:suse][:missing_hae] = missing
            node.save
          end
        end
      end

      def get_repos(provisioner_server_node, platform)
        admin_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(provisioner_server_node, "admin").address
        web_port = provisioner_server_node[:provisioner][:web_port]
        provisioner_web = "http://#{admin_ip}:#{web_port}"
        default_repos_url = "#{provisioner_web}/repos"

        repos = Mash.new

        case platform
        when "suse"
          repos = suse_get_repos_from_attributes(provisioner_server_node)

          # This needs to be done here rather than via deep-merge with static
          # JSON due to the dynamic nature of the default value.
          %w(
            SLE-Cloud
            SLE-Cloud-PTF
            SUSE-Cloud-4-Pool
            SUSE-Cloud-4-Updates
            SLES11-SP3-Pool
            SLES11-SP3-Updates
          ).each do |name|
            suffix = name.sub(/^SLE-Cloud/, 'Cloud')
            repos[name] ||= Mash.new
            repos[name][:url] ||= default_repos_url + '/' + suffix
          end

          # optional repos
          unless provisioner_server_node[:provisioner][:suse].nil?
            unless provisioner_server_node[:provisioner][:suse][:missing_hae]
              suse_optional_repos.each do |name|
                repos[name] ||= Mash.new
                repos[name][:url] ||= default_repos_url + '/' + name
              end
            end
          end
        end

        repos
      end
    end
  end
end
