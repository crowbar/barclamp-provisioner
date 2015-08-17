node[:crowbar_wall] ||= Mash.new

# Special code for crowbar_register:
# We claim all devices that are in use.
if node["crowbar_wall"]["registering"]
  Chef::Log.info("Using crowbar_register mode to claim devices...")
  unclaimed_disks = BarclampLibrary::Barclamp::Inventory::Disk.unclaimed(node, true)
  unclaimed_disks.each do |d|
    # Make sure to claim disks that are used for mount points
    %x{lsblk #{d.name.gsub(/!/, "/")} --noheadings --output MOUNTPOINT | grep -q ^/$}
    if $?.exitstatus == 0
        Chef::Log.info("Claiming #{d.name} (#{d.unique_name}) as boot device for crowbar_register mode.")
        node[:crowbar_wall][:boot_device] = d.unique_name.sub(/^\/dev\//, "")
        d.claim("Boot")
    else
       %x{lsblk #{d.name} --noheadings --output MOUNTPOINT | grep -q -v ^$}
       d.claim("OS") if $?.exitstatus == 0
    end
  end

 # Remove attribute that is really temporary
 node["crowbar_wall"].delete("registering")
 node.save
end

# Find the first thing that looks like a hard drive based on
# PCI bus enumeration, and use it as the target disk.
# Unless some other barclamp has set it, that is.
ruby_block "Find the fallback boot device" do
  block do
    basedir = "/dev/disk/by-path"
    dev = nil
    disk_by_path = nil
    if File.directory?(basedir)
      ["-usb-", nil].each do |deviceignore|
        ::Dir.entries(basedir).sort.each do |path|
          # Not a symlink?  Not interested.
          next unless File.symlink?(File.join(basedir, path))
          # Symlink does not point at a disk?  Also not interested.
          dev = File.readlink("#{basedir}/#{path}").split('/')[-1]
          # Prefer devices in a specific order
          next if (deviceignore and path.include?(deviceignore))
          disk_by_path = "disk/by-path/#{path}"
          break if dev =~ /^[hsv]d[a-z]+$/
          # pci-0000:0b:08.0-cciss-disk0 -> ../../cciss/c0d0
          break if dev =~ /^c[0-9]+d[0-9]+$/
          # xen-vbd-51712-part1 -> ../../xvda1
          break if dev =~ /^xvd[a-z]+$/
          dev = nil
          disk_by_path = nil
        end
        break if dev
      end
    end
    node[:crowbar_wall][:boot_device] = disk_by_path

    # Turn the found device into its corresponding /dev/disk/by-id link.
    # This name should be more stable than the /dev/disk/by-path one.

    basedir = "/dev/disk/by-id"
    # /dev/disk/by-id is unstable under VirtualBox so don't rely on it.
    hardware = node[:dmi][:system][:product_name] rescue "unknown"
    if hardware !~ /VirtualBox/i && File.directory?(basedir)
      bootdisks = ::Dir.entries(basedir).sort.select do |m|
        f = File.join(basedir, m)
        File.symlink?(f) && (File.readlink(f).split('/')[-1] == dev)
      end
      unless bootdisks.empty?
        # SLE11 SP3 generates so-called "MSFT compatibility links"
        # that start with scsi-1. Skip those, as those are less
        # reusable than the normal links.
        # Note: this find construct should match the code in
        # barclamp/libraries/barclamp_library.rb (from deployer)
        bootdisk = bootdisks.find{|b|b =~ /^scsi-[a-zA-Z]/} ||
          bootdisks.find{|b|b =~ /^scsi-[^1]/} ||
          bootdisks.find{|b|b =~ /^scsi-/} ||
          bootdisks.find{|b|b =~ /^ata-/} ||
          bootdisks.find{|b|b =~ /^cciss-/} ||
          bootdisks.first
        node[:crowbar_wall][:boot_device] = "disk/by-id/#{bootdisk}"
      end
    end

    # Searching boot disk with virtio driver if no other disks were found
    # According to:
    #  https://www.mail-archive.com/systemd-devel@lists.freedesktop.org/msg20607.html
    # the by-path names for virtio device are not stable and don't even exist
    # anymore with newer udev releases including SLES12
    basedir = "/sys/block"
    device_driver = nil
    if dev.nil?
      ::Dir.entries(basedir).sort.each do |path|
        next unless File.symlink?(File.join(basedir, path))
        dev = File.readlink("#{basedir}/#{path}").split('/')[-1]
        if dev =~ /^vd[a-z]+$/ && File.exists?("/sys/block/#{dev}/device/uevent")
          File.open("/sys/block/#{dev}/device/uevent").each_line {
            |line| device_driver = line.strip.split('=')[1] if line =~ /DRIVER/
          }
          if device_driver =~ /^virtio/
            node[:crowbar_wall][:boot_device] = dev
            break
          end
        end
      end
    else
      raise "Cannot find a hard disk!"
    end

    disk = BarclampLibrary::Barclamp::Inventory::Disk.new(node,dev)
    disk.claim("Boot")
    node.save
  end
  not_if do node[:crowbar_wall][:boot_device] end
end
