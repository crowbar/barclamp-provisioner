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

class BarclampProvisioner::OsInstall < Role
  
  def on_proposed(nr)
    nr.sysdata = {
      "crowbar" => {
        "target_os" => nr.deployment_data["crowbar"]["target_os"]
      }
    }
  end

  def on_active(nr)
    node = nr.node
    target = nr.all_my_data["crowbar"]["target_os"] rescue nr.deployment_data["crowbar"]["target_os"]
    return if node.bootenv == "local"
    Rails.logger.info("provisioner-install: Trying to install #{target} on #{node.name} (bootenv: #{node.bootenv})")

    node.bootenv = "#{target}-install"
    node.alive = false
    node.save!
  end

end
