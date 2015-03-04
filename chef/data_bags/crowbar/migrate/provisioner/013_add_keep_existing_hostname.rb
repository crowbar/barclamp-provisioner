def upgrade ta, td, a, d
  a['keep_existing_hostname'] = ta['keep_existing_hostname']
  return a, d
end

def downgrade ta, td, a, d
  a.delete 'keep_existing_hostname'
  return a, d
end
