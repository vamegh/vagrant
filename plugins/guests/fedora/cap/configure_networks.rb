require "set"
require "tempfile"

require_relative "../../../../lib/vagrant/util/retryable"
require_relative "../../../../lib/vagrant/util/template_renderer"

module VagrantPlugins
  module GuestFedora
    module Cap
      class ConfigureNetworks
        extend Vagrant::Util::Retryable
        include Vagrant::Util

        def self.configure_networks(machine, networks)
          network_scripts_dir = machine.guest.capability("network_scripts_dir")

          virtual = false
          interface_names = Array.new
          interface_names_by_slot = Array.new
          machine.communicate.sudo("/usr/sbin/biosdevname &>/dev/null; echo $?") do |_, result|
            # The above command returns:
            #   - '4' if /usr/sbin/biosdevname detects it is running in a virtual machine
            #   - '127' if /usr/sbin/biosdevname doesn't exist
            virtual = true if ['4', '127'].include? result.chomp
          end

          if virtual
            machine.communicate.sudo("ls -v /sys/class/net | egrep -v lo\\|docker") do |_, result|
              next if result !~ /(^en\w\d)|(^sl\w\d)|(^wl\w\d)|(^ww\w\d)|(^em\w\d)|(^p\w\d)|(^eth\d)/
              interface_names = result.split("\n")
            end

            interface_names_by_slot = networks.map do |network|
               "#{interface_names[network[:interface]]}"
            end
          else
            machine.communicate.sudo("/usr/sbin/biosdevname -d | grep Kernel | cut -f2 -d: | sed -e 's/ //;'") do |_, result|
              next if result !~ /(^en\w\d)|(^sl\w\d)|(^wl\w\d)|(^ww\w\d)|(^em\w\d)|(^p\w\d)|(^eth\d)/
              interface_names = result.split("\n")
            end

            interface_name_pairs = Array.new
            interface_names.each do |interface_name|
              machine.communicate.sudo("/usr/sbin/biosdevname --policy=all_ethN -i #{interface_name}") do |_, result|
                next if result !~ /(^en\w\d)|(^sl\w\d)|(^wl\w\d)|(^ww\w\d)|(^em\w\d)|(^p\w\d)|(^eth\d)/
                interface_name_pairs.push([interface_name, result.gsub("\n", "")])
              end
            end

            setting_interface_names = networks.map do |network|
               "eth#{network[:interface]}"
            end

            interface_names_by_slot = interface_names.dup
            interface_name_pairs.each do |interface_name, previous_interface_name|
              if setting_interface_names.index(previous_interface_name) == nil
                interface_names_by_slot.delete(interface_name)
              end
            end
          end

          # Read interface MAC addresses for later matching
          mac_addresses = Array.new(interface_names.length)
          interface_names.each_with_index do |ifname, index|
            machine.communicate.sudo("cat /sys/class/net/#{ifname}/address") do |_, result|
              mac_addresses[index] = result.strip
            end
          end

          # Accumulate the configurations to add to the interfaces file as well
          # as what interfaces we're actually configuring since we use that later.
          interfaces = Set.new
          networks.each do |network|
            interface = nil
            if network[:mac_address]
              found_idx = mac_addresses.find_index(network[:mac_address])
              # Ignore network if requested MAC address could not be found
              next if found_idx.nil?
              interface = interface_names[found_idx]
            else
              ifname_by_slot = interface_names_by_slot[network[:interface]-1]
              # Don't overwrite if interface was already matched via MAC address
              next if interfaces.include?(ifname_by_slot)
              interface = ifname_by_slot
            end

            interfaces.add(interface)
            network[:device] = interface

            # Remove any previous vagrant configuration in this network
            # interface's configuration files.
            machine.communicate.sudo("touch #{network_scripts_dir}/ifcfg-#{interface}")
            machine.communicate.sudo("sed -e '/^#VAGRANT-BEGIN/,/^#VAGRANT-END/ d' #{network_scripts_dir}/ifcfg-#{interface} > /tmp/vagrant-ifcfg-#{interface}")
            machine.communicate.sudo("cat /tmp/vagrant-ifcfg-#{interface} > #{network_scripts_dir}/ifcfg-#{interface}")
            machine.communicate.sudo("rm -f /tmp/vagrant-ifcfg-#{interface}")

            # Render and upload the network entry file to a deterministic
            # temporary location.
            entry = TemplateRenderer.render("guests/fedora/network_#{network[:type]}",
                                            options: network)

            Tempfile.open("vagrant-fedora-configure-networks") do |f|
              f.binmode
              f.write(entry)
              f.fsync
              f.close
              machine.communicate.upload(f.path, "/tmp/vagrant-network-entry_#{interface}")
            end
          end

          # Bring down all the interfaces we're reconfiguring. By bringing down
          # each specifically, we avoid reconfiguring p7p (the NAT interface) so
          # SSH never dies.
          interfaces.each do |interface|
            retryable(on: Vagrant::Errors::VagrantError, tries: 3, sleep: 2) do
              machine.communicate.sudo(<<-SCRIPT, error_check: true)
cat /tmp/vagrant-network-entry_#{interface} >> #{network_scripts_dir}/ifcfg-#{interface}

if command -v nmcli &>/dev/null; then
  if command -v systemctl &>/dev/null && systemctl -q is-enabled NetworkManager &>/dev/null; then
    nmcli c reload #{interface}
  elif command -v service &>/dev/null && service NetworkManager status &>/dev/null; then
    nmcli c reload #{interface}
  fi
fi

/sbin/ifdown #{interface}
/sbin/ifup #{interface}

rm -f /tmp/vagrant-network-entry_#{interface}
SCRIPT
            end
          end
        end
      end
    end
  end
end
