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

class ProvisionerController < BarclampController
  self.help_contents = Array.new(superclass.help_contents)

  add_help(:oses)
  def oses
    res = get_oses
    respond_to do |format|
      format.html
      format.json { render :json => res }
    end
  end

  # XXX: This will need to converted to new formats.
  # os should be pulled from the provisioner config.

  add_help(:current_os, [:id,:name])
  def current_os
    node = Node.find_by_name(params[:name])
    return render :text => "Could not find node #{params[:name]}", :status => 404 unless node
    render :json => [ node.crowbar["crowbar"]["os"].to_s ]
  end

  add_help(:set_os, [:id,:node,:os], [:post])
  def set_os
    node = Node.find_node_name(params[:node])
    return render :text => "Could not find node #{params[:name]}", :status => 404 unless node
    oses = get_oses
    return render :text => "#{params[:os]} is not an available OS", :status => 404 unless oses.member?(params[:os])
    node.crowbar["crowbar"]["os"] = params[:os]
    node.save
    render :json => [ node.crowbar["crowbar"]["os"].to_s ]
  end

  private
  def get_oses
    provisioners = Node.find_by_role_name('provisioner-server')
    provisioners ? provisioners.map{|n|n.jig_hash["provisioner"]["available_oses"].keys}.flatten.sort.uniq : []
  end
end

