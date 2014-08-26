def upgrade ta, td, a, d
  a['supported_oses']['suse-12.0'] = ta['supported_oses']['suse-12.0']
  return a, d
end

def downgrade ta, td, a, d
  a['supported_oses'].delete('suse-12.0')
  return a, d
end
