def upgrade ta, td, a, d
  a['supported_oses']['windows-6.3'] = ta['supported_oses']['windows-6.3']
  a['supported_oses']['hyperv-6.3'] = ta['supported_oses']['hyperv-6.3']
  return a, d
end

def downgrade ta, td, a, d
  a['supported_oses'].delete('windows-6.3')
  a['supported_oses'].delete('hyperv-6.3')
  return a, d
end
