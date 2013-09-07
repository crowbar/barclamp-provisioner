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
directory "/root/.ssh" do
  owner "root"
  group "root"
  mode "0700"
  action :create
end

keys = (node["crowbar"]["provisioner"]["server"]["access_keys"] rescue Hash.new)
raise "Could not find access keys for SSH" if keys.empty?

template "/root/.ssh/authorized_keys" do
  owner "root"
  group "root"
  mode "0700"
  action :create
  source "authorized_keys.erb"
  variables(:keys => keys.values.sort)
end

bash "Disable Strict Host Key checking" do
  code "echo '    StrictHostKeyChecking no' >>/etc/ssh/ssh_config"
  not_if "grep -q 'StrictHostKeyChecking no' /etc/ssh/ssh_config"
end
