def upgrade ta, td, a, d
  a['supported_oses'] = ta['supported_oses']

  if a.fetch('suse', {}).fetch('autoyast',{})['repos']
    a['suse']['autoyast']['repos'].keys.each do |os|
      os_value = a['suse']['autoyast']['repos'].delete(os)
      a['suse']['autoyast']['repos'][os] = {}
      a['suse']['autoyast']['repos'][os]['x86_64'] = os_value
    end
  end

  return a, d
end

def downgrade ta, td, a, d
  a['supported_oses'] = ta['supported_oses']

  if a.fetch('suse', {}).fetch('autoyast',{})['repos']
    a['suse']['autoyast']['repos'].keys.each do |os|
      os_value = a['suse']['autoyast']['repos'][os].delete('x86_64')
      a['suse']['autoyast']['repos'].delete(os)
      if os_value
        a['suse']['autoyast']['repos'][os] = os_value
      end
    end
  end

  return a, d
end
