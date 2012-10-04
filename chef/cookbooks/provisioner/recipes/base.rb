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

package "ipmitool" do
  package_name "OpenIPMI-tools" if node[:platform] =~ /^(redhat|centos)$/
  action :install
end

directory "/root/.ssh" do
  owner "root"
  group "root"
  mode "0700"
  action :create
end

# We don't want to use bluepill on SUSE
if node["platform"] != "suse"
  # Make sure we have Bluepill
  case node["state"]
  when "ready","readying"
    include_recipe "bluepill"
  end
end

node["crowbar"]["ssh"] = {} if node["crowbar"]["ssh"].nil?

# Start with a blank slate, to ensure that any keys removed from a
# previously applied proposal will be removed.  It also means that any
# keys manually added to authorized_keys will be automatically removed
# by Chef.
node["crowbar"]["ssh"]["access_keys"] = {}

# Build my key
node_modified = false
if ::File.exists?("/root/.ssh/id_rsa.pub") == false
  %x{ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ""}
end

str = %x{cat /root/.ssh/id_rsa.pub}.chomp
node["crowbar"]["ssh"]["root_pub_key"] = str
node["crowbar"]["ssh"]["access_keys"][node.name] = str
node_modified = true

# Add additional keys
node["provisioner"]["access_keys"].strip.split("\n").each do |key|
  key.strip!
  nodename = key.split(" ")[2]
  nodename = key.split("@")[1] if key.include?("@")
  node["crowbar"]["ssh"]["access_keys"][nodename] = key
end

# Find provisioner servers and include them.
search(:node, "roles:provisioner-server AND provisioner_config_environment:#{node[:provisioner][:config][:environment]}") do |n|
  pkey = n["crowbar"]["ssh"]["root_pub_key"] rescue nil
  if !pkey.nil? and pkey != node["crowbar"]["ssh"]["access_keys"][n.name]
    node["crowbar"]["ssh"]["access_keys"][n.name] = pkey
    node_modified = true
  end
end
node.save if node_modified

file "/root/.ssh/authorized_keys" do
  action :delete
end
template "/root/.ssh/authorized_keys" do
  owner "root"
  group "root"
  mode "0700"
  action :create
  source "authorized_keys.erb"
  variables(:keys => node["crowbar"]["ssh"]["access_keys"])
end

bash "Disable Strict Host Key checking" do
  code "echo '    StrictHostKeyChecking no' >>/etc/ssh/ssh_config"
  not_if "grep -q 'StrictHostKeyChecking no' /etc/ssh/ssh_config"
end

config_file = "/etc/default/chef-client"
config_file = "/etc/sysconfig/chef-client" if node[:platform] =~ /^(redhat|centos)$/

cookbook_file config_file do
  owner "root"
  group "root"
  mode "0644"
  action :create
  source "chef-client"
end

