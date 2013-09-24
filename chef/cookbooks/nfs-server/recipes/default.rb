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

rpcService="portmap"
case node[:platform]
when "ubuntu","debian"
  package "nfs-common"
  package "nfs-kernel-server"

  case node[:lsb][:codename]
  when "precise"
    cookbook_file "/etc/init.d/nfs-kernel-server" do
      source "nfs-kernel-server.init.d.precise"
      mode "0755"
      notifies :restart, "service[nfs-kernel-server]", :delayed
    end

    cookbook_file "/etc/default/nfs-kernel-server" do
      source "nfs-kernel-server.default.precise"
      mode "0644"
      notifies :restart, "service[nfs-kernel-server]", :delayed
    end
  end

when "centos","redhat","suse"
  package "nfs-utils"
  if node[:platform_version].to_f >= 6 || node[:platform] == "suse"
    rpcService="rpcbind"
  end
end

package rpcService

service rpcService do
  running true
  enabled true
  action [ :enable, :start ]
end

directory "/install-logs" do
  owner "root"
  group "root"
  mode 0755
end

service "nfs-kernel-server" do
  service_name "nfs" if node[:platform] =~ /^(redhat|centos)$/
  service_name "nfsserver" if node[:platform] == "suse"
  supports :restart => true, :status => true, :reload => true
  running true
  enabled true
  action [ :enable, :start ]
end

execute "nfs-export" do
  command "exportfs -a"
  action :nothing
end

template "/etc/exports" do
  source "exports.erb"
  group "root"
  owner "root"
  mode 0644
  variables(:admin_subnet => node.address("admin",IP::IP4).network.to_s)
  notifies :run, "execute[nfs-export]", :delayed
end
