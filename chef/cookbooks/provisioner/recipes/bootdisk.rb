#!/usr/bin/env ruby

node[:crowbar_wall] ||= Mash.new

ruby_block "Find the fallback boot device" do
  block do
    # Parse what sysfs knows about all our block devices
    # in order to find our boot device candidate.
    # We do it this way instead of using /dev/disk/by-path
    # because udev can identify devices by SCSI WWN intead of
    # host:bus:target:lun identification.
    # This will break for devices that are not addressed through
    # the SCSI midlayer.
    Bootdev = Struct.new(:device,:pci_address,:scsi_id, :path)
    candidates = Array.new
    ::Dir.entries("/sys/block").each do |dev|
      # Pre-filter out uninteresting devices.
      next unless dev =~ /^[hsv]d[a-z]+$/
      name = File.join("/sys/block",dev)
      next unless File.symlink?(name)
      link = File.readlink(name)
      path = File.expand_path(link,"/sys/block")
      # Ignore USB devices
      next if path =~ /\/usb[^\/]*\//
      # Ignore any non-removable USB devices
      next if (node[:block_device][dev][:removable] rescue "not here") != "0"
      pci_address = Array.new
      scsi_id = Array.new
      # For now, we are looking for devices hosting SCSI devices hanging off
      # devices attached to a PCI bus.  This means that iSCSI targets and
      # things that do not communicate through the SCSI midlayer will not
      # work, but those are the breaks for now.
      # A better algorithm is welcome.
      path.split('/').each do |p|
        case
        when /(([0-9a-f]+:){2}[0-9a-f]+\.[0-9a-f]+)/ =~ p
          # We need to handle it this way to account for multiple layers
          # of PCI busses.  It would not do to pick the wrong device due
          # to not mapping out the PCI bus topology properly.
          pci_address << $1.split(/[:\.]/).map{|i|i.hex}
        when /(([0-9a-f]+:){3}[0-9a-f]+)/ =~ p
          # It is not likely that we will have more than one SCSI quad
          # in a sysfs path, but it should be harmless if we do.
          scsi_id << $1.split(":").map{|i|i.hex}
        end
      end
      next if pci_address.empty? || scsi_id.empty?
      Chef::Log.info("Will consider #{path} as the boot device.")
      candidates << Bootdev.new(dev,pci_address,scsi_id,path)
    end
    # Find the first thing that looks like a hard drive based on
    # PCI bus enumeration and SCSI quad, and use it as the target disk.
    # Unless some other barclamp has set it, that is.
    candidate = candidates.sort do |a,b|
      res = a.pci_address <=> b.pci_address
      res = a.scsi_id <=> b.scsi_id if res == 0
      res = a.device <=> b.device if res == 0
      res
    end.first
    dev = "sda"
    if !candidate.nil?
      Chef::Log.info("Picked #{candidate.path} as the boot device.")
      dev = candidate.device
    else
      Chef::Log.info("Could not pick a best candidate, defaulting to /dev/sda")
    end
    disk = BarclampLibrary::Barclamp::Inventory::Disk.new(node,dev)
    raise "Could not claim a boot device!" unless disk.claim("Boot")
    node[:crowbar_wall][:boot_device] = disk.unique_device
    node.save
  end
  not_if do node[:crowbar_wall][:boot_device] end
end
