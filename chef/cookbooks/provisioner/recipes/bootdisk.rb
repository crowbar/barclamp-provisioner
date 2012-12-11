#!/usr/bin/env ruby

node[:crowbar_wall] ||= Mash.new

# Find the first thing that looks like a hard drive based on
# PCI bus enumeration, and use it as the target disk.
# Unless some other barclamp has set it, that is.
ruby_block "Find the fallback boot device" do
  block do
    basedir="/dev/disk/by-path"
    dev=nil
    ::Dir.entries(basedir).sort.each do |path|
      # Not a symlink?  Not interested.
      next unless File.symlink?("#{basedir}/#{path}")
      # Symlink does not point at a disk?  Also not interested.
      dev = File.readlink("#{basedir}/#{path}").split('/')[-1]
      break if dev =~ /^[hsv]d[a-z]+$/
      dev = nil
    end
    raise "Cannot find a hard disk!" unless dev
    # Turn the found device into its corresponding /dev/disk/by-id link.
    # This name shoule be more stable than the /dev/disk/by-path one.
    basedir="/dev/disk/by-id"
    bootdisks=::Dir.entries(basedir).select do |m|
      f="#{basedir}/#{m}"
      File.symlink?(f) && (File.readlink(f).split('/')[-1] == dev)
    end
    bootdisk = bootdisks.find{|b|b =~ /^scsi-/} ||
      bootdisks.find{|b|b =~ /^ata-/} ||
      bootdisks.first
    node[:crowbar_wall][:boot_device] = "disk/by-id/#{bootdisk}"
    node.save
  end
  not_if do node[:crowbar_wall][:boot_device] end
end
