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

node.set["crowbar"]["ssh"] = {} if node["crowbar"]["ssh"].nil?

# Start with a blank slate, to ensure that any keys removed from a
# previously applied proposal will be removed.  It also means that any
# keys manually added to authorized_keys will be automatically removed
# by Chef.
node.set["crowbar"]["ssh"]["access_keys"] = {}

# Build my key
node_modified = false
if ::File.exists?("/root/.ssh/id_rsa.pub") == false
  %x{ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ""}
end

str = %x{cat /root/.ssh/id_rsa.pub}.chomp
node.set["crowbar"]["ssh"]["root_pub_key"] = str
node.set["crowbar"]["ssh"]["access_keys"][node.name] = str
node_modified = true

# Add additional keys
node["provisioner"]["access_keys"].strip.split("\n").each do |key|
  key.strip!
  if !key.empty?
    nodename = key.split(" ")[2]
    nodename = key.split("@")[1] if key.include?("@")
    node.set["crowbar"]["ssh"]["access_keys"][nodename] = key
  end
end

# Find provisioner servers and include them.
search(:node, "roles:provisioner-server AND provisioner_config_environment:#{node[:provisioner][:config][:environment]}") do |n|
  pkey = n["crowbar"]["ssh"]["root_pub_key"] rescue nil
  if !pkey.nil? and pkey != node["crowbar"]["ssh"]["access_keys"][n.name]
    node.set["crowbar"]["ssh"]["access_keys"][n.name] = pkey
    node_modified = true
  end
end
node.save if node_modified

template "/root/.ssh/authorized_keys" do
  owner "root"
  group "root"
  mode "0644"
  action :create
  source "authorized_keys.erb"
  variables(:keys => node["crowbar"]["ssh"]["access_keys"])
end

# Also put authorized_keys in tftpboot path on the admin node so that discovered
# nodes can use the same.
if node.roles.include? "crowbar"
  case node[:platform]
  when "suse"
    tftpboot_path = "/srv/tftpboot"
  else
    tftpboot_path = "/tftpboot"
  end

  template "#{tftpboot_path}/authorized_keys" do
    owner "root"
    group "root"
    mode "0644"
    action :create
    source "authorized_keys.erb"
    variables(:keys => node["crowbar"]["ssh"]["access_keys"])
  end
end

bash "Disable Strict Host Key checking" do
  code "echo '    StrictHostKeyChecking no' >>/etc/ssh/ssh_config"
  not_if "grep -q 'StrictHostKeyChecking no' /etc/ssh/ssh_config"
end

bash "Set EDITOR=vi environment variable" do
  code "echo \"EDITOR=vi\" > /etc/profile.d/editor.sh"
  not_if "export | grep -q EDITOR="
end

sysctl_core_dump_file = "/etc/sysctl.d/core-dump.conf"
if node[:provisioner][:coredump]
  directory "create /etc/sysctl.d for core-dump" do
    path "/etc/sysctl.d"
    mode "755"
  end
  cookbook_file sysctl_core_dump_file do
    owner "root"
    group "root"
    mode "0644"
    action :create
    source "core-dump.conf"
  end
  bash "reload core-dump-sysctl" do
    code "/sbin/sysctl -e -q -p #{sysctl_core_dump_file}"
    action :nothing
    subscribes :run, resources(:cookbook_file=> sysctl_core_dump_file), :delayed
  end
  bash "Enable core dumps" do
    code "ulimit -c unlimited"
  end
  # Permanent core dumping (needs reboot)
  bash "Enable permanent core dumps (/etc/security/limits)" do
    code "echo '* soft core unlimited' >> /etc/security/limits.conf"
    not_if "grep -q 'soft core unlimited' /etc/security/limits.conf"
  end
  if node[:platform] == "suse"
    package "ulimit"
    # Permanent core dumping (no reboot needed)
    bash "Enable permanent core dumps (/etc/sysconfig/ulimit)" do
      code 'sed -i s/SOFTCORELIMIT.*/SOFTCORELIMIT="unlimited"/ /etc/sysconfig/ulimit'
      not_if "grep -q 'SOFTCORELIMIT=\"unlimited\"' /etc/sysconfig/ulimit"
    end
  end
else
  file sysctl_core_dump_file do
    action :delete
  end
  bash "Disable permanent core dumps (/etc/security/limits)" do
    code 'sed -is "/\* soft core unlimited/d" /etc/security/limits.conf'
    only_if "grep -q '* soft core unlimited' /etc/security/limits.conf"
  end
  if node[:platform] == "suse"
    package "ulimit"
    bash "Disable permanent core dumps (/etc/sysconfig/ulimit)" do
      code 'sed -i s/SOFTCORELIMIT.*/SOFTCORELIMIT="1"/ /etc/sysconfig/ulimit'
      not_if "grep -q 'SOFTCORELIMIT=\"1\"' /etc/sysconfig/ulimit"
    end
  end
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

