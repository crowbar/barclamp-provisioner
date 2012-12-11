#!/usr/bin/env ruby

basedir="/dev/disk/by-path"
dev=nil
node[:crowbar_wall] ||= Mash.new

# Find the first thing that looks like a hard drive based on
# PCI bus enumeration, and use it as the target disk.
# Unless some other barclamp has set it, that is.
return if node[:crowbar_wall][:boot_device]
::Dir.entries(basedir).sort.each do |path|
  # Not a symlink?  Not interested.
  next unless File.symlink?("#{basedir}/#{path}")
  # Symlink does not point at a disk?  Also not interested.
  dev = File.readlink("#{basedir}/#{path}").split('/')[-1]
  next unless dev =~ /^[hsv]d[a-z]+$/
  break
end

raise "Cannot find a hard disk!" unless dev
# Turn the found device into its corresponding /dev/disk/by-id link.
# This name shoule be more stable than the /dev/disk/by-path one.
basedir="/dev/disk/by-id"
bootdisk=::Dir.entries(basedir).select do |m|
  f="#{basedir}/#{m}"
  File.symlink?(f) && (File.readlink(f).split('/')[-1] == dev)
end.sort do |a,b|
  case
  when a == b then 0
  when a =~ /^scsi-/ then -1
  when b =~ /^scsi-/ then 1
  when a =~ /^ata-/ then -1
  when b =~ /^ata-/ then 1
  else a <=> b
  end
end.first
node[:crowbar_wall][:boot_device] = "disk/by-id/#{bootdisk}"

node.save
