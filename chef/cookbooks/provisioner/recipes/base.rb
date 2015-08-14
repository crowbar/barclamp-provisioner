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

return if node[:platform] == "windows"

###
# If anything has to be applied to a Windows node, it has to be done
# before the return above, anything from this point forward being applied
# to linux nodes only.
###

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

# We don't want to use bluepill on SUSE and Windows
if node["platform"] != "suse"
  # Make sure we have Bluepill
  case node["state"]
  when "ready","readying"
    include_recipe "bluepill"
  end
end

node.set["crowbar"]["ssh"] ||= {}

# Start with a blank slate, to ensure that any keys removed from a
# previously applied proposal will be removed.  It also means that any
# keys manually added to authorized_keys will be automatically removed
# by Chef.
node.set["crowbar"]["ssh"]["access_keys"] = {}

# Build my key
if ::File.exists?("/root/.ssh/id_rsa.pub") == false
  %x{ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ""}
end

str = %x{cat /root/.ssh/id_rsa.pub}.chomp
node.set["crowbar"]["ssh"]["root_pub_key"] = str
node.set["crowbar"]["ssh"]["access_keys"][node.name] = str

# Add additional keys
node["provisioner"]["access_keys"].strip.split("\n").each do |key|
  key.strip!
  if !key.empty?
    nodename = key.split(" ")[2]
    node.set["crowbar"]["ssh"]["access_keys"][nodename] = key
  end
end

# Find provisioner servers and include them.
provisioner_server_node = nil
search(:node, "roles:provisioner-server AND provisioner_config_environment:#{node[:provisioner][:config][:environment]}") do |n|
  provisioner_server_node = n if provisioner_server_node.nil?

  pkey = n["crowbar"]["ssh"]["root_pub_key"] rescue nil
  if !pkey.nil? and pkey != node["crowbar"]["ssh"]["access_keys"][n.name]
    node.set["crowbar"]["ssh"]["access_keys"][n.name] = pkey
  end
end

# Fix bug we had in stoney and earlier where we never saved the target_platform
# of the node when the node was installed with the default target platform.
# This only works because the default target platform didn't change between
# stoney and tex.
if node[:target_platform].nil? or node[:target_platform].empty?
  node.set[:target_platform] = provisioner_server_node[:provisioner][:default_os]
end

node.save

template "/root/.ssh/authorized_keys" do
  owner "root"
  group "root"
  mode "0644"
  action :create
  source "authorized_keys.erb"
  variables(:keys => node["crowbar"]["ssh"]["access_keys"])
end

template "/etc/sudo.conf" do
  source "sudo.conf.erb"
  owner "root"
  group "root"
  mode "0644"
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
  code "echo \"export EDITOR=vi\" > /etc/profile.d/editor.sh"
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
    if node[:platform_version].to_f < 12.0
      package "ulimit"
      # Permanent core dumping (no reboot needed)
      bash "Enable permanent core dumps (/etc/sysconfig/ulimit)" do
        code 'sed -i s/SOFTCORELIMIT.*/SOFTCORELIMIT="unlimited"/ /etc/sysconfig/ulimit'
        not_if "grep -q '^SOFTCORELIMIT=\"unlimited\"' /etc/sysconfig/ulimit"
      end
    else
      # Permanent core dumping (no reboot needed)
      bash "Enable permanent core dumps (/etc/systemd/system.conf)" do
        code 'sed -i s/^#*DefaultLimitCORE=.*/DefaultLimitCORE=infinity/ /etc/systemd/system.conf'
        not_if "grep -q '^DefaultLimitCORE=infinity' /etc/systemd/system.conf"
      end
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
    if node[:platform_version].to_f < 12.0
      package "ulimit"
      bash "Disable permanent core dumps (/etc/sysconfig/ulimit)" do
        code 'sed -i s/SOFTCORELIMIT.*/SOFTCORELIMIT="1"/ /etc/sysconfig/ulimit'
        not_if "grep -q '^SOFTCORELIMIT=\"1\"' /etc/sysconfig/ulimit"
      end
    else
      bash "Disable permanent core dumps (/etc/sysconfig/ulimit)" do
        code 'sed -i s/^DefaultLimitCORE=.*/#DefaultLimitCORE=/ /etc/systemd/system.conf'
        not_if "grep -q '^#DefaultLimitCORE=' /etc/systemd/system.conf"
      end
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

# On SUSE: install crowbar_join properly, with init script
if node["platform"] == "suse" && !node.roles.include?("provisioner-server")
  admin_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(provisioner_server_node, "admin").address
  web_port = provisioner_server_node[:provisioner][:web_port]

  ntp_servers = search(:node, "roles:ntp-server")
  ntp_servers_ips = ntp_servers.map { |n| Chef::Recipe::Barclamp::Inventory.get_network_by_type(n, "admin").address }

  template "/usr/sbin/crowbar_join" do
    mode 0755
    owner "root"
    group "root"
    source "crowbar_join.suse.sh.erb"
    variables(:admin_ip => admin_ip,
              :web_port => web_port,
              :ntp_servers_ips => ntp_servers_ips,
              :target_platform_version => node["platform_version"] )
  end

  if node["platform_version"].to_f < 12.0
    cookbook_file "/etc/init.d/crowbar_join" do
      owner "root"
      group "root"
      mode "0755"
      action :create
      source "crowbar_join.init.suse"
    end

    link "/usr/sbin/rccrowbar_join" do
      action :create
      to "/etc/init.d/crowbar_join"
    end

    # Make sure that any dependency change is taken into account
    bash "insserv crowbar_join service" do
      code "insserv crowbar_join"
      action :nothing
      subscribes :run, resources(:cookbook_file=> "/etc/init.d/crowbar_join"), :delayed
    end
  else
    # Use a systemd .service file on SLE12
    cookbook_file "/etc/systemd/system/crowbar_notify_shutdown.service" do
      owner "root"
      group "root"
      mode "0644"
      action :create
      source "crowbar_notify_shutdown.service"
    end

    cookbook_file "/etc/systemd/system/crowbar_join.service" do
      owner "root"
      group "root"
      mode "0644"
      action :create
      source "crowbar_join.service"
    end

    # Make sure that any dependency change is taken into account
    bash "reload systemd after crowbar_join update" do
      code "systemctl daemon-reload"
      action :nothing
      subscribes :run, resources(:cookbook_file=> "/etc/systemd/system/crowbar_notify_shutdown.service"), :immediately
      subscribes :run, resources(:cookbook_file=> "/etc/systemd/system/crowbar_join.service"), :immediately
    end

    link "/usr/sbin/rccrowbar_join" do
      action :create
      to "service"
    end

    service "crowbar_notify_shutdown" do
      action :enable
    end
  end

  service "crowbar_join" do
    action :enable
  end

  cookbook_file "/etc/logrotate.d/crowbar_join" do
    owner "root"
    group "root"
    mode "0644"
    source "crowbar_join.logrotate.suse"
    action :create
  end

  # remove old crowbar_join.sh file
  file "/etc/init.d/crowbar_join.sh" do
    action :delete
  end

  if node["platform"] == "suse"
    ## make sure the repos are properly setup
    repos = Provisioner::Repositories.get_repos(provisioner_server_node, node["platform"], node["platform_version"])
    for name, attrs in repos
      url = %x{zypper --non-interactive repos #{name} 2> /dev/null | grep "^URI " | cut -d : -f 2-}
      url.strip!
      if url != attrs[:url]
        unless url.empty?
          Chef::Log.info("Removing #{name} zypper repository pointing to wrong URI...")
          %x{zypper --non-interactive removerepo #{name}}
        end
        Chef::Log.info("Adding #{name} zypper repository...")
        %x{zypper --non-interactive addrepo --refresh #{attrs[:url]} #{name}}
      end
    end
    # install additional packages
    os = "#{node[:platform]}-#{node[:platform_version]}"
    if node[:provisioner][:packages][os]
      node[:provisioner][:packages][os].each { |p| package p }
    end
  end
end

aliaz = begin
  display_alias = node["crowbar"]["display"]["alias"]
  if display_alias && !display_alias.empty?
    display_alias
  else
    node["hostname"]
  end
rescue
  node["hostname"]
end

%w(/etc/profile.d/zzz-prompt.sh /etc/profile.d/zzz-prompt.csh).each do |cfg|
  template cfg do
    source "zzz-prompt.sh.erb"
    owner "root"
    group "root"
    mode "0644"

    variables(
      :prompt_from_template => proc { |user, cwd|
        node["provisioner"]["shell_prompt"].to_s \
          .gsub("USER", user) \
          .gsub("CWD", cwd) \
          .gsub("SUFFIX", "${prompt_suffix}") \
          .gsub("ALIAS", aliaz) \
          .gsub("HOST", node["hostname"]) \
          .gsub("FQDN", node["fqdn"])
      },

      :zsh_prompt_from_template => proc {
        node["provisioner"]["shell_prompt"].to_s \
          .gsub("USER", "%{\\e[0;31m%}%n%{\\e[0m%}") \
          .gsub("CWD", "%{\\e[0;35m%}%~%{\\e[0m%}") \
          .gsub("SUFFIX", "%#") \
          .gsub("ALIAS", "%{\\e[0;35m%}#{aliaz}%{\\e[0m%}") \
          .gsub("HOST", "%{\\e[0;35m%}#{node["hostname"]}%{\\e[0m%}") \
          .gsub("FQDN", "%{\\e[0;35m%}#{node["fqdn"]}%{\\e[0m%}")
      },

      :bash_prompt_from_template => proc {
        node["provisioner"]["shell_prompt"].to_s \
          .gsub("USER", "\\[\\e[01;31m\\]\\u\\[\\e[0m\\]") \
          .gsub("CWD", "\\[\\e[01;31m\\]\\w\\[\\e[0m\\]") \
          .gsub("SUFFIX", "${prompt_suffix}") \
          .gsub("ALIAS", "\\[\\e[01;35m\\]#{aliaz}\\[\\e[0m\\]") \
          .gsub("HOST", "\\[\\e[01;35m\\]#{node["hostname"]}\\[\\e[0m\\]") \
          .gsub("FQDN", "\\[\\e[01;35m\\]#{node["fqdn"]}\\[\\e[0m\\]")
      }
    )
  end
end

template "/etc/sh.shrc.local" do
  source "shrc.local.erb"
  owner "root"
  group "root"
  mode "0644"
end
