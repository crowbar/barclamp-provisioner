#!/usr/bin/env ruby

node[:crowbar_wall] ||= Mash.new

# Find the first thing that looks like a hard drive based on
# PCI bus enumeration, and use it as the target disk.
# Unless some other barclamp has set it, that is.
ruby_block "Find the fallback boot device" do
  block do
    basedir="/dev/disk/by-path"
    dev=nil
    disk_by_path = nil
    ::Dir.entries(basedir).sort.each do |path|
      # Not a symlink?  Not interested.
      next unless File.symlink?(File.join(basedir, path))
      # Symlink does not point at a disk?  Also not interested.
      dev = File.readlink("#{basedir}/#{path}").split('/')[-1]
      disk_by_path = "disk/by-path/#{path}"
      break if dev =~ /^[hsv]d[a-z]+$/
      # pci-0000:0b:08.0-cciss-disk0 -> ../../cciss/c0d0
      break if dev =~ /^c[0-9]+d[0-9]+$/
      dev = nil
      disk_by_path = nil
    end
    raise "Cannot find a hard disk!" unless dev
    node[:crowbar_wall][:boot_device] = disk_by_path
    # Turn the found device into its corresponding /dev/disk/by-id link.
    # This name should be more stable than the /dev/disk/by-path one.

    basedir="/dev/disk/by-id"
    if File.exists? basedir
      bootdisks=::Dir.entries(basedir).sort.select do |m|
        f = File.join(basedir, m)
        File.symlink?(f) && (File.readlink(f).split('/')[-1] == dev)
      end
      unless bootdisks.empty?
        bootdisk = bootdisks.find{|b|b =~ /^scsi-[a-zA-Z]/} ||
          bootdisks.find{|b|b =~ /^scsi-/} ||
          bootdisks.find{|b|b =~ /^ata-/} ||
          bootdisks.find{|b|b =~ /^cciss-/} ||
          bootdisks.first
        node[:crowbar_wall][:boot_device] = "disk/by-id/#{bootdisk}"
      end
    end
    disk = BarclampLibrary::Barclamp::Inventory::Disk.new(node,dev)
    disk.claim("Boot")
    node.save
  end
  not_if do node[:crowbar_wall][:boot_device] end
end
