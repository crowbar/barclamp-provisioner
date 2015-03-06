def upgrade ta, td, a, d
  if !a['suse']['autoyast']['repos'].nil? && !a['suse']['autoyast']['repos'].empty?
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
  if !a['suse']['autoyast']['repos']['suse-11.3'].nil? && !a['suse']['autoyast']['repos']['suse-11.3'].empty?
    a['suse']['autoyast']['repos']      = a['suse']['autoyast']['repos']['suse-11.3']
  elsif !a['suse']['autoyast'].nil?
    a['suse'].delete('autoyast')
  end
  return a, d
end
