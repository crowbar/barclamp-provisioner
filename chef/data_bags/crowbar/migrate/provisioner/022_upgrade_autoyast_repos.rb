def upgrade ta, td, a, d
  # The 'suse' hierarchy is optional in the proposal template so we need to
  # check the whole tree here.
  if a.fetch('suse', {}).fetch('autoyast',{})['repos']
    if %w(common suse-11.3 suse-12.0).select {|k|
        a['suse']['autoyast']['repos'].keys.include? k
    }.empty?
      repos = a['suse']['autoyast'].delete('repos')
      a['suse']['autoyast']['repos'] = {}
      a['suse']['autoyast']['repos']['suse-11.3'] = repos
    end
  end
  return a, d
end

def downgrade ta, td, a, d
  # The 'suse' hierarchy is optional in the proposal template
  if a['suse'].fetch('autoyast', {}).fetch('repos', {})['suse-11.3']
    a['suse']['autoyast']['repos'] = a['suse']['autoyast']['repos']['suse-11.3']
  else
    a.delete('suse')
  end
  return a, d
end
