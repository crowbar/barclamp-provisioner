# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied
# See the License for the specific language governing permissions and
# limitations under the License
#

package "syslinux"

append_line = "append initrd=initrd0.img root=/sledgehammer.iso rootfstype=iso9660 rootflags=loop"
if node[:provisioner][:use_serial_console]
  append_line += " console=tty0 console=ttyS1,115200n8"
end
if ::File.exists?("/etc/crowbar.install.key")
  append_line += " crowbar.install.key=#{::File.read("/etc/crowbar.install.key").chomp.strip}"
end

pxecfg_dir="/tftpboot/discovery/pxelinux.cfg"

# Generate the appropriate pxe config file for each state
[ "discovery","update","hwinstall"].each do |state|
  template "#{pxecfg_dir}/#{state}" do
    mode 0644
    owner "root"
    group "root"
    source "default.erb"
    variables(:append_line => "#{append_line} crowbar.state=#{state}",
              :install_name => state,  
              :kernel => "vmlinuz0")
  end
end

# and the execute state as well
cookbook_file "#{pxecfg_dir}/execute" do
  mode 0644
  owner "root"
  group "root"
  source "localboot.default"
end

# Make discovery our default state
link "#{pxecfg_dir}/default" do
  to "discovery"
end

include_recipe "bluepill"

package "nginx"

service "nginx" do
  action :disable
end

link "/etc/nginx/sites-enabled/default" do
  action :delete
end

# Set up our the webserver for the provisioner.
file "/var/log/provisioner-webserver.log" do
  owner "nobody"
  action :create
end

template "/etc/nginx/provisioner.conf" do
  source "base-nginx.conf.erb"
  variables(:docroot => "/tftpboot",
            :port => 8091,
            :logfile => "/var/log/provisioner-webserver.log",
            :pidfile => "/var/run/provisioner-webserver.pid")
end

bluepill_service "provisioner-webserver" do
  variables(:processes => [ {
                              "daemonize" => false,
                              "pid_file" => "/var/run/provisioner-webserver.pid",
                              "start_command" => "nginx -c /etc/nginx/provisioner.conf",
                              "stderr" => "/var/log/provisioner-webserver.log",
                              "stdout" => "/var/log/provisioner-webserver.log",
                              "name" => "provisioner-webserver"
                            } ] )
  action [:create, :load]
end

# Set up the TFTP server as well.
case node[:platform]
when "ubuntu", "debian"
  package "tftpd-hpa"
  bash "stop ubuntu tftpd" do
    code "service tftpd-hpa stop; killall in.tftpd; rm /etc/init/tftpd-hpa.conf"
    only_if "test -f /etc/init/tftpd-hpa.conf"
  end
when "redhat","centos"
  package "tftp-server"
end

bluepill_service "tftpd" do
  variables(:processes => [ {
                              "daemonize" => true,
                              "start_command" => "in.tftpd -4 -L -a 0.0.0.0:69 -s /tftpboot",
                              "stderr" => "/dev/null",
                              "stdout" => "/dev/null",
                              "name" => "tftpd"
                            } ] )
  action [:create, :load]
end

bash "copy validation pem" do
  code <<-EOH
  cp /etc/chef/validation.pem /tftpboot
  chmod 0444 /tftpboot/validation.pem
EOH
  not_if "test -f /tftpboot/validation.pem"  
end
case node[:platform]
when "ubuntu","debian"
  directory "/tftpboot/curl"

  # I am sorry for this
  case node[:lsb][:codename]
  when "natty"
    file_list = [ "/usr/bin/curl", "/usr/lib/libcurl.so.4",
      "/usr/lib/libidn.so.11", "/usr/lib/liblber-2.4.so.2",
      "/usr/lib/libldap_r-2.4.so.2", "/usr/lib/x86_64-linux-gnu/libgssapi_krb5.so.2",
      "/usr/lib/libssl.so.0.9.8", "/usr/lib/libcrypto.so.0.9.8",
      "/usr/lib/libsasl2.so.2", "/usr/lib/x86_64-linux-gnu/libgnutls.so.26",
      "/usr/lib/x86_64-linux-gnu/libkrb5.so.3", "/usr/lib/x86_64-linux-gnu/libk5crypto.so.3",
      "/usr/lib/x86_64-linux-gnu/libkrb5support.so.0", "/lib/x86_64-linux-gnu/libkeyutils.so.1",
      "/usr/lib/x86_64-linux-gnu/libtasn1.so.3", "/lib/x86_64-linux-gnu/librt.so.1",
      "lib/x86_64-linux-gnu/libcom_err.so.2", "/lib/x86_64-linux-gnu/libgcrypt.so.11",
      "/lib/x86_64-linux-gnu/libgpg-error.so.0"
    ]
  else
    file_list = [ "/usr/bin/curl", "/usr/lib/libcurl.so.4",
      "/usr/lib/libidn.so.11", "/usr/lib/liblber-2.4.so.2",
      "/usr/lib/libldap_r-2.4.so.2", "/usr/lib/libgssapi_krb5.so.2",
      "/usr/lib/libssl.so.0.9.8", "/usr/lib/libcrypto.so.0.9.8",
      "/usr/lib/libsasl2.so.2", "/usr/lib/libgnutls.so.26",
      "/usr/lib/libkrb5.so.3", "/usr/lib/libk5crypto.so.3",
      "/usr/lib/libkrb5support.so.0", "/lib/libkeyutils.so.1",
      "/usr/lib/libtasn1.so.3", "/lib/librt.so.1",
      "/lib/libcom_err.so.2", "/lib/libgcrypt.so.11",
      "/lib/libgpg-error.so.0"
    ]
  end

  file_list.each { |file|
    basefile = file.gsub("/usr/bin/", "").gsub("/usr/lib/", "").gsub("/lib/", "").gsub("/lib/x86_64-linux-gnu/", "")
    bash "copy #{file} to curl dir" do
      code "cp #{file} /tftpboot/curl"
      not_if "test -f /tftpboot/curl/#{basefile}"
    end
  }
end
