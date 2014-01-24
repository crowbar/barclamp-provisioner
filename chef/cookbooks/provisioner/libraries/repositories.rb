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
      def get_repos(provisioner_server_node, platform)
        admin_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(provisioner_server_node, "admin").address
        web_port = provisioner_server_node[:provisioner][:web_port]
        provisioner_web = "http://#{admin_ip}:#{web_port}"
        default_repos_url = "#{provisioner_web}/repos"

        repos = Mash.new

        case platform
          when "suse"
            if provisioner_server_node[:provisioner][:suse]
              if provisioner_server_node[:provisioner][:suse][:autoyast]
                if provisioner_server_node[:provisioner][:suse][:autoyast][:repos]
                  repos = provisioner_server_node[:provisioner][:suse][:autoyast][:repos].to_hash
                end
              end
            end
            # This needs to be done here rather than via deep-merge with static
            # JSON due to the dynamic nature of the default value.
            %w(
              SLE-Cloud
              SLE-Cloud-PTF
              SUSE-Cloud-3-Pool
              SUSE-Cloud-3-Updates
              SLES11-SP3-Pool
              SLES11-SP3-Updates
            ).each do |name|
              suffix = name.sub(/^SLE-/, '')
              repos[name] ||= Mash.new
              repos[name][:url] ||= default_repos_url + '/' + suffix
            end
        end

        repos
      end
    end
  end
end
