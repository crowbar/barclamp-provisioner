def upgrade ta, td, a, d
  a['admin_pass'] = ta['admin_pass']
  return a, d
end

def downgrade ta, td, a, d
  a.delete('admin_pass')
  return a, d
end
