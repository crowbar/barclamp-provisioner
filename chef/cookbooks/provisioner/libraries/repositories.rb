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
      def suse_optional_repos(version, type)
        case type
        when :common
          %w(PTF)
        when :cloud
          case version
          when /^11\.[34]$/
            %w(
              Cloud
              SUSE-OpenStack-Cloud-SLE11-6-Pool
              SUSE-OpenStack-Cloud-SLE11-6-Updates
            )
          when "12.0"
            %w(
              Cloud
              SUSE-OpenStack-Cloud-6-Pool
              SUSE-OpenStack-Cloud-6-Updates
            )
          else
            []
          end
        when :hae
          case version
          when "11.3"
            %w(SLE11-HAE-SP3-Pool SLE11-HAE-SP3-Updates)
          when "11.4"
            %w(SLE11-HAE-SP4-Pool SLE11-HAE-SP4-Updates)
          when "12.0"
            %w(SLE12-HA-Pool SLE12-HA-Updates)
          else
            []
          end
        when :storage
          case version
          when "12.0"
            %w(SUSE-Enterprise-Storage-1.0-Pool SUSE-Enterprise-Storage-1.0-Updates)
          else
            []
          end
        end
      end

      def suse_get_repos_from_attributes(node,platform,version)
        repos = Mash.new

        if node[:provisioner][:suse] && node[:provisioner][:suse][:autoyast] && node[:provisioner][:suse][:autoyast][:repos]
          if node[:provisioner][:suse][:autoyast][:repos][:common]
            repos = node[:provisioner][:suse][:autoyast][:repos][:common].to_hash
          end
          product = "#{platform}-#{version}"
          if node[:provisioner][:suse][:autoyast][:repos][product]
            repos.merge! node[:provisioner][:suse][:autoyast][:repos][product].to_hash
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
          repos = Mash.new
          common_available = false
          cloud_available = false
          hae_available = false
          storage_available = false

          %w(11.3 11.4 12.0).each do |version|
            repos.merge! suse_get_repos_from_attributes(node,"suse",version)

            # Common optional repos (regardless of cloud vs. storage)
            suse_optional_repos(version, :common).each do |name|
              repos[name] ||= Mash.new
              next unless repos[name][:url].nil?
              common_available ||= File.exist?("#{node[:provisioner][:root]}/suse-#{version}/repos/#{name}/repodata/repomd.xml")
            end

            # For cloud
            suse_optional_repos(version, :cloud).each do |name|
              repos[name] ||= Mash.new
              next unless repos[name][:url].nil?
              cloud_available ||= File.exist?("#{node[:provisioner][:root]}/suse-#{version}/repos/#{name}/repodata/repomd.xml") ||
                                File.exist?("#{node[:provisioner][:root]}/suse-#{version}/repos/#{name}/suse/repodata/repomd.xml")
            end

            # For pacemaker
            suse_optional_repos(version, :hae).each do |name|
              repos[name] ||= Mash.new
              next unless repos[name][:url].nil?
              hae_available ||= File.exist?("#{node[:provisioner][:root]}/suse-#{version}/repos/#{name}/repodata/repomd.xml")
            end

            # For suse storage
            suse_optional_repos(version, :storage).each do |name|
              repos[name] ||= Mash.new
              next unless repos[name][:url].nil?
              storage_available ||= File.exist?("#{node[:provisioner][:root]}/suse-#{version}/repos/#{name}/repodata/repomd.xml")
            end
          end

          # set an attribute about available repos so that cookbooks and crowbar
          # know that HA can be used
          # know that SUSE_Storage can be used
          # know that OpenStack can be used
          node_set = false
          node.set[:provisioner][:suse] ||= {}
          if node[:provisioner][:suse][:common_available] != common_available
            node.set[:provisioner][:suse][:common_available] = common_available
            node_set = true
          end
          if node[:provisioner][:suse][:cloud_available] != cloud_available
            node.set[:provisioner][:suse][:cloud_available] = cloud_available
            node_set = true
          end
          if node[:provisioner][:suse][:hae_available] != hae_available
            node.set[:provisioner][:suse][:hae_available] = hae_available
            node_set = true
          end
          if node[:provisioner][:suse][:storage_available] != storage_available
            node.set[:provisioner][:suse][:storage_available] = storage_available
            node_set = true
          end
          if node_set
            node.save
          end
        end
      end

      # This returns a hash containing the data about the repos that must be
      # used on nodes; optional repos (such as HA) will only be returned if
      # they can be used.
      def get_repos(provisioner_server_node, platform, version)
        admin_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(provisioner_server_node, "admin").address
        web_port = provisioner_server_node[:provisioner][:web_port]
        provisioner_web = "http://#{admin_ip}:#{web_port}"
        default_repos_url = "#{provisioner_web}/suse-#{version}/repos"

        repos = Mash.new

        case platform
        when "suse"
          repos = Mash.new
          repos_from_attrs = suse_get_repos_from_attributes(provisioner_server_node,platform,version)

          case version
          when "11.3"
            repo_names = %w(
              SLES11-SP3-Pool
              SLES11-SP3-Updates
            )
          when "11.4"
            repo_names = %w(
              SLES11-SP4-Pool
              SLES11-SP4-Updates
            )
          when "12.0"
            repo_names = %w(
              SLES12-Pool
              SLES12-Updates
            )
          else
            raise "Unsupported version of SLE/openSUSE!"
          end

          # Add the new (not predefined) repositories from attributes
          repos_from_attrs.each do |name,repo|
            repo_names << name unless repo_names.include? name
          end

          # This needs to be done here rather than via deep-merge with static
          # JSON due to the dynamic nature of the default value.
          repo_names.each do |name|
            repos[name] = repos_from_attrs.fetch(name, Mash.new)
            repos[name][:url] ||= default_repos_url + '/' + name
          end

          # optional repos
          unless provisioner_server_node[:provisioner][:suse].nil?
            [[:common, :common_available],
             [:cloud, :cloud_available],
             [:hae, :hae_available],
             [:storage, :storage_available]].each do |optionalrepo|
              if provisioner_server_node[:provisioner][:suse][optionalrepo[1]]
                suse_optional_repos(version, optionalrepo[0]).each do |name|
                  repos[name] = repos_from_attrs.fetch(name, Mash.new)
                  repos[name][:url] ||= default_repos_url + '/' + name
                end
              end
            end
          end
        end

        repos
      end
    end
  end
end
