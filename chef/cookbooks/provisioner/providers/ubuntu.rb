# Copyright 2013, Dell
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

action :add do
  os = "ubuntu-#{new_resource.version}"
  proxy = node["crowbar"]["provisioner"]["server"]["proxy"]
  repos = node["crowbar"]["provisioner"]["server"]["repositories"][os]
  params = node["crowbar"]["provisioner"]["server"]["boot_specs"][os]
  online = node["crowbar"]["provisioner"]["server"]["online"]
  tftproot = node["crowbar"]["provisioner"]["server"]["root"]
  provisioner_addr = node["crowbar"]["provisioner"]["server"]["v4addr"]
  provisioner_web = node["crowbar"]["provisioner"]["server"]["webserver"]
  use_local_security = node["crowbar"]["provisioner"]["server"]["use_local_security"]
  os_codename = node["crowbar"]["provisioner"]["server"]["supported_oses"][os]["codename"]
  keys = node["crowbar"]["provisioner"]["server"]["access_keys"].values.sort.join($/)
  os_dir = "#{tftproot}/#{os}"
  mnode_name = new_resource.name
  web_path = "#{provisioner_web}/#{os}"
  crowbar_repo_web="#{web_path}/crowbar-extra"
  admin_web="#{web_path}/install"
  append = "url=#{web_path}/#{mnode_name}.seed netcfg/get_hostname=#{mnode_name} #{params["kernel_params"]}"
  v4addr = new_resource.address

  template "#{os_dir}/#{mnode_name}.seed" do
    mode 0644
    owner "root"
    group "root"
    source "net_seed.erb"
    variables(:install_name => os,
              :name => mnode_name,
              :cc_use_local_security => use_local_security,
              :os_install_site => params[:os_install_site],
              :online => online,
              :provisioner_web => provisioner_web,
              :web_path => web_path,
              :proxy => "http://#{proxy}/")
  end

  template "#{os_dir}/#{mnode_name}-post-install.sh" do
    mode 0644
    owner "root"
    group "root"
    source "net-post-install.sh.erb"
    variables(:admin_web => admin_web,
              :os_codename => os_codename,
              :repos => repos,
              :admin_ip => provisioner_addr,
              :online => online,
              :keys => keys,
              :provisioner_web => provisioner_web,
              :proxy => "http://#{proxy}/",
              :web_path => web_path)
  end

  template "#{os_dir}/crowbar_join.sh" do
    mode 0644
    owner "root"
    group "root"
    source "crowbar_join.ubuntu.sh.erb"
    variables(:admin_ip => provisioner_addr)
  end

  provisioner_bootfile mnode_name do
    bootenv "#{os}-install"
    kernel params["kernel"]
    initrd params["initrd"]
    address v4addr
    kernel_params append
    action :add
  end
  
end
